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
var _transition_requested := false
var _stats_visible := false
var _last_objective_send_tick := 0
var objective: ObjectiveZone

func _ready() -> void:
	add_to_group("game_mode")
	_clock_tick = NetworkTick.tick
	if timer_touch_toggle_button != null:
		timer_touch_toggle_button.pressed.connect(_toggle_stats)
	if leave_game_button != null:
		leave_game_button.pressed.connect(_return_to_lobby)
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
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
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
		if not MultiplayerSession.is_peer_connected(player.owner_peer_id):
			continue
		if player.team == attacking_team:
			counts.x += 1
		elif player.team == defending_team():
			counts.y += 1
	return counts

func _evaluate_elimination() -> bool:
	var counts := _living_counts()
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
	if phase == Phase.MATCH_END and displayed_seconds() == 0:
		_return_to_lobby()

func _refresh_hud() -> void:
	if match_timer_label != null:
		var seconds := displayed_seconds()
		match_timer_label.text = "Waiting for players" if phase == Phase.WAITING else "%02d:%02d" % [seconds / 60, seconds % 60]
	if leaderboard != null:
		leaderboard.visible = _stats_visible and phase != Phase.MATCH_END
	if leave_game_button != null:
		leave_game_button.visible = _stats_visible and phase != Phase.MATCH_END

func _unhandled_input(event: InputEvent) -> void:
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
	if not _starting_round and phase in [Phase.FREEZE, Phase.LIVE]:
		_evaluate_elimination()

func _on_peer_disconnected(id: int) -> void:
	scoreboard.remove_peer(id)
	var player := map.get_node_or_null(str(id)) as PlayerController
	if player != null:
		player.queue_free()

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
	if sender <= 1 or not multiplayer.get_peers().has(sender):
		return
	_phase_event.rpc_id(sender, phase, NetworkTick.tick, phase_end_tick, round_index, attacking_team, team_scores, winner_team)
	_objective_progress_event.rpc_id(sender, objective_progress)
	scoreboard.send_stats_to(sender)
