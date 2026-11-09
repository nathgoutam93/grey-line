extends "res://tests/net/net_test_base.gd"

const WALL := preload("res://tests/fixtures/test_wall.tscn")
var _bot_id := 0
var _spectator_ally := 0
var _walls: DestructibleWalls

func _mode() -> RoundGameMode:
	return game_mode() as RoundGameMode

func run_host_lobby() -> void:
	_bot_id = MultiplayerSession.add_bot()
	_spectator_ally = MultiplayerSession.add_bot() # Temporary fourth player for remote spectating coverage.
	MultiplayerSession.set_team(1, Teams.BRAVO)
	MultiplayerSession.set_team(client_peer(), Teams.ALPHA)
	MultiplayerSession.set_team(_bot_id, Teams.BRAVO)
	MultiplayerSession.set_team(_spectator_ally, Teams.ALPHA)
	get_tree().node_added.connect(_configure_mode)
	var picker := get_tree().current_scene.find_child("CycleMap", true, false) as Button
	picker.pressed.emit()
	check("host_map_picker_selects_rounds", MultiplayerSession.map_scene_path == MultiplayerSession.MAPS[1], "host button selected the rounds variant")
	await capture_frame("map-picker")
	send("lobby_probe")
	var report: Variant = await wait_for("lobby_report", 5.0)
	check("map_selection_replicates_and_rejects_client_changes", report is Dictionary and report.get("map") == MultiplayerSession.MAPS[1] and report.get("guarded", false), "client received selected mode and could not change it")

func _configure_mode(node: Node) -> void:
	var mode := node as RoundGameMode
	if mode == null:
		return
	mode.freeze_seconds = 2.0
	mode.round_seconds = 6.0
	mode.objective_hold_seconds = 2.0
	mode.rounds_to_win = 2
	get_tree().node_added.disconnect(_configure_mode)

func _spawn_wall(position: Vector2) -> void:
	_walls = WALL.instantiate() as DestructibleWalls
	_walls.name = "RoundTestWall"
	_walls.position = position
	_mode().map.add_child(_walls)

func on_message(key: String, value: Variant) -> void:
	if role != "client":
		return
	if key == "lobby_probe":
		_lobby_probe()
	elif key == "fixture":
		_spawn_wall(value)
		send("fixture_ready")
	elif key == "freeze_hold":
		_hold_during_freeze()
	elif key.begins_with("probe:"):
		_reply_state(key.trim_prefix("probe:"), value)

func _lobby_probe() -> void:
	await wait_until(func(): return MultiplayerSession.map_scene_path == MultiplayerSession.MAPS[1], 2.0)
	MultiplayerSession.set_selected_map_scene_path(MultiplayerSession.MAPS[0])
	await capture_frame("lobby")
	send("lobby_report", {"map": MultiplayerSession.map_scene_path, "guarded": MultiplayerSession.map_scene_path == MultiplayerSession.MAPS[1]})

func _hold_during_freeze() -> void:
	var start := local_player().global_position
	Input.action_press("move_up")
	await hold(0.45)
	Input.action_release("move_up")
	send("freeze_held", {"moved": local_player().global_position.distance_to(start)})

func _reply_state(tag: String, options: Dictionary) -> void:
	await wait_until(func(): return _mode() != null, 3.0)
	var mode := _mode()
	if mode == null:
		send("result:" + tag, {})
		send("captured:" + tag)
		return
	if tag == "ready":
		await wait_until(func(): return local_player() != null, 3.0)
	if options.has("phase"):
		await wait_until(func(): return mode.phase == int(options.phase), 1.0)
	if options.has("spectate"):
		await wait_until(func(): return mode.local_spectate_target == int(options.spectate), 1.0)
		mode.request_spectate_next.rpc_id(1)
	if options.has("tiles"):
		await wait_until(func(): return _walls != null and _walls.get_used_cells().size() == int(options.tiles), 1.0)
	if options.get("progress", false):
		await wait_until(func(): return mode.objective_bar.visible and mode.objective_bar.value > 0.0, 1.0)
	var mask_owner := 0
	if is_instance_valid(MaskViewProvider.viewport) and is_instance_valid(MaskViewProvider.viewport.player):
		mask_owner = MaskViewProvider.viewport.player.owner_peer_id
	var target := player(mode.local_spectate_target)
	send("result:" + tag, {
		"phase": mode.phase, "winner": mode.winner_team, "round": mode.round_index,
		"scores": mode.team_scores.duplicate(), "attacking": mode.attacking_team,
		"seconds": mode.displayed_seconds(), "result": mode.match_result_label.text,
		"role": mode.role_label.text, "bar": mode.objective_bar.visible,
		"progress": mode.objective_bar.value, "spectate": mode.local_spectate_target,
		"mask_owner": mask_owner, "camera": target.camera.is_current() if target != null else false,
		"tiles": _walls.get_used_cells().size() if is_instance_valid(_walls) else -1,
	})
	await capture_frame(tag)
	send("captured:" + tag)

func _sample(tag: String, options: Dictionary = {}) -> Dictionary:
	send("probe:" + tag, options)
	var report: Variant = await wait_for("result:" + tag, 5.0)
	if report is Dictionary:
		report["host_seconds"] = _mode().displayed_seconds()
	if await wait_for("captured:" + tag, 5.0) == null:
		results.fail("sample", "client checkpoint %s missing" % tag)
	return report if report is Dictionary else {}

func _phase(next: RoundGameMode.Phase, timeout: float = 10.0) -> bool:
	var ready := await wait_until(func(): return _mode().phase == next, timeout)
	if not ready:
		finish_with_failure("phase", "expected %s, got %s" % [RoundGameMode.Phase.keys()[next], RoundGameMode.Phase.keys()[_mode().phase]])
	return ready

func run_host() -> void:
	var mode := _mode()
	await _sample("ready")
	if mode.round_index != 0:
		finish_with_failure("setup", "initial round finished before peers were ready")
		return
	# Align the short test freeze after both renderers and input owners are ready.
	mode._publish_phase(RoundGameMode.Phase.FREEZE, mode.freeze_seconds)
	_spawn_wall(Vector2(-2400, -2100))
	send("fixture", Vector2(-2400, -2100))
	if await wait_for("fixture_ready", 3.0) == null:
		finish_with_failure("setup", "client wall fixture missing")
		return
	var client_id := client_peer()
	var start := player(client_id).global_position
	send("freeze_hold")
	var held: Variant = await wait_for("freeze_held", 3.0)
	check("freeze_blocks_movement", held is Dictionary and float(held.get("moved", INF)) < 0.1 and player(client_id).global_position.distance_to(start) < 0.1 and mode.phase == RoundGameMode.Phase.FREEZE, "client prediction and server position stayed fixed under held movement")
	await _sample("freeze", {"phase": RoundGameMode.Phase.FREEZE})
	if not await _phase(RoundGameMode.Phase.LIVE):
		return
	var service := DestructionService.current(get_tree())
	for cell in [Vector2i(0, 4), Vector2i(0, 5)]:
		service.apply_cell_damage(_walls, cell, 40, DestructionMaterial.KIND_BULLET)
	await _sample("breached", {"tiles": 10})
	player(1).health_component.take_damage(30, client_id)
	(player(1).equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance).ammo_in_mag = 1
	player(client_id).health_component.take_damage(500, 1)
	var spectating := await _sample("spectating", {"spectate": _spectator_ally})
	check("dead_client_spectates_teammate", spectating.get("spectate") == _spectator_ally and spectating.get("mask_owner") == _spectator_ally and spectating.get("camera", false) and mode.spectate_target.get(client_id) == _spectator_ally, "remote dead viewer follows a living ally's camera and fog")
	await hold(0.2)
	check("no_respawn_during_live", mode.phase == RoundGameMode.Phase.LIVE and player(client_id) == null and not mode.spawning.spawning_enabled and mode.team_scores[Teams.BRAVO] == 0, "dead client stayed out while ally lived; kills did not add round points")
	player(_spectator_ally).health_component.take_damage(500, 1)
	var won := await _sample("elimination", {"phase": RoundGameMode.Phase.ROUND_END})
	var first_scores: Dictionary = won.get("scores", {})
	check("elimination_ends_round", mode.winner_team == Teams.BRAVO and won.get("winner") == Teams.BRAVO and first_scores.get(Teams.BRAVO) == 1 and first_scores.get(Teams.ALPHA) == 0, "eliminating every opponent awarded one Bravo round on both peers")
	MultiplayerSession.remove_bot(_spectator_ally)
	if not await _phase(RoundGameMode.Phase.FREEZE):
		return
	await hold(0.2) # Default loadouts are constructed after player readiness.
	var reset := await _sample("reset", {"tiles": 12})
	var fresh := true
	for id in [1, client_id, _bot_id]:
		var actor := player(id)
		if actor == null:
			fresh = false
			continue
		var pool := "AttackerSpawns" if mode.role_of(actor.team) == RoundGameMode.Role.ATTACK else "DefenderSpawns"
		var at_spawn := false
		for point in mode.spawn_point_container.get_node(pool).get_children():
			at_spawn = at_spawn or actor.global_position.distance_to(point.global_position) < 2.0
		var rifle := actor.equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance
		fresh = fresh and at_spawn and actor.health_component.current_health == 100 and rifle != null and rifle.ammo_in_mag == rifle.data.mag_size
	check("round_reset", fresh and _walls.get_used_cells().size() == 12 and reset.get("tiles") == 12 and mode.attacking_team == Teams.BRAVO, "all three lives, health, ammo, role spawns and breached cells reset at halftime")
	if not await _phase(RoundGameMode.Phase.LIVE):
		return
	var timer := await _sample("timer", {"phase": RoundGameMode.Phase.LIVE})
	check("client_timer_matches_server", absi(int(timer.get("seconds", -100)) - int(timer.get("host_seconds", 100))) <= 1 and String(timer.get("role", "")).contains("DEFEND"), "client countdown within one second and Alpha now defends")
	if not await _phase(RoundGameMode.Phase.ROUND_END, 8.0):
		return
	var timeout := await _sample("timeout", {"phase": RoundGameMode.Phase.ROUND_END})
	check("timeout_goes_to_defenders", mode.winner_team == Teams.ALPHA and timeout.get("winner") == Teams.ALPHA and mode.team_scores[Teams.ALPHA] == 1 and mode.team_scores[Teams.BRAVO] == 1, "uncontested timeout gave defending Alpha the 1–1 equalizer")
	if not await _phase(RoundGameMode.Phase.FREEZE):
		return
	if not await _phase(RoundGameMode.Phase.LIVE):
		return
	player(1).health_component.take_damage(500, client_id)
	var puppet := player(_bot_id)
	puppet.global_position = mode.objective.global_position
	bot(_bot_id).stop()
	await capture_frame("host-spectating")
	var progress := await _sample("capture", {"progress": true})
	check("objective_progress_replicates", progress.get("bar", false) and float(progress.get("progress", 0.0)) > 0.0, "uncontested bot capture updates the client bar")
	if not await _phase(RoundGameMode.Phase.ROUND_END, 4.0):
		return
	check("objective_capture", mode.winner_team == Teams.BRAVO and mode.objective_progress >= 1.0, "attacking Bravo bot completed the hold alone")
	if not await _phase(RoundGameMode.Phase.MATCH_END, 7.0):
		return
	var ended := await _sample("match-end", {"phase": RoundGameMode.Phase.MATCH_END})
	check("sides_swap_and_match_ends", mode.attacking_team == Teams.BRAVO and mode.team_scores[Teams.BRAVO] == 2 and mode.match_result_label.text == "VICTORY" and ended.get("result") == "DEFEAT", "roles swapped once; first to two produced correct host/client results")
