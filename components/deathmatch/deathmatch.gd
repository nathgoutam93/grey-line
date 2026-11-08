extends Node

## Deathmatch rules and match flow: timer, score limit, end of match, the
## result overlay and returning to the lobby.
##
## The work is split across two children (deathmatch_game_mode.tscn):
## - Spawning (MatchPlayerSpawner): spawn / respawn / per-peer player setup.
## - Scoreboard (MatchScoreboard): kills, deaths, ping, kill feed, leaderboard.

@export var player_scene: PackedScene
@export var leaderboard: DeathmatchLeaderboard
@export var map: Node2D
@export var spawn_point_container: Node
@export var match_timer_label: Label
@export var timer_touch_toggle_button: TouchScreenButton
@export var match_result_overlay: Control
@export var match_result_label: Label
@export var leave_game_button: TouchScreenButton
@export_range(30, 3600, 1, "or_greater") var match_duration_seconds := 600
@export_range(1, 200, 1, "or_greater") var score_limit := 25
@export_range(0.5, 10.0, 0.1, "or_greater") var post_match_result_duration_seconds := 2.0

@onready var spawning: MatchPlayerSpawner = $Spawning
@onready var scoreboard: MatchScoreboard = $Scoreboard

const TIMER_REFRESH_INTERVAL := 1.0
const RESYNC_REQUEST_DELAY_SECONDS := 0.75
const RPC_CHANNEL_UI := 2

var match_time_remaining := 0.0
var match_ended := false
var winning_peer_id := -1
var touch_leaderboard_visible := false
var post_match_transition_started := false
var post_match_transition_deadline_msec := -1
var post_match_scene_change_requested := false
var _timer_refresh_elapsed := 0.0

func _ready():
	spawning.setup(map, spawn_point_container, player_scene)
	scoreboard.setup(map, leaderboard, score_limit)
	spawning.player_setup.connect(scoreboard.track_player)
	scoreboard.score_limit_reached.connect(func(peer_id: int): _end_match(peer_id, "score limit"))

	if is_instance_valid(leaderboard):
		leaderboard.visible = false
	if is_instance_valid(match_result_overlay):
		match_result_overlay.visible = false
	if is_instance_valid(leave_game_button):
		leave_game_button.visible = false
		if not leave_game_button.pressed.is_connected(_on_leave_game_pressed):
			leave_game_button.pressed.connect(_on_leave_game_pressed)
	if is_instance_valid(timer_touch_toggle_button):
		if not timer_touch_toggle_button.pressed.is_connected(_on_timer_touch_toggle_pressed):
			timer_touch_toggle_button.pressed.connect(_on_timer_touch_toggle_pressed)

	match_time_remaining = float(match_duration_seconds)
	_update_match_timer_ui_local(_format_match_time(match_time_remaining))

	if not NetUtil.has_active_peer(multiplayer):
		return

	if not multiplayer.is_server():
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.server_disconnected.connect(_on_disconnected)
		multiplayer.connection_failed.connect(_on_connection_failed)
		call_deferred("_request_players_resync_delayed")
		return

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_update_match_timer_ui.rpc(_format_match_time(match_time_remaining))
	spawning.call_deferred("spawn_initial_connected_players")

func _exit_tree() -> void:
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)

func _process(delta: float) -> void:
	if post_match_transition_started:
		_try_execute_post_match_transition()
		return
	if not NetUtil.has_active_peer(multiplayer):
		return

	if is_instance_valid(leaderboard):
		leaderboard.visible = touch_leaderboard_visible
	if is_instance_valid(leave_game_button):
		leave_game_button.visible = touch_leaderboard_visible and not OS.has_feature("dedicated_server")

	if not multiplayer.is_server() or match_ended:
		return
	match_time_remaining = max(match_time_remaining - delta, 0.0)
	_timer_refresh_elapsed += delta
	if _timer_refresh_elapsed >= TIMER_REFRESH_INTERVAL or is_zero_approx(match_time_remaining):
		_timer_refresh_elapsed = 0.0
		_update_match_timer_ui.rpc(_format_match_time(match_time_remaining))
	if is_zero_approx(match_time_remaining):
		_end_match(-1, "time limit")

# --- connection -------------------------------------------------------------

func _on_connected():
	print("Connected to server.")
	spawning.request_resync()
	call_deferred("_request_players_resync_delayed")

func _on_disconnected():
	print("Disconnected from server.")
	call_deferred("_change_to_post_match_scene")

func _on_connection_failed():
	print("Failed to connect to server.")

func _request_players_resync_delayed() -> void:
	await get_tree().create_timer(RESYNC_REQUEST_DELAY_SECONDS).timeout
	spawning.request_resync()

func _on_peer_connected(id: int):
	print("Peer connected: %d" % id)
	_sync_match_state_to_peer(id)
	if not match_ended:
		spawning.spawn_player(id)
		spawning.call_deferred("sync_existing_players_to_peer", id)

func _on_peer_disconnected(id: int):
	print("Peer disconnected: %d" % id)
	scoreboard.remove_peer(id)

func _sync_match_state_to_peer(peer_id: int) -> void:
	scoreboard.send_stats_to(peer_id)
	if match_ended:
		_update_match_timer_ui.rpc_id(peer_id, "")
		_show_match_end_ui_and_return.rpc_id(peer_id, winning_peer_id, scoreboard.player_stats)
		return
	_update_match_timer_ui.rpc_id(peer_id, _format_match_time(match_time_remaining))

# --- input / HUD ------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("stats"):
		_toggle_hud_menu_visibility()
		get_viewport().set_input_as_handled()

func _on_timer_touch_toggle_pressed() -> void:
	_toggle_hud_menu_visibility()

func _toggle_hud_menu_visibility() -> void:
	if match_ended or post_match_transition_started:
		return
	touch_leaderboard_visible = not touch_leaderboard_visible

func _on_leave_game_pressed() -> void:
	if post_match_scene_change_requested:
		return
	post_match_scene_change_requested = true
	if not _change_to_post_match_scene():
		post_match_scene_change_requested = false

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _update_match_timer_ui(text: String) -> void:
	_update_match_timer_ui_local(text)

func _update_match_timer_ui_local(text: String) -> void:
	if is_instance_valid(match_timer_label):
		match_timer_label.text = text

func _format_match_time(total_seconds: float) -> String:
	var clamped_seconds := maxi(0, int(ceil(total_seconds)))
	return "%02d:%02d" % [clamped_seconds / 60, clamped_seconds % 60]

# --- end of match -----------------------------------------------------------

func _end_match(winner_id: int, reason: String) -> void:
	if match_ended:
		return
	if winner_id <= 0:
		winner_id = scoreboard.resolve_top_scorer()

	match_ended = true
	winning_peer_id = winner_id
	spawning.spawning_enabled = false
	scoreboard.active = false

	scoreboard.refresh_all_combat_data()
	var final_stats := scoreboard.final_stats()
	print("Match ended by %s. Winner: %s" % [reason, scoreboard.winner_name(winner_id)])
	scoreboard.broadcast_stats(final_stats)
	_update_match_timer_ui.rpc("")
	_show_match_end_ui_and_return.rpc(winner_id, final_stats)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _show_match_end_ui_and_return(winner_id: int, final_stats: Dictionary) -> void:
	if post_match_transition_started:
		return
	post_match_transition_started = true
	post_match_transition_deadline_msec = Time.get_ticks_msec() + int(post_match_result_duration_seconds * 1000.0)

	if is_instance_valid(leaderboard):
		leaderboard.populate_leaderboard(final_stats)
		leaderboard.visible = false
	touch_leaderboard_visible = false
	if is_instance_valid(leave_game_button):
		leave_game_button.visible = false
	if is_instance_valid(match_result_overlay):
		match_result_overlay.visible = true
	if is_instance_valid(match_result_label):
		match_result_label.text = _local_match_result_text(winner_id)

	if OS.has_feature("dedicated_server"):
		return
	_try_execute_post_match_transition()

func _local_match_result_text(winner_id: int) -> String:
	if winner_id > 0 and NetUtil.has_active_peer(multiplayer) and multiplayer.get_unique_id() == winner_id:
		return "VICTORY"
	return "DEFEAT"

func _try_execute_post_match_transition() -> void:
	if post_match_transition_deadline_msec < 0:
		return
	if Time.get_ticks_msec() < post_match_transition_deadline_msec:
		return
	if post_match_scene_change_requested:
		return
	post_match_scene_change_requested = true
	if not _change_to_post_match_scene():
		post_match_scene_change_requested = false

func _change_to_post_match_scene() -> bool:
	if not is_inside_tree():
		return false
	var mask_viewport := MaskViewProvider.viewport
	if is_instance_valid(mask_viewport):
		mask_viewport.player_camera = null
		mask_viewport.player = null
	MultiplayerSession.call_deferred("return_to_lobby_after_match")
	return true
