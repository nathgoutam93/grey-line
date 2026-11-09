extends MatchGameMode
class_name RoundGameMode

enum Phase { WAITING, FREEZE, LIVE, ROUND_END, MATCH_END }
enum Role { ATTACK, DEFEND }

@export var rounds_to_win := 4
@export var freeze_seconds := 5.0
@export var round_seconds := 120.0
@export var round_end_seconds := 5.0
@export var objective_hold_seconds := 10.0
@export var post_match_result_duration_seconds := 5.0
@export var player_scene: PackedScene
@export var map: Node2D
@export var spawn_point_container: Node
@export var leaderboard: DeathmatchLeaderboard
@export var match_timer_label: Label
@export var timer_touch_toggle_button: TouchScreenButton
@export var match_result_overlay: Control
@export var match_result_label: Label
@export var leave_game_button: TouchScreenButton

@onready var spawning: MatchPlayerSpawner = $Spawning
@onready var scoreboard: MatchScoreboard = $Scoreboard

var phase: Phase = Phase.WAITING
var round_index := 0 # Number of finished rounds.
var attacking_team := Teams.ALPHA
var objective_progress := 0.0
var phase_end_tick := 0
var local_end_tick := 0
var winner_team := Teams.NONE
var team_scores := {Teams.ALPHA: 0, Teams.BRAVO: 0}
var _clock_tick := 0
var _roles_swapped := false
var _starting_round := false
var _elimination_pending := false
var _transition_requested := false
var _stats_visible := false
var _last_objective_send_tick := 0
var objective: ObjectiveZone
var spectate_target: Dictionary = {}
var local_spectate_target := 0
var _view_instance_id := 0
var round_score_label: Label
var role_label: Label
var phase_label: Label
var objective_bar: ProgressBar
var spectate_button: Button

func _ready() -> void:
	add_to_group("game_mode")
	_clock_tick = NetworkTick.tick
	_build_round_hud()
	if timer_touch_toggle_button != null:
		timer_touch_toggle_button.pressed.connect(_toggle_stats)
	if leave_game_button != null:
		leave_game_button.pressed.connect(_confirm_leave)
	if map == null or spawn_point_container == null:
		return
	spawning.setup(map, spawn_point_container, player_scene)
	spawning.spawning_enabled = false
	scoreboard.setup(map, leaderboard, 0, true)
	scoreboard.round_scoring = true
	scoreboard.team_scores = team_scores
	spawning.player_setup.connect(scoreboard.track_player)
	spawning.player_setup.connect(_on_player_setup)
	for node in get_tree().get_nodes_in_group(ObjectiveZone.GROUP):
		var zone := node as ObjectiveZone
		if zone != null and map.is_ancestor_of(zone):
			objective = zone
			break
	if multiplayer.is_server():
		NetworkTick.tick_started.connect(_on_network_tick)
		MultiplayerSession.player_left.connect(_on_peer_disconnected)
		MultiplayerSession.player_dropped.connect(_on_player_dropped)
		MultiplayerSession.player_rejoined.connect(_on_player_rejoined)
		MultiplayerSession.bot_removed.connect(_on_peer_disconnected)
	else:
		multiplayer.server_disconnected.connect(_return_to_lobby)
		_request_initial_state.call_deferred()

func _exit_tree() -> void:
	if NetworkTick.tick_started.is_connected(_on_network_tick):
		NetworkTick.tick_started.disconnect(_on_network_tick)

func role_of(team: int) -> Role:
	return Role.ATTACK if team == attacking_team else Role.DEFEND

func defending_team() -> int:
	return Teams.BRAVO if attacking_team == Teams.ALPHA else Teams.ALPHA

func is_actions_locked() -> bool:
	return phase != Phase.LIVE

func is_movement_locked() -> bool:
	return phase in [Phase.WAITING, Phase.FREEZE, Phase.MATCH_END]

func allows_damage() -> bool:
	return phase in [Phase.FREEZE, Phase.LIVE]

func uses_round_respawns() -> bool:
	return true

func spawn_pool_for(team: int) -> int:
	return Teams.ALPHA if role_of(team) == Role.ATTACK else Teams.BRAVO

func configure_player(player: PlayerController) -> void:
	player.actions_locked = is_actions_locked()
	if player.hud != null:
		player.hud.kill_feed_container.offset_top = 210.0

func _roster_ready() -> bool:
	var counts := {Teams.ALPHA: 0, Teams.BRAVO: 0}
	for id in MultiplayerSession.player_names:
		if MultiplayerSession.is_peer_connected(int(id)):
			var team := MultiplayerSession.get_team(int(id))
			if counts.has(team):
				counts[team] += 1
	return counts[Teams.ALPHA] > 0 and counts[Teams.BRAVO] > 0

func _on_network_tick(tick: int) -> void:
	if not multiplayer.is_server() or _starting_round:
		return
	_clock_tick = tick
	_refresh_spectators()
	match phase:
		Phase.WAITING:
			if _roster_ready():
				_start_round()
		Phase.FREEZE:
			if tick >= phase_end_tick:
				_publish_phase(Phase.LIVE, round_seconds)
		Phase.LIVE:
			if _evaluate_elimination():
				return
			_tick_objective()
			if phase != Phase.LIVE:
				return
			if tick >= phase_end_tick:
				_finish_round(defending_team())
		Phase.ROUND_END:
			if tick >= phase_end_tick:
				if int(team_scores.get(winner_team, 0)) >= rounds_to_win:
					_publish_phase(Phase.MATCH_END, post_match_result_duration_seconds, winner_team)
				else:
					_start_round()

func _start_round() -> void:
	if _starting_round:
		return
	if not _roster_ready():
		_publish_phase(Phase.WAITING, 0.0)
		return
	if not _roles_swapped and round_index == rounds_to_win - 1:
		attacking_team = defending_team()
		_roles_swapped = true
	objective_progress = 0.0
	for peer in spectate_target.keys():
		_send_spectate_target(int(peer), int(peer))
	spectate_target.clear()
	_starting_round = true
	var destruction := DestructionService.current(get_tree())
	if destruction != null:
		destruction.reset_all()
	await spawning.respawn_everyone()
	if not is_inside_tree():
		return
	_clock_tick = NetworkTick.tick
	_publish_phase(Phase.FREEZE, freeze_seconds)
	_starting_round = false

func _finish_round(winner: int) -> void:
	if not multiplayer.is_server() or phase not in [Phase.FREEZE, Phase.LIVE]:
		return
	team_scores[winner] = int(team_scores.get(winner, 0)) + 1
	round_index += 1
	scoreboard.broadcast_stats()
	_publish_phase(Phase.ROUND_END, round_end_seconds, winner)

func _living_counts() -> Vector2i:
	var counts := Vector2i.ZERO
	if map == null:
		return counts
	for node in get_tree().get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player == null or player.is_dead or not map.is_ancestor_of(player):
			continue
		# A dropped player's body stays in the round (frozen, killable).
		if not MultiplayerSession.holds_slot(player.owner_peer_id):
			continue
		if player.team == attacking_team:
			counts.x += 1
		elif player.team == defending_team():
			counts.y += 1
	return counts

func _evaluate_elimination() -> bool:
	var counts := _living_counts()
	if counts == Vector2i.ZERO:
		# Mutual elimination: the attackers did not complete the objective.
		_finish_round(defending_team())
		return true
	if counts.x == 0 and counts.y > 0:
		_finish_round(defending_team())
		return true
	if counts.y == 0 and counts.x > 0:
		_finish_round(attacking_team)
		return true
	return false

func _tick_objective() -> void:
	if not is_instance_valid(objective):
		return
	var counts := objective.living_counts(attacking_team)
	if counts.x <= 0 or counts.y > 0:
		return
	objective_progress = minf(1.0, objective_progress + NetworkTick.get_tick_delta() / maxf(objective_hold_seconds, 0.001))
	if _clock_tick - _last_objective_send_tick >= ceili(NetworkTick.tick_rate / 5.0) or objective_progress >= 1.0:
		_last_objective_send_tick = _clock_tick
		if not multiplayer.get_peers().is_empty():
			_objective_progress_event.rpc(objective_progress)
	if objective_progress >= 1.0:
		_finish_round(attacking_team)

func _publish_phase(next: Phase, seconds: float, winner: int = Teams.NONE) -> void:
	var end_tick := _clock_tick + maxi(0, ceili(seconds * NetworkTick.tick_rate))
	if multiplayer.get_peers().is_empty():
		_phase_event(next, _clock_tick, end_tick, round_index, attacking_team, team_scores, winner)
	else:
		_phase_event.rpc(next, _clock_tick, end_tick, round_index, attacking_team, team_scores, winner)

@rpc("authority", "call_local", "reliable", 2)
func _phase_event(next: int, server_tick: int, end_tick: int, index: int, attack: int, scores: Dictionary, winner: int) -> void:
	phase = next as Phase
	phase_end_tick = end_tick
	local_end_tick = NetworkTick.tick + (end_tick - server_tick)
	round_index = index
	attacking_team = attack
	team_scores = scores.duplicate()
	scoreboard.team_scores = team_scores
	winner_team = winner
	if phase in [Phase.WAITING, Phase.FREEZE]:
		objective_progress = 0.0
	for node in get_tree().get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player != null:
			configure_player(player)
	if phase == Phase.MATCH_END:
		MultiplayerSession.mark_match_over()
		spawning.spawning_enabled = false
		scoreboard.active = false
		_stats_visible = false
		if match_result_overlay != null:
			match_result_overlay.show()
		if match_result_label != null:
			match_result_label.text = "VICTORY" if MultiplayerSession.get_team(multiplayer.get_unique_id()) == winner else "DEFEAT"
	_refresh_hud()

@rpc("authority", "call_local", "unreliable", 2)
func _objective_progress_event(progress: float) -> void:
	if phase == Phase.LIVE:
		objective_progress = clampf(progress, 0.0, 1.0)

func displayed_seconds() -> int:
	var remaining := phase_end_tick - _clock_tick if multiplayer.is_server() else local_end_tick - NetworkTick.tick
	return maxi(0, ceili(float(remaining) / NetworkTick.tick_rate))

func _process(_delta: float) -> void:
	_refresh_hud()
	_update_spectate_view()
	if phase == Phase.MATCH_END and displayed_seconds() == 0:
		_return_to_lobby()

func _refresh_hud() -> void:
	if match_timer_label != null:
		var seconds := displayed_seconds()
		match_timer_label.text = "--:--" if phase == Phase.WAITING else "%02d:%02d" % [seconds / 60, seconds % 60]
	if leaderboard != null:
		leaderboard.visible = _stats_visible and phase != Phase.MATCH_END
	if leave_game_button != null:
		leave_game_button.visible = _stats_visible and phase != Phase.MATCH_END
	if round_score_label == null:
		return
	round_score_label.text = "ALPHA %d  –  %d BRAVO" % [team_scores[Teams.ALPHA], team_scores[Teams.BRAVO]]
	var team := MultiplayerSession.get_team(multiplayer.get_unique_id())
	role_label.text = "%s  /  %s" % [Teams.display_name(team).to_upper(), "ATTACK" if role_of(team) == Role.ATTACK else "DEFEND"] if team != Teams.NONE else "SPECTATOR"
	role_label.modulate = Teams.COLORS.get(team, Color.WHITE)
	match phase:
		Phase.WAITING: phase_label.text = "Waiting for players"
		Phase.FREEZE: phase_label.text = "ROUND %d  /  GET READY" % (round_index + 1)
		Phase.LIVE: phase_label.text = "ROUND %d  /  LIVE" % (round_index + 1)
		Phase.ROUND_END: phase_label.text = Teams.display_name(winner_team).to_upper() + " WINS THE ROUND"
		Phase.MATCH_END: phase_label.text = "MATCH COMPLETE"
	objective_bar.visible = objective_progress > 0.0 and phase in [Phase.LIVE, Phase.ROUND_END]
	objective_bar.value = objective_progress
	spectate_button.visible = local_spectate_target != 0 and _living_player(multiplayer.get_unique_id()) == null
	spectate_button.text = "Watching %s  ·  Next teammate [F]" % MultiplayerSession.get_player_name(local_spectate_target)

func _build_round_hud() -> void:
	var panel := PanelContainer.new()
	panel.name = "RoundHud"
	$MatchResultLayer/Control.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	panel.offset_left = -235
	panel.offset_right = 235
	panel.offset_top = 46
	panel.offset_bottom = 166
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.07, 0.1, 0.94)
	style.border_color = Color(0.2, 0.32, 0.37)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	panel.add_child(column)
	round_score_label = _hud_label("RoundScore", 23)
	role_label = _hud_label("RoundRole", 15)
	phase_label = _hud_label("RoundPhase", 13)
	column.add_child(round_score_label)
	column.add_child(role_label)
	column.add_child(phase_label)
	objective_bar = ProgressBar.new()
	objective_bar.name = "ObjectiveProgress"
	objective_bar.max_value = 1.0
	objective_bar.step = 0.0
	objective_bar.show_percentage = false
	objective_bar.custom_minimum_size.y = 12
	objective_bar.tooltip_text = "Objective capture"
	column.add_child(objective_bar)
	spectate_button = Button.new()
	spectate_button.name = "SpectateNext"
	spectate_button.pressed.connect(_on_spectate_next_pressed)
	column.add_child(spectate_button)
	_refresh_hud()

func _hud_label(label_name: String, size: int) -> Label:
	var label := Label.new()
	label.name = label_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	return label

func _on_spectate_next_pressed() -> void:
	if multiplayer.is_server():
		cycle_spectate(multiplayer.get_unique_id())
	else:
		request_spectate_next.rpc_id(1)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pickup") and _living_player(multiplayer.get_unique_id()) == null:
		if multiplayer.is_server():
			cycle_spectate(multiplayer.get_unique_id())
		else:
			request_spectate_next.rpc_id(1)
		get_viewport().set_input_as_handled()
	if event.is_action_pressed("stats"):
		_toggle_stats()
		get_viewport().set_input_as_handled()

func _toggle_stats() -> void:
	_stats_visible = not _stats_visible

func _return_to_lobby() -> void:
	if _transition_requested:
		return
	_transition_requested = true
	if is_instance_valid(MaskViewProvider.viewport):
		MaskViewProvider.viewport.player_camera = null
		MaskViewProvider.viewport.player = null
	MultiplayerSession.return_to_lobby_after_match.call_deferred()

func _on_player_setup(_id: int, player: PlayerController) -> void:
	configure_player(player)
	player.health_component.die_detailed.connect(_on_player_eliminated)

func _on_player_eliminated(_killer: int, _headshot: bool) -> void:
	# Defer to the end of the frame so every death from one blast counts:
	# resolving on the first death would end the round, block the remaining
	# damage and pick the winner by player iteration order.
	if not _elimination_pending and not _starting_round and phase in [Phase.FREEZE, Phase.LIVE]:
		_elimination_pending = true
		_resolve_pending_elimination.call_deferred()
	_refresh_spectators()

func _resolve_pending_elimination() -> void:
	_elimination_pending = false
	if not _starting_round and phase in [Phase.FREEZE, Phase.LIVE]:
		_evaluate_elimination()

func _confirm_leave() -> void:
	LeaveMatchDialog.confirm(self, func():
		_transition_requested = true
		if is_instance_valid(MaskViewProvider.viewport):
			MaskViewProvider.viewport.player_camera = null
			MaskViewProvider.viewport.player = null
		MultiplayerSession.leave_match())

func _on_peer_disconnected(id: int) -> void:
	scoreboard.remove_peer(id)
	spectate_target.erase(id)
	var player := map.get_node_or_null(str(id)) as PlayerController
	if player != null:
		player.queue_free()

## The body stays where it is for the rest of this round: frozen, killable and
## counted as alive. The player gets no new body until they rejoin.
func _on_player_dropped(id: int) -> void:
	spectate_target.erase(id)
	var player := _living_player(id)
	if player != null:
		player.net_sync.owner_dropped = true

## Back mid-round: spectate teammates and play from the next round.
func _on_player_rejoined(old_id: int, new_id: int) -> void:
	scoreboard.rekey_peer(old_id, new_id)
	spectate_target.erase(old_id)
	_refresh_spectators()

func _request_initial_state() -> void:
	await get_tree().create_timer(0.75).timeout
	if is_inside_tree() and NetUtil.has_active_peer(multiplayer):
		spawning.request_resync()
		request_state.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable", 2)
func request_state() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not multiplayer.get_peers().has(sender) or not MultiplayerSession.player_names.has(sender):
		return
	_phase_event.rpc_id(sender, phase, NetworkTick.tick, phase_end_tick, round_index, attacking_team, team_scores, winner_team)
	_objective_progress_event.rpc_id(sender, objective_progress)
	scoreboard.send_stats_to(sender)
	if spectate_target.has(sender):
		_send_spectate_target(sender, int(spectate_target[sender]))

func _living_player(peer: int) -> PlayerController:
	if not is_instance_valid(map):
		return null
	var player := map.get_node_or_null(str(peer)) as PlayerController
	return player if player != null and not player.is_dead else null

func spectator_player_for(peer: int) -> PlayerController:
	return _living_player(int(spectate_target.get(peer, 0)))

func _spectate_candidates(peer: int) -> Array[int]:
	var candidates: Array[int] = []
	var team := MultiplayerSession.get_team(peer)
	if team == Teams.NONE:
		return candidates
	for node in map.get_children():
		var player := node as PlayerController
		if player != null and not player.is_dead and player.team == team and player.owner_peer_id != peer:
			if MultiplayerSession.is_peer_connected(player.owner_peer_id):
				candidates.append(player.owner_peer_id)
	candidates.sort()
	return candidates

func _refresh_spectators() -> void:
	if not multiplayer.is_server() or not is_instance_valid(map) or phase == Phase.WAITING:
		return
	var viewers: Array[int] = [1]
	viewers.append_array(multiplayer.get_peers())
	for peer in viewers:
		if _living_player(peer) != null:
			if spectate_target.has(peer):
				spectate_target.erase(peer)
				_send_spectate_target(peer, peer)
			continue
		var candidates := _spectate_candidates(peer)
		var target := int(spectate_target.get(peer, 0))
		if candidates.has(target):
			continue
		var next := candidates[0] if not candidates.is_empty() else 0
		if not spectate_target.has(peer) or target != next:
			spectate_target[peer] = next
			_send_spectate_target(peer, next)

func cycle_spectate(peer: int) -> void:
	if not multiplayer.is_server() or _living_player(peer) != null:
		return
	var candidates := _spectate_candidates(peer)
	if candidates.is_empty():
		return
	var current := candidates.find(int(spectate_target.get(peer, 0)))
	var target := candidates[(current + 1) % candidates.size()]
	spectate_target[peer] = target
	_send_spectate_target(peer, target)

@rpc("any_peer", "call_remote", "reliable", 2)
func request_spectate_next() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not multiplayer.get_peers().has(sender):
		return
	cycle_spectate(sender)

func _send_spectate_target(peer: int, target: int) -> void:
	if peer == multiplayer.get_unique_id():
		_spectate_event(target)
	elif multiplayer.get_peers().has(peer):
		_spectate_event.rpc_id(peer, target)

@rpc("authority", "call_remote", "reliable", 2)
func _spectate_event(target: int) -> void:
	local_spectate_target = target
	_view_instance_id = 0
	_update_spectate_view()

func _update_spectate_view() -> void:
	if map == null:
		return
	var own := map.get_node_or_null(str(multiplayer.get_unique_id())) as PlayerController
	if own != null and not own.is_dead:
		local_spectate_target = 0
		_view_instance_id = 0
		if is_instance_valid(MaskViewProvider.viewport) and is_instance_valid(MaskViewProvider.viewport.los):
			MaskViewProvider.viewport.los.enabled = true
		return
	if own != null:
		own.hud.hide()
	var target := _living_player(local_spectate_target)
	if target == null:
		if is_instance_valid(MaskViewProvider.viewport):
			MaskViewProvider.viewport.player = null
			MaskViewProvider.viewport.player_camera = null
			if is_instance_valid(MaskViewProvider.viewport.los):
				MaskViewProvider.viewport.los.enabled = false
		return
	if target.get_instance_id() == _view_instance_id:
		return
	_view_instance_id = target.get_instance_id()
	target.camera.enabled = true
	target.camera.make_current()
	target.audio_listner.make_current()
	if is_instance_valid(MaskViewProvider.viewport):
		MaskViewProvider.viewport.player = target
		MaskViewProvider.viewport.player_camera = target.camera
		if is_instance_valid(MaskViewProvider.viewport.los):
			MaskViewProvider.viewport.los.enabled = true
