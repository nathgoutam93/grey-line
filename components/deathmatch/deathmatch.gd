extends Node

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
@export_file("*.tscn") var post_match_scene_path := "res://scenes/main_menu/main_menu.tscn"

var spawn_points: Array[Node2D] = []

var player_stats := {} # Format: { peer_id: { "kills": 0, "deaths": 0 } }
var stats_refresh_elapsed := 0.0
var timer_refresh_elapsed := 0.0
var ping_probe_elapsed := 0.0
var match_time_remaining := 0.0
var match_ended := false
var winning_peer_id := -1
var touch_leaderboard_visible := false
var post_match_transition_started := false
var post_match_transition_deadline_msec := -1
var post_match_scene_change_requested := false
const STATS_REFRESH_INTERVAL := 0.35
const TIMER_REFRESH_INTERVAL := 1.0
const PING_PROBE_INTERVAL := 1.0

func _ready():
	_cache_spawn_points()

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

	if not _has_active_multiplayer_peer():
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

	call_deferred("_spawn_initial_connected_players")


func _process(delta: float) -> void:
	if post_match_transition_started:
		_try_execute_post_match_transition()
		return

	if not _has_active_multiplayer_peer():
		return

	if is_instance_valid(leaderboard):
		leaderboard.visible = touch_leaderboard_visible
	if is_instance_valid(leave_game_button):
		leave_game_button.visible = touch_leaderboard_visible and not OS.has_feature("dedicated_server")

	if not multiplayer.is_server():
		ping_probe_elapsed += delta
		if ping_probe_elapsed >= PING_PROBE_INTERVAL:
			ping_probe_elapsed = 0.0
			_request_ping_echo.rpc_id(1, Time.get_ticks_msec())
		return

	if not match_ended:
		match_time_remaining = max(match_time_remaining - delta, 0.0)
		timer_refresh_elapsed += delta
		if timer_refresh_elapsed >= TIMER_REFRESH_INTERVAL or is_zero_approx(match_time_remaining):
			timer_refresh_elapsed = 0.0
			_update_match_timer_ui.rpc(_format_match_time(match_time_remaining))
		if is_zero_approx(match_time_remaining):
			_end_match(-1, "time limit")
			return

	if match_ended:
		return

	stats_refresh_elapsed += delta
	if stats_refresh_elapsed < STATS_REFRESH_INTERVAL:
		return

	stats_refresh_elapsed = 0.0
	if _refresh_all_player_combat_data():
		_update_stats.rpc(player_stats)


func _on_connected():
	print("Connected to server.")
	request_players_resync.rpc_id(1)
	call_deferred("_request_players_resync_delayed")

func _on_disconnected():
	print("Disconnected from server.")
	call_deferred("_change_to_post_match_scene")

func _on_connection_failed():
	print("Failed to connect to server.")

func _request_players_resync_delayed() -> void:
	await get_tree().create_timer(0.75).timeout
	if not _has_active_multiplayer_peer():
		return
	if multiplayer.is_server():
		return
	request_players_resync.rpc_id(1)

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
	var changed := _change_to_post_match_scene()
	if not changed:
		post_match_scene_change_requested = false


func _on_peer_connected(id: int):
	print("Peer connected: %d" % id)
	_sync_match_state_to_peer(id)
	if not match_ended:
		spawn_player(id)
		call_deferred("_sync_existing_players_to_peer", id)

func _spawn_initial_connected_players() -> void:
	if not is_inside_tree():
		return
	if not _has_active_multiplayer_peer() or not multiplayer.is_server():
		return
	if match_ended:
		return

	if not OS.has_feature("dedicated_server"):
		spawn_player(1)
	for peer_id in multiplayer.get_peers():
		spawn_player(peer_id)

func _on_peer_disconnected(id: int):
	print("Peer disconnected: %d" % id)
	player_stats.erase(id)
	_update_stats.rpc(player_stats)


func register_death(victim_id: int, killer_id: int, is_headshot: bool = false):
	if not multiplayer.is_server() or match_ended:
		return

	var killer_name := _player_identifier(killer_id) if killer_id > 0 else "Unknown"
	var victim_name := _player_identifier(victim_id)

	if player_stats.has(victim_id):
		player_stats[victim_id]["deaths"] += 1
	if player_stats.has(killer_id) and killer_id != victim_id:
		player_stats[killer_id]["kills"] += 1
		_notify_local_kill_feedback.rpc_id(killer_id, is_headshot)
		if int(player_stats[killer_id].get("kills", 0)) >= score_limit:
			_end_match(killer_id, "score limit")

	_notify_kill_feed.rpc(killer_name, victim_name)
	_refresh_player_combat_data(victim_id)
	_refresh_player_combat_data(killer_id)

	print("K/D updated:")
	print("Player %d -> Kills: %d, Deaths: %d" % [
		killer_id,
		player_stats.get(killer_id, {}).get("kills", 0),
		player_stats.get(killer_id, {}).get("deaths", 0)
	])

	_update_stats.rpc(player_stats)


@rpc("authority", "call_local", "reliable")
func _notify_local_kill_feedback(is_headshot: bool = false) -> void:
	if not _has_active_multiplayer_peer():
		return
	if not is_instance_valid(map):
		return

	var local_peer_id := multiplayer.get_unique_id()
	var local_player := map.get_node_or_null(str(local_peer_id)) as PlayerController
	if local_player == null or local_player.hud == null:
		return

	if local_player.hud.has_method("show_kill_feedback"):
		local_player.hud.call("show_kill_feedback", is_headshot)


@rpc("authority", "call_local", "reliable")
func _notify_kill_feed(killer_name: String, victim_name: String) -> void:
	if not _has_active_multiplayer_peer():
		return
	if not is_instance_valid(map):
		return

	var local_peer_id := multiplayer.get_unique_id()
	var local_player := map.get_node_or_null(str(local_peer_id)) as PlayerController
	if local_player == null or local_player.hud == null:
		return

	if local_player.hud.has_method("show_kill_feed_toast"):
		local_player.hud.call("show_kill_feed_toast", killer_name, victim_name)


@rpc("call_local", "reliable")
func _update_stats(stats: Dictionary):
	if not is_instance_valid(leaderboard):
		return

	leaderboard.populate_leaderboard(stats)


@rpc("call_local", "reliable")
func _setup_player(peer_id, player_path: NodePath, spawn_position: Vector2, server_tick: int):
	for _i in range(30):
		if not is_inside_tree():
			return
		var maybe_player := get_node_or_null(player_path) as PlayerController
		if maybe_player != null:
			break
		await get_tree().process_frame
	if match_ended:
		return
	if not is_instance_valid(map):
		return

	var player := get_node_or_null(player_path) as PlayerController
	if player == null:
		# Fallback for late join: if spawner has not materialized this player yet, create it locally on the client.
		if not multiplayer.is_server() and is_instance_valid(map) and player_scene != null:
			var existing := map.get_node_or_null(str(peer_id)) as PlayerController
			if existing == null:
				var spawned := player_scene.instantiate() as PlayerController
				spawned.name = str(peer_id)
				spawned.set_multiplayer_authority(1)
				map.add_child(spawned, true)
				await get_tree().process_frame
		player = map.get_node_or_null(str(peer_id)) as PlayerController
		if player == null:
			# Player can despawn before setup RPC executes (e.g. match end or disconnect).
			return

	player.reset_for_respawn()
	player.global_position = spawn_position
	player.set_multiplayer_authority(1)
	if player.has_method("sync_server_tick"):
		player.sync_server_tick(server_tick)

	if player:
		player.owner_peer_id = peer_id
		player.player_input.set_authority(peer_id)

		if _has_active_multiplayer_peer() and multiplayer.is_server():
			if not player_stats.has(peer_id):
				player_stats[peer_id] = _new_player_stats(peer_id)
			_refresh_player_combat_data(peer_id, player)
			_update_stats.rpc(player_stats)
			player.health_component.die_detailed.connect(func(killer_id: int, is_headshot: bool): register_death(peer_id, killer_id, is_headshot))
			player.tree_exited.connect(_on_player_tree_exited.bind(peer_id))

		if _has_active_multiplayer_peer() and peer_id == multiplayer.get_unique_id():
			player.setup_locals()
			MaskViewProvider.viewport.player_camera = player.camera
			MaskViewProvider.viewport.player = player

# Spawn a player on server, will autospawn on client by MultiplayerSpawner Node
func spawn_player(peer_id: int):
	if match_ended:
		return

	if not is_instance_valid(map):
		return

	if spawn_points.is_empty():
		push_warning("No spawn points configured. Set Deathmatch.spawn_point_container in the editor.")
		return

	var spawn_point = spawn_points.pick_random()

	var player_instance = player_scene.instantiate()
	var existing_named_player := map.get_node_or_null(str(peer_id)) as PlayerController
	if existing_named_player != null:
		existing_named_player.queue_free()
	player_instance.name = str(peer_id)
	player_instance.position = spawn_point.global_position
	player_instance.owner_peer_id = peer_id
	player_instance.set_multiplayer_authority(1)

	player_instance.ready.connect(func(): rpc("_setup_player", peer_id, player_instance.get_path(), spawn_point.global_position, NetworkTick.tick))
	map.add_child(player_instance, true)
	
	print("Spawned player for peer %d at %s" % [peer_id, spawn_point.global_position])

func _sync_existing_players_to_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if not is_instance_valid(map):
		return
	for child in map.get_children():
		var player := child as PlayerController
		if player == null:
			continue
		rpc_id(peer_id, "_setup_player", player.owner_peer_id, player.get_path(), player.global_position, NetworkTick.tick)

@rpc("any_peer", "reliable")
func request_players_resync() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	_sync_existing_players_to_peer(peer_id)

func _cache_spawn_points() -> void:
	spawn_points.clear()
	if not is_instance_valid(spawn_point_container):
		return

	for child in spawn_point_container.get_children():
		if child is Node2D:
			spawn_points.append(child)

func _on_player_tree_exited(peer_id: int) -> void:
	if not is_inside_tree():
		return
	if not _has_active_multiplayer_peer() or not multiplayer.is_server() or match_ended:
		return
	if not _should_respawn_peer(peer_id):
		return
	spawn_player(peer_id)

func _should_respawn_peer(peer_id: int) -> bool:
	if peer_id == multiplayer.get_unique_id():
		return true

	var multiplayer_manager := get_tree().get_first_node_in_group("multiplayer_manager")
	if multiplayer_manager != null and multiplayer_manager.has_method("is_peer_connected"):
		return bool(multiplayer_manager.call("is_peer_connected", peer_id))

	return multiplayer.get_peers().has(peer_id)

func _exit_tree() -> void:
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)


func _new_player_stats(peer_id: int) -> Dictionary:
	return {
		"player_identifier": _player_identifier(peer_id),
		"kills": 0,
		"deaths": 0,
		"ping_ms": 0,
		"loadout": {},
		"current_weapon": {}
	}

@rpc("any_peer", "unreliable")
func _request_ping_echo(client_send_msec: int) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	_receive_ping_echo.rpc_id(peer_id, client_send_msec)

@rpc("authority", "call_local", "unreliable")
func _receive_ping_echo(client_send_msec: int) -> void:
	if multiplayer.is_server():
		return
	if client_send_msec <= 0:
		return
	var rtt_ms := maxi(0, int(Time.get_ticks_msec() - client_send_msec))
	_report_client_ping.rpc_id(1, rtt_ms)

@rpc("any_peer", "unreliable")
func _report_client_ping(rtt_ms: int) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	if not player_stats.has(peer_id):
		player_stats[peer_id] = _new_player_stats(peer_id)
	var stats: Dictionary = player_stats[peer_id]
	var sanitized_rtt := maxi(0, mini(rtt_ms, 9999))
	if int(stats.get("ping_ms", -1)) == sanitized_rtt:
		return
	stats["ping_ms"] = sanitized_rtt
	player_stats[peer_id] = stats
	_update_stats.rpc(player_stats)

func _slot_name(slot: int) -> String:
	match slot:
		EquipmentData.EquipmentSlot.PRIMARY:
			return "primary"
		EquipmentData.EquipmentSlot.SECONDARY:
			return "secondary"
		EquipmentData.EquipmentSlot.MELEE:
			return "melee"
		_:
			return "unknown"


func _get_equipment_manager(player: PlayerController) -> Node:
	if player.equipment_manager:
		return player.equipment_manager
	return player.weapon_manager


func _weapon_payload(equipment: EquipmentInstance) -> Dictionary:
	if equipment == null or equipment.equipment_data == null:
		return {}
	if equipment is WeaponInstance:
		var weapon = equipment as WeaponInstance
		return {
			"name": weapon.data.name,
			"slot": _slot_name(weapon.data.slot),
			"ammo_in_mag": weapon.ammo_in_mag,
			"ammo_reserve": weapon.ammo_reserve,
			"mag_size": weapon.data.mag_size,
			"uses_ammo": weapon.data.uses_ammo
		}
	# Generic equipment (non-weapon)
	return {
		"name": equipment.equipment_data.name
	}

func _refresh_player_combat_data(peer_id: int, player: PlayerController = null) -> bool:
	if not multiplayer.is_server():
		return false

	if not player_stats.has(peer_id):
		player_stats[peer_id] = _new_player_stats(peer_id)

	if player == null:
		if not is_instance_valid(map):
			return false
		player = map.get_node_or_null(str(peer_id)) as PlayerController

	var loadout_payload := {}
	var current_weapon_payload := {}

	if player:
		var equipment_manager = _get_equipment_manager(player)
		if equipment_manager:
			var current_item = equipment_manager.get_current_item() if equipment_manager.has_method("get_current_item") else equipment_manager.current_weapon
			current_weapon_payload = _weapon_payload(current_item)
			if not current_weapon_payload.is_empty():
				current_weapon_payload["slot"] = _slot_name(int(equipment_manager.current_slot))
				loadout_payload = current_weapon_payload.duplicate(true)

	var stats: Dictionary = player_stats[peer_id]
	var has_changed := false
	var identifier := _player_identifier(peer_id)

	if stats.get("player_identifier", "") != identifier:
		stats["player_identifier"] = identifier
		has_changed = true
	if stats.get("loadout", {}) != loadout_payload:
		stats["loadout"] = loadout_payload
		has_changed = true
	if stats.get("current_weapon", {}) != current_weapon_payload:
		stats["current_weapon"] = current_weapon_payload
		has_changed = true

	player_stats[peer_id] = stats
	return has_changed

func _refresh_all_player_combat_data() -> bool:
	var has_any_change := false
	for peer_id in player_stats.keys():
		if _refresh_player_combat_data(int(peer_id)):
			has_any_change = true
	return has_any_change

func _player_identifier(peer_id: int) -> String:
	var multiplayer_manager := _get_multiplayer_manager()
	if multiplayer_manager and multiplayer_manager.has_method("get_player_name"):
		var player_name := String(multiplayer_manager.get_player_name(peer_id)).strip_edges()
		if player_name != "":
			return player_name
	return str(peer_id)

func _get_multiplayer_manager() -> Node:
	var nodes := get_tree().get_nodes_in_group("multiplayer_manager")
	if nodes.is_empty():
		return null
	return nodes[0]

func _sync_match_state_to_peer(peer_id: int) -> void:
	_update_stats.rpc_id(peer_id, player_stats)
	if match_ended:
		_update_match_timer_ui.rpc_id(peer_id, "")
		_show_match_end_ui_and_return.rpc_id(peer_id, winning_peer_id, player_stats)
		return
	_update_match_timer_ui.rpc_id(peer_id, _format_match_time(match_time_remaining))

func _end_match(winner_id: int, reason: String) -> void:
	if match_ended:
		return

	if winner_id <= 0:
		winner_id = _resolve_time_limit_winner_id()

	match_ended = true
	winning_peer_id = winner_id

	_refresh_all_player_combat_data()
	var final_stats := player_stats.duplicate(true)

	print("Match ended by %s. Winner: %s" % [reason, _winner_name(winner_id)])
	_update_stats.rpc(final_stats)
	_update_match_timer_ui.rpc("")
	_show_match_end_ui_and_return.rpc(winner_id, final_stats)

@rpc("call_local", "reliable")
func _update_match_timer_ui(text: String) -> void:
	_update_match_timer_ui_local(text)

func _update_match_timer_ui_local(text: String) -> void:
	if is_instance_valid(match_timer_label):
		match_timer_label.text = text

func _has_active_multiplayer_peer() -> bool:
	var mp := get_multiplayer()
	if mp == null:
		return false
	var peer := mp.multiplayer_peer
	if peer == null:
		return false
	if peer.has_method("get_connection_status"):
		return peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED
	return true

@rpc("call_local", "reliable")
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

func _clear_local_fow_camera_reference() -> void:
	var mask_viewport := MaskViewProvider.viewport
	if is_instance_valid(mask_viewport):
		mask_viewport.set("player_camera", null)
		mask_viewport.set("player", null)

func _change_to_post_match_scene() -> bool:
	if not is_inside_tree():
		return false
	_clear_local_fow_camera_reference()
	var multiplayer_manager := _get_multiplayer_manager()
	if multiplayer_manager and multiplayer_manager.has_method("return_to_lobby_after_match"):
		multiplayer_manager.call_deferred("return_to_lobby_after_match")
		return true
	var target_scene_path := post_match_scene_path.strip_edges()
	if target_scene_path != "":
		var error := get_tree().change_scene_to_file(target_scene_path)
		if error != OK:
			push_warning("Failed to change to post match scene '%s': %s" % [target_scene_path, error])
			return false
		return true
	return false

func _try_execute_post_match_transition() -> void:
	if post_match_transition_deadline_msec < 0:
		return
	if Time.get_ticks_msec() < post_match_transition_deadline_msec:
		return
	if post_match_scene_change_requested:
		return
	post_match_scene_change_requested = true
	var changed := _change_to_post_match_scene()
	if not changed:
		post_match_scene_change_requested = false

func _format_match_time(total_seconds: float) -> String:
	var clamped_seconds := maxi(0, int(ceil(total_seconds)))
	var minutes := clamped_seconds / 60
	var seconds := clamped_seconds % 60
	return "%02d:%02d" % [minutes, seconds]

func _winner_name(winner_id: int) -> String:
	if winner_id <= 0:
		return "No one"

	if player_stats.has(winner_id):
		var winner_stats: Dictionary = player_stats[winner_id]
		var identifier := String(winner_stats.get("player_identifier", "")).strip_edges()
		if identifier != "":
			return identifier

	return _player_identifier(winner_id)

func _local_match_result_text(winner_id: int) -> String:
	if winner_id > 0 and _has_active_multiplayer_peer() and multiplayer.get_unique_id() == winner_id:
		return "VICTORY"
	return "DEFEAT"

func _resolve_time_limit_winner_id() -> int:
	var best_peer_id := -1
	var best_kills := -1
	var has_tie := false

	for peer_id_variant in player_stats.keys():
		var peer_id := int(peer_id_variant)
		var stats: Dictionary = player_stats.get(peer_id, {})
		var kills := int(stats.get("kills", 0))
		if kills > best_kills:
			best_kills = kills
			best_peer_id = peer_id
			has_tie = false
		elif kills == best_kills:
			has_tie = true

	if has_tie:
		return -1
	return best_peer_id
