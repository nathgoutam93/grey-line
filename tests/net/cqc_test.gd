extends "res://tests/net/net_test_base.gd"

const Builder := preload("res://tools/map_builder.gd")
const Routes := preload("res://tests/helpers/map_route.gd")
const MAP := "res://scenes/maps/cqc_1/cqc_1.tscn"
var _bot_id := 0
var _baseline := 0

func _mode() -> RoundGameMode:
	return game_mode() as RoundGameMode

func _walls() -> DestructibleWalls:
	return _mode().map.get_node("DestructibleWalls") as DestructibleWalls

func _crates() -> Array[BreakableProp]:
	var crates: Array[BreakableProp] = []
	for node in _mode().map.get_node("Props").get_children():
		var crate := node as BreakableProp
		if crate != null:
			crates.append(crate)
	return crates

func _prop_report() -> Dictionary:
	var broken := 0
	var fog_blocking := 0
	for crate in _crates():
		if crate.broken and crate.collision_layer == 0:
			broken += 1
		if not crate._fog_occluders.is_empty() and crate._fog_occluders.all(func(occluder: LightOccluder2D): return occluder.visible):
			fog_blocking += 1
	return {"crates": _crates().size(), "broken": broken, "fog_blocking": fog_blocking}

func run_host_lobby() -> void:
	_bot_id = MultiplayerSession.add_bot()
	MultiplayerSession.set_team(1, Teams.ALPHA)
	MultiplayerSession.set_team(_bot_id, Teams.ALPHA)
	MultiplayerSession.set_team(client_peer(), Teams.BRAVO)
	MultiplayerSession.set_selected_map_scene_path(MAP)
	get_tree().node_added.connect(_configure_mode)
	await capture_frame("lobby")

func _configure_mode(node: Node) -> void:
	var mode := node as RoundGameMode
	if mode == null:
		return
	mode.freeze_seconds = 2.0
	mode.round_seconds = 90.0
	mode.objective_hold_seconds = 2.0
	mode.rounds_to_win = 2
	get_tree().node_added.disconnect(_configure_mode)

func on_message(key: String, value: Variant) -> void:
	if role == "client" and key.begins_with("probe:"):
		_report(key.trim_prefix("probe:"), value)

func _report(tag: String, options: Dictionary) -> void:
	await wait_until(func(): return _mode() != null and _walls().mirror != null, 5.0)
	if options.has("cells"):
		await wait_until(func(): return _walls().get_used_cells().size() == int(options.cells), 3.0)
	if options.has("phase"):
		await wait_until(func(): return _mode().phase == int(options.phase), 3.0)
	if options.has("broken"):
		await wait_until(func(): return _prop_report().broken == int(options.broken), 3.0)
	var states: Array[int] = []
	for door in _mode().map.get_node("Doors").get_children():
		states.append((door as Door).state)
	send("state:" + tag, {"map": MultiplayerSession.map_scene_path, "cells": _walls().get_used_cells().size(), "fog": _walls().mirror.get_used_cells().size(), "doors": states, "phase": _mode().phase, "winner": _mode().winner_team, "scores": _mode().team_scores.duplicate(), "progress": _mode().objective_bar.value, "props": _prop_report()})
	await capture_frame(tag)
	send("captured:" + tag)

func _sample(tag: String, options: Dictionary = {}) -> Dictionary:
	send("probe:" + tag, options)
	var report: Variant = await wait_for("state:" + tag, 6.0)
	if await wait_for("captured:" + tag, 6.0) == null:
		results.fail("capture", "client checkpoint missing: " + tag)
	return report if report is Dictionary else {}

func _follow_route(puppet: PlayerController, path: PackedVector2Array) -> float:
	var start_tick := NetworkTick.tick
	var deadline := start_tick + ceili(32.0 * NetworkTick.tick_rate)
	var index := 1
	while index < path.size() and NetworkTick.tick < deadline and _mode().phase == RoundGameMode.Phase.LIVE:
		var delta := path[index] - puppet.global_position
		if delta.length() < 0.5:
			index += 1
			continue
		var brain := bot(_bot_id)
		brain.aim_dir = delta.normalized()
		brain.move = Vector2(0, -minf(1.0, delta.length() / (puppet.get_speed() * NetworkTick.get_tick_delta())))
		await NetworkTick.tick_started
	bot(_bot_id).stop()
	var elapsed := float(NetworkTick.tick - start_tick) / NetworkTick.tick_rate
	if index != path.size():
		results.fail("route_completion", "stopped at waypoint %d/%d pos=%s target=%s phase=%s" % [index, path.size(), puppet.global_position, path[index], _mode().phase])
	return elapsed

func run_host() -> void:
	var mode := _mode()
	var ready := await _sample("ready")
	check("cqc_selected_on_both_peers", ready.get("map") == MAP and mode != null, "host-selected generated CQC map loaded on both peers")
	_baseline = _walls().get_used_cells().size()
	if not await wait_until(func(): return mode.phase == RoundGameMode.Phase.LIVE, 5.0):
		finish_with_failure("phase", "CQC did not unlock")
		return
	var service := DestructionService.current(get_tree())
	var soft := Vector2i(134, 50)
	var reinforced := Vector2i(188, 64)
	for cell in [soft, reinforced, Vector2i.ZERO]:
		for kind in [DestructionMaterial.KIND_BULLET, DestructionMaterial.KIND_MELEE, DestructionMaterial.KIND_EXPLOSIVE]:
			service.apply_cell_damage(_walls(), cell, 1000, kind)
	service.apply_explosion(_walls().to_global(_walls().map_to_local(soft)) + Vector2(-24, 0), 320.0, 200)
	check("cqc_walls_indestructible", _walls().get_used_cells().size() == _baseline and _walls().has_wall(soft) and _walls().has_wall(reinforced), "soft, reinforced and hard cells ignore bullets, melee and explosions")
	var crates := _crates()
	for crate in crates:
		crate.apply_damage(crate.max_hp, DestructionMaterial.KIND_BULLET)
	var broken := await _sample("crates-broken", {"broken": crates.size()})
	var props: Dictionary = broken.get("props", {})
	check("cqc_crates_break_and_replicate", crates.size() > 0 and props.get("crates") == crates.size() and props.get("broken") == crates.size() and props.get("fog_blocking") == 0 and broken.get("cells") == _baseline and broken.get("fog") == _baseline, "%d crates broke with collision and fog on the client; walls unchanged: %s" % [crates.size(), broken])
	for door in mode.map.get_node("Doors").get_children():
		(door as Door).on_interact(player(1))
	var opened := await _sample("doors-open")
	var states: Array = opened.get("doors", [])
	check("cqc_doors_replicate", states.size() == 9 and states.all(func(value): return value == Door.State.OPEN), "all authored door instances open on the client")
	player(1).health_component.take_damage(500, client_peer())
	await hold(0.1)
	check("cqc_host_spectates_runner", mode.spectate_target.get(1) == _bot_id and player(_bot_id).camera.is_current(), "dead host follows the moving teammate's camera")
	var data := Builder.parse(FileAccess.get_file_as_string("res://scenes/maps/cqc_1/layout.txt"))
	var grid := Routes.grid_for(data)
	var puppet := player(_bot_id)
	var start := Vector2i(puppet.global_position / Builder.CELL)
	var target: Vector2i = data.objective.get_center()
	var path := Routes.simplify(grid.get_point_path(start, target))
	if path.size() < 2:
		finish_with_failure("route", "no route to the objective")
		return
	await capture_frame("approach")
	var elapsed := await _follow_route(puppet, path)
	check("cqc_running_time", elapsed >= 15.0 and elapsed <= 20.0 and puppet.global_position.distance_to(mode.objective.global_position) < 4.0, "normal puppet input reached objective in %.2f s from %s at %.0f px/s" % [elapsed, start, puppet.get_speed()])
	await capture_frame("objective")
	if not await wait_until(func(): return mode.phase == RoundGameMode.Phase.ROUND_END, 4.0):
		finish_with_failure("capture", "runner did not capture")
		return
	var captured := await _sample("captured", {"phase": RoundGameMode.Phase.ROUND_END})
	check("cqc_capture_wins_round", mode.winner_team == Teams.ALPHA and captured.get("winner") == Teams.ALPHA and mode.team_scores[Teams.ALPHA] == 1, "runner captured the authored objective on both peers")
	if not await wait_until(func(): return mode.phase == RoundGameMode.Phase.FREEZE, 8.0):
		finish_with_failure("reset", "next CQC round did not start")
		return
	var reset := await _sample("reset", {"cells": _baseline, "phase": RoundGameMode.Phase.FREEZE, "broken": 0})
	states = reset.get("doors", [])
	var restored := true
	for id in [1, client_peer(), _bot_id]:
		restored = restored and player(id) != null and player(id).health_component.current_health == 100
	var reset_props: Dictionary = reset.get("props", {})
	check("cqc_round_restores_map", restored and reset.get("cells") == _baseline and reset.get("fog") == _baseline and reset_props.get("broken") == 0 and reset_props.get("fog_blocking") == crates.size() and states.size() == 9 and states.all(func(value): return value == Door.State.CLOSED), "fresh lives, walls, crates with fog, and closed doors reset together: %s" % [reset])
