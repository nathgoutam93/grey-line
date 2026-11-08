extends Node

## Headless unit tests for netcode building blocks. Run through
## tests/run_tests.sh (or: godot --headless --path . res://tests/unit/unit_tests.tscn -- --ephemeral-profile).
## Every func starting with `test_` runs in order; the process exits 0 when
## all pass, 1 otherwise.

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")
const TestLog := preload("res://tests/test_log.gd")

var _log := TestLog.new("unit")
var _current := ""

func _ready() -> void:
	await get_tree().process_frame
	for method in get_method_list():
		var method_name: String = method["name"]
		if not method_name.begins_with("test_"):
			continue
		_current = method_name
		var failures_before := _log.failures
		await call(method_name)
		if _log.failures == failures_before:
			_log.pass_test(method_name)
	get_tree().quit(_log.finish())

func check(condition: bool, message: String) -> void:
	if not condition:
		_log.fail(_current, message)

func check_near(actual: float, expected: float, tolerance: float, message: String) -> void:
	check(absf(actual - expected) <= tolerance, "%s (expected %.3f, got %.3f)" % [message, expected, actual])

# --- helpers ----------------------------------------------------------------

## A player in this scene with its network/footstep tick handlers detached, so
## the test fully controls it (no server simulation overriding rotation).
func _spawn_player(at: Vector2) -> PlayerController:
	var player := PLAYER_SCENE.instantiate() as PlayerController
	player.position = at
	add_child(player)
	await get_tree().process_frame
	await get_tree().process_frame # equipment is created a frame after _ready
	if NetworkTick.tick_started.is_connected(player.net_sync._on_network_tick):
		NetworkTick.tick_started.disconnect(player.net_sync._on_network_tick)
	if NetworkTick.tick_started.is_connected(player._on_network_tick):
		NetworkTick.tick_started.disconnect(player._on_network_tick)
	return player

func _move_frame(tick: int, move: Vector2) -> PlayerInputFrame:
	var frame := PlayerInputFrame.new()
	frame.tick = tick
	frame.move = move
	frame.aim_dir = Vector2.RIGHT
	return frame

func _wall(from: Vector2, size: Vector2) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	body.add_child(shape)
	body.position = from
	add_child(body)
	return body

# --- PlayerInputFrame -------------------------------------------------------

func test_destructible_walls_destroy_and_restore() -> void:
	var old_viewport := MaskViewProvider.viewport
	var viewport := FowViewportController.new()
	var level := Node2D.new()
	level.name = "Level"
	viewport.add_child(level)
	add_child(viewport)
	var walls := DestructibleWalls.new()
	walls.position = Vector2(-2100, -2400)
	walls.tile_set = load("res://resources/destruction/destructible_walls_tileset.tres")
	for y in range(3):
		walls.set_cell(Vector2i(0, y), 0, Vector2i.ZERO)
	add_child(walls)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var cell := Vector2i(0, 1)
	var center := walls.to_global(walls.map_to_local(cell))
	var ray := PhysicsRayQueryParameters2D.create(center - Vector2(40, 0), center + Vector2(40, 0), 1)
	var space := get_viewport().world_2d.direct_space_state
	check(not space.intersect_ray(ray).is_empty(), "intact cell has no collision")
	check(walls.cell_from_hit(space.intersect_ray(ray)) == cell, "ray hit resolved to the wrong cell")
	check(is_instance_valid(walls.mirror), "fog mirror missing")
	check(walls.mirror.global_transform == walls.global_transform, "mirror transform differs")
	check(not walls.mirror.collision_enabled and walls.mirror.occlusion_enabled, "mirror flags wrong")
	walls.destroy_cells([cell])
	check(not walls.has_wall(cell), "destroyed cell remains")
	check(walls.mirror.get_cell_source_id(cell) == -1, "mirror retains cell")
	check(space.intersect_ray(ray).is_empty(), "destroyed cell still blocks ray")
	check(walls.destroyed_cells() == [cell], "destroyed state wrong")
	walls.restore_all()
	check(walls.get_used_cells().size() == 3 and walls.mirror.get_used_cells().size() == 3, "restore lost cells")
	# Restoring creates new physics bodies; the broadphase registers them on its next step.
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(not space.intersect_ray(ray).is_empty(), "restore did not restore collision")
	walls.queue_free()
	await get_tree().process_frame
	check(level.get_child_count() == 0, "mirror leaked on exit")
	MaskViewProvider.set_viewport(old_viewport)
	viewport.queue_free()

func test_wall_damage_state_and_reset() -> void:
	var walls := DestructibleWalls.new()
	walls.name = "DamageTestWall"
	walls.tile_set = load("res://resources/destruction/destructible_walls_tileset.tres")
	for material in range(3):
		walls.set_cell(Vector2i(material, 0), 0, Vector2i(material, 0))
	add_child(walls)
	var service := DestructionService.new()
	add_child(service)
	var events: Array = []
	service.cells_destroyed.connect(func(cells: Array[Vector2i]): events.append(cells))
	var soft := Vector2i.ZERO
	var reinforced := Vector2i(1, 0)
	var hard := Vector2i(2, 0)
	service.apply_cell_damage(walls, soft, 10, DestructionMaterial.KIND_BULLET)
	check(walls.has_wall(soft), "partial damage destroyed cell")
	service.apply_cell_damage(walls, soft, 30, DestructionMaterial.KIND_BULLET)
	service.apply_cell_damage(walls, soft, 100, DestructionMaterial.KIND_BULLET)
	check(not walls.has_wall(soft) and events.size() == 1, "destruction missing or emitted twice")
	check(service._pending.size() == 1, "destruction not batched by wall path")
	service.apply_cell_damage(walls, reinforced, 1000, DestructionMaterial.KIND_BULLET)
	service.apply_cell_damage(walls, hard, 1000, DestructionMaterial.KIND_EXPLOSIVE)
	check(walls.has_wall(reinforced) and walls.has_wall(hard), "material damage rules bypassed")
	var path := get_path_to(walls)
	var state := {path: PackedVector2Array([Vector2(soft)])}
	walls.restore_all()
	service._full_state(state, {})
	service._full_state(state, {})
	check(walls.destroyed_cells() == [soft], "full state is not idempotent")
	service.apply_cell_damage(walls, reinforced, 100, DestructionMaterial.KIND_EXPLOSIVE)
	service.reset_all()
	check(walls.get_used_cells().size() == 3 and service._pending.is_empty(), "reset did not restore grid and clear pending events")
	service.apply_cell_damage(walls, reinforced, 60, DestructionMaterial.KIND_EXPLOSIVE)
	check(walls.has_wall(reinforced), "reset retained previous partial HP damage")
	service.apply_cell_damage(walls, reinforced, 90, DestructionMaterial.KIND_EXPLOSIVE)
	check(not walls.has_wall(reinforced), "reinforced explosive damage did not accumulate")
	walls.queue_free()
	service.queue_free()
	await get_tree().process_frame

func test_input_frame_round_trip() -> void:
	var f := PlayerInputFrame.new()
	f.tick = 123
	f.move = Vector2(0.5, -1)
	f.aim_dir = Vector2(0, 2)
	f.fire_held = true
	f.drop_pressed = true
	f.slot_select = 2
	f.shot_intent = 1
	f.view_tick = 118
	f.slow_walk_held = true
	var g := PlayerInputFrame.from_packed(f.to_packed())
	check(g != null, "unpacked frame is null")
	if g == null:
		return
	check(g.tick == 123 and g.view_tick == 118, "ticks lost")
	check(g.fire_held and g.drop_pressed and g.slow_walk_held and not g.reload_pressed, "flags wrong")
	check(g.slot_select == 2 and g.shot_intent == 1, "slot/intent wrong")
	check(g.aim_dir.is_equal_approx(Vector2(0, 1)), "aim not normalized")

func test_input_frame_rejects_malformed() -> void:
	check(PlayerInputFrame.from_packed("x") == null, "accepted a string")
	check(PlayerInputFrame.from_packed([1, 2]) == null, "accepted a short array")
	check(PlayerInputFrame.from_packed([1.5, Vector2.ZERO, Vector2.ZERO, 0, 0, 0, 0]) == null, "accepted a float tick")
	var big := PlayerInputFrame.from_packed([1, Vector2(50, 50), Vector2.ZERO, 0, -1, 0, -1])
	check(big != null and big.move.length() <= 1.0001, "move not clamped to length 1")

func test_input_frame_copy_and_merge() -> void:
	var f := PlayerInputFrame.new()
	f.fire_held = true
	f.drop_pressed = true
	f.slot_select = 2
	var c := f.copy_continuous(124)
	check(c.tick == 124 and c.fire_held, "continuous state not copied")
	check(not c.has_one_shot_actions(), "one-shot actions were copied")
	var later := PlayerInputFrame.new()
	later.merge_actions_from(f)
	check(later.drop_pressed and later.slot_select == 2, "merge lost earlier presses")

# --- Teams ------------------------------------------------------------------

func test_destruction_material_damage_rules() -> void:
	for kind in [DestructionMaterial.KIND_BULLET, DestructionMaterial.KIND_EXPLOSIVE, DestructionMaterial.KIND_MELEE]:
		check(DestructionMaterial.can_damage(DestructionMaterial.SOFT, kind), "soft wall rejected damage")
		check(not DestructionMaterial.can_damage(DestructionMaterial.HARD, kind), "hard wall accepted damage")
	check(DestructionMaterial.can_damage(DestructionMaterial.REINFORCED, DestructionMaterial.KIND_EXPLOSIVE), "reinforced wall rejected explosive damage")
	check(not DestructionMaterial.can_damage(DestructionMaterial.REINFORCED, DestructionMaterial.KIND_BULLET), "bullet damaged reinforced wall")
	check(not DestructionMaterial.can_damage(DestructionMaterial.REINFORCED, DestructionMaterial.KIND_MELEE), "melee damaged reinforced wall")
	check(not DestructionMaterial.can_damage(-1, DestructionMaterial.KIND_EXPLOSIVE), "invalid material accepted damage")

func test_teams_damage_rules() -> void:
	check(not Teams.can_damage(Teams.ALPHA, Teams.ALPHA, 1, 2, false), "friendly fire allowed")
	check(Teams.can_damage(Teams.ALPHA, Teams.ALPHA, 1, 2, true), "friendly fire toggle ignored")
	check(Teams.can_damage(Teams.ALPHA, Teams.BRAVO, 1, 2, false), "enemy damage blocked")
	check(Teams.can_damage(Teams.ALPHA, Teams.ALPHA, 1, 1, false), "self damage blocked")
	check(Teams.can_damage(Teams.NONE, Teams.ALPHA, 1, 2, false), "FFA attacker blocked")
	check(Teams.can_damage(Teams.ALPHA, Teams.NONE, 1, 2, false), "FFA victim blocked")

func test_teams_assignment_and_switching() -> void:
	check(Teams.pick_team_for_new_player({}) == Teams.ALPHA, "empty lobby did not pick Alpha")
	check(Teams.pick_team_for_new_player({1: Teams.ALPHA}) == Teams.BRAVO, "did not pick smaller team")
	var teams := {1: Teams.ALPHA, 2: Teams.BRAVO, -1: Teams.ALPHA}
	check(Teams.pick_team_for_new_player(teams) == Teams.BRAVO, "bots not counted")
	check(Teams.can_switch(teams, 1, Teams.BRAVO, 4), "balanced switch rejected")
	check(not Teams.can_switch(teams, 2, Teams.ALPHA, 4), "unbalanced switch accepted")
	check(not Teams.can_switch(teams, 1, Teams.BRAVO, 1), "full team accepted")
	check(not Teams.can_switch(teams, 99, Teams.BRAVO, 4), "unregistered peer accepted")
	check(not Teams.can_switch(teams, 1, Teams.NONE, 4), "invalid team accepted")
	check(teams[1] == Teams.ALPHA, "validation mutated teams")
	check(Teams.other(Teams.ALPHA) == Teams.BRAVO and Teams.other(Teams.BRAVO) == Teams.ALPHA, "opposite teams wrong")
	var five_players := {}
	for peer_id in [1, -1, -2, -3, -4]:
		five_players[peer_id] = Teams.pick_team_for_new_player(five_players)
	check(five_players.values().count(Teams.ALPHA) == 3 and five_players.values().count(Teams.BRAVO) == 2, "five players must split 3–2")

func test_free_for_all_fallback_keeps_individual_winner() -> void:
	var mode := DeathmatchGameMode.new()
	mode.teams_enabled = false
	mode.score_limit = 1
	var spawning := MatchPlayerSpawner.new()
	spawning.name = "Spawning"
	spawning.spawning_enabled = false
	mode.add_child(spawning)
	var scoreboard := MatchScoreboard.new()
	scoreboard.name = "Scoreboard"
	mode.add_child(scoreboard)
	add_child(mode)
	var saved_teams := MultiplayerSession.player_teams.duplicate()
	MultiplayerSession.player_teams = {1: Teams.ALPHA, 2: Teams.ALPHA}
	check(MultiplayerSession.get_team(1) == Teams.NONE and MultiplayerSession.get_team(2) == Teams.NONE, "FFA kept lobby teams active")
	var attacker := await _spawn_player(Vector2(-2400, -2400))
	var victim := await _spawn_player(Vector2(-2100, -2400))
	victim.owner_peer_id = 2
	scoreboard.track_player(1, attacker)
	scoreboard.track_player(2, victim)
	victim.health_component.take_damage(500, 1)
	check(mode.match_ended and mode.winning_peer_id == 1 and mode.winning_team == Teams.NONE, "FFA did not end at the individual limit")
	check(int(scoreboard.player_stats[1]["kills"]) == 1 and int(scoreboard.team_scores[Teams.ALPHA]) == 0, "FFA scoring wrong")
	check(mode._local_match_result_text(1) == "VICTORY", "FFA winner result wrong")
	MultiplayerSession.player_teams = saved_teams
	mode.queue_free()
	attacker.queue_free()
	victim.queue_free()

func test_frag_damages_both_teams_and_keeps_self_damage_and_knockback() -> void:
	var thrower := await _spawn_player(Vector2(-2400, -2400))
	var teammate := await _spawn_player(Vector2(-2300, -2400))
	var enemy := await _spawn_player(Vector2(-2350, -2500))
	var outside := await _spawn_player(Vector2(-1500, -2400))
	thrower.owner_peer_id = 1
	teammate.owner_peer_id = 2
	enemy.owner_peer_id = 3
	outside.owner_peer_id = 4
	thrower.team = Teams.ALPHA
	teammate.team = Teams.ALPHA
	enemy.team = Teams.BRAVO
	outside.team = Teams.ALPHA
	var saved_teams := MultiplayerSession.player_teams.duplicate()
	MultiplayerSession.player_teams = {1: Teams.ALPHA, 2: Teams.ALPHA, 3: Teams.BRAVO, 4: Teams.ALPHA}
	var frag := FragProjectile.new()
	frag.instigator_peer_id = 1
	frag.position = Vector2(-2350, -2400)
	frag.detonate_smoke_scene = null
	add_child(frag)
	frag._detonate()
	check(thrower.health_component.current_health < 100, "own grenade did not cause self damage")
	check(teammate.health_component.current_health < 100, "grenade did not damage a teammate")
	check(teammate.health_component.current_health == thrower.health_component.current_health, "same-distance teammate/self damage differs")
	check(enemy.health_component.current_health < 100, "grenade did not damage an enemy")
	check(outside.health_component.current_health == 100, "grenade damaged a player outside its radius")
	check(teammate.movement_component.external_velocity.length() > 0.0, "friendly grenade lost its knockback")
	MultiplayerSession.player_teams = saved_teams
	thrower.queue_free()
	teammate.queue_free()
	enemy.queue_free()
	outside.queue_free()

func test_team_visuals_restore_enemy_fog_mask() -> void:
	var player := await _spawn_player(Vector2(-2400, -2400))
	player.owner_peer_id = -1
	player.team = Teams.ALPHA
	var fog_material := player.skeletal_character.material
	player.apply_team_visuals(Teams.ALPHA)
	check(player.skeletal_character.material == null, "teammate still masked by fog")
	var tint: Color = Teams.COLORS[Teams.ALPHA]
	check(player.skeletal_character.modulate == tint.lerp(Color.WHITE, 0.6), "teammate tint wrong")
	player.apply_team_visuals(Teams.BRAVO)
	check(player.skeletal_character.material == fog_material and fog_material != null, "enemy fog mask not restored")
	check(player.skeletal_character.modulate == Color.WHITE, "enemy kept teammate tint")
	player.queue_free()

func test_team_spawns_avoid_players_and_prefer_distance() -> void:
	var occupant := await _spawn_player(Vector2(-2400, -2400))
	occupant.team = Teams.ALPHA
	var enemy := await _spawn_player(Vector2(-2000, -2400))
	enemy.team = Teams.BRAVO
	var map := Node2D.new()
	add_child(map)
	var points := Node2D.new()
	map.add_child(points)
	var attackers := Node2D.new()
	attackers.name = "AttackerSpawns"
	points.add_child(attackers)
	var defenders := Node2D.new()
	defenders.name = "DefenderSpawns"
	points.add_child(defenders)
	for position in [Vector2(-2400, -2400), Vector2(-2200, -2400), Vector2(-2800, -2400)]:
		var point := Node2D.new()
		point.position = position
		attackers.add_child(point)
	var defender := Node2D.new()
	defender.position = Vector2(-2400, -3000)
	defenders.add_child(defender)
	var fallback := Node2D.new()
	fallback.position = Vector2(-3000, -3000)
	points.add_child(fallback)
	var spawner := MatchPlayerSpawner.new()
	map.add_child(spawner)
	spawner.setup(map, points, PLAYER_SCENE)
	for _i in range(10):
		check(spawner.choose_spawn_point(Teams.ALPHA) == attackers.get_child(2), "chose occupied/closer attacker spawn")
	check(spawner.choose_spawn_point(Teams.BRAVO) == defender, "wrong role spawn")
	check(spawner.choose_spawn_point(Teams.NONE) == fallback, "FFA did not use flat spawns")
	points.remove_child(defenders)
	defenders.queue_free()
	spawner.setup(map, points, PLAYER_SCENE)
	check(spawner.choose_spawn_point(Teams.BRAVO) == fallback, "missing role did not use flat fallback")
	map.queue_free()
	occupant.queue_free()
	enemy.queue_free()

# --- BotBrain ---------------------------------------------------------------

func test_bot_brain_frame_fields() -> void:
	var brain := BotBrain.new()
	brain.move = Vector2(3, -4)
	brain.aim_dir = Vector2(0, 5)
	brain.fire_held = true
	brain.slow_walk_held = true
	brain.slot_select = 2
	brain.reload = true
	var first := brain.build_input_frame(100)
	check(first.tick == 100 and first.view_tick == 100, "bot ticks wrong")
	check(first.move.is_equal_approx(Vector2(0.6, -0.8)), "movement not limited")
	check(first.aim_dir.is_equal_approx(Vector2.DOWN), "aim not normalized")
	check(first.fire_held and first.fire_pressed and first.slow_walk_held, "held/press fields wrong")
	check(first.slot_select == 2 and first.reload_pressed, "one-shots missing")
	var held := brain.build_input_frame(101)
	check(held.fire_held and not held.fire_pressed, "fire press repeated while held")
	check(held.slot_select == -1 and not held.reload_pressed, "one-shots repeated")
	brain.stop()
	var stopped := brain.build_input_frame(102)
	check(stopped.move == Vector2.ZERO and not stopped.fire_held and not stopped.fire_pressed, "stop did not clear movement/fire")
	brain.fire_held = true
	brain.face_point(Vector2(10, 20), Vector2(10, 10))
	var restarted := brain.build_input_frame(103)
	check(restarted.fire_pressed and restarted.aim_dir == Vector2.UP, "new press or face_point wrong")
	brain.aim_dir = Vector2.ZERO
	check(brain.build_input_frame(104).aim_dir == Vector2.RIGHT, "zero aim has no fallback")

# --- StateHistoryBuffer / RemoteInterpolator --------------------------------

func test_state_history_returns_latest_at_or_before_tick() -> void:
	var history := StateHistoryBuffer.new()
	history.configure(3)
	for t in [10, 11, 12, 13]:
		history.store(t, Transform2D(0.0, Vector2(t, 0)))
	check(history.get_transform_for_tick(10) == null, "kept more entries than configured")
	var at_12: Variant = history.get_transform_for_tick(12)
	check(at_12 != null and (at_12 as Transform2D).origin.x == 12.0, "wrong entry for tick 12")
	var at_20: Variant = history.get_transform_for_tick(20)
	check(at_20 != null and (at_20 as Transform2D).origin.x == 13.0, "future tick should return newest")

func test_interpolator_orders_and_blends_snapshots() -> void:
	var player := await _spawn_player(Vector2.ZERO)
	var interpolator := RemoteInterpolator.new()
	interpolator.push_snapshot({"tick": 20, "position": Vector2(20, 0), "rotation": 0.0})
	interpolator.push_snapshot({"tick": 10, "position": Vector2(10, 0), "rotation": 0.0})
	check(int(interpolator.snapshot_buffer[0]["tick"]) == 10, "snapshots not kept in tick order")
	interpolator.interpolate(player, 15)
	check_near(player.global_position.x, 15.0, 0.001, "midpoint not interpolated")
	player.queue_free()

# --- movement / reconciliation ----------------------------------------------

func test_movement_step_is_one_tick_in_and_out_of_physics_frames() -> void:
	var player := await _spawn_player(Vector2(-2400, -2400))
	var expected := player.get_speed() * NetworkTick.get_tick_delta()
	var before := player.global_position
	player.movement_component.simulate(_move_frame(1, Vector2(0, -1)))
	check_near(player.global_position.distance_to(before), expected, 0.01, "step outside a physics frame")
	await get_tree().physics_frame
	before = player.global_position
	player.movement_component.simulate(_move_frame(2, Vector2(0, -1)))
	check_near(player.global_position.distance_to(before), expected, 0.01, "step inside a physics frame")
	player.queue_free()

func test_reconciler_skips_matching_prediction_and_replays_on_mismatch() -> void:
	var player := await _spawn_player(Vector2(-2400, -2400))
	var reconciler := ClientReconciler.new()
	var step := player.get_speed() * NetworkTick.get_tick_delta()
	# Movement is relative to facing: aim +x with move (0, -1) walks forward, +x.
	var forward := Vector2(step, 0)
	var input_buffer := {11: _move_frame(11, Vector2(0, -1)), 12: _move_frame(12, Vector2(0, -1))}
	var predicted := {10: Vector2(-2400, -2400)}

	player.global_position = Vector2(-2400, -2400) + 2.0 * forward
	var current := player.global_position
	reconciler.reconcile(player, Vector2(-2400, -2400), Vector2.ZERO, 10, input_buffer, predicted, player.movement_component)
	check(player.global_position.is_equal_approx(current), "corrected although prediction matched")

	input_buffer = {11: _move_frame(11, Vector2(0, -1)), 12: _move_frame(12, Vector2(0, -1))}
	predicted = {10: Vector2(-2400, -2400)}
	var server := Vector2(-2400, -2380)
	reconciler.reconcile(player, server, Vector2.ZERO, 10, input_buffer, predicted, player.movement_component)
	check(player.global_position.distance_to(server + 2.0 * forward) < 0.01, "did not snap and replay 2 pending inputs (at %s)" % [player.global_position])
	check(not input_buffer.has(10) and input_buffer.size() == 2, "acked inputs not pruned correctly")
	player.queue_free()

# --- equipment ammo sync -----------------------------------------------------

func test_weapon_ammo_capture_and_deltas() -> void:
	var player := await _spawn_player(Vector2(-2400, -2400))
	var equipment := player.equipment_manager
	var ammo := equipment.capture_weapon_ammo()
	check(ammo.size() == EquipmentManager.WEAPON_SLOTS.size() * 2, "wrong ammo layout size")
	var rifle := equipment.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance
	check(rifle != null, "no primary weapon in default loadout")
	if rifle == null:
		return
	var deltas := PackedInt32Array()
	deltas.resize(ammo.size())
	deltas[0] = -5
	deltas[1] = 1000
	var mag_before := rifle.ammo_in_mag
	equipment.apply_weapon_ammo_deltas(deltas)
	check(rifle.ammo_in_mag == maxi(mag_before - 5, 0), "mag delta not applied")
	deltas[0] = 10000
	equipment.apply_weapon_ammo_deltas(deltas)
	check(rifle.ammo_in_mag == rifle.data.mag_size, "mag not clamped to mag_size")
	player.queue_free()

# --- server visibility / hearing --------------------------------------------

func test_visibility_cone_walls_and_smoke() -> void:
	var viewer := await _spawn_player(Vector2(-2400, -2400))
	var target := await _spawn_player(Vector2(-1900, -2400))
	viewer.rotation = 0.0 # facing +x, towards the target
	await get_tree().physics_frame
	check(VisibilityQuery.can_see(viewer, target, []), "clear line in the cone not visible")

	viewer.rotation = PI # facing away
	await get_tree().physics_frame
	check(not VisibilityQuery.can_see(viewer, target, []), "visible behind the viewer")
	target.global_position = Vector2(-2400 + VisibilityQuery.CLOSE_RANGE * 0.5, -2400)
	await get_tree().physics_frame
	check(VisibilityQuery.can_see(viewer, target, []), "close range should ignore facing")

	viewer.rotation = 0.0
	target.global_position = Vector2(-1900, -2400)
	var smoke := [[Vector2(-2150, -2400), 80.0]]
	check(not VisibilityQuery.can_see(viewer, target, smoke), "visible through smoke")

	var wall := _wall(Vector2(-2150, -2400), Vector2(20, 400))
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(not VisibilityQuery.can_see(viewer, target, []), "visible through a wall")
	wall.queue_free()
	viewer.queue_free()
	target.queue_free()

func test_hearing_follows_noise_radius() -> void:
	var listener := await _spawn_player(Vector2(-2400, -2400))
	var source := await _spawn_player(Vector2(-1900, -2400)) # 500 px away
	source.velocity = Vector2.ZERO
	check(not VisibilityQuery.can_hear(listener, source), "silent player heard")
	source.velocity = Vector2(200, 0) # walking: footsteps carry footstep_player.max_distance (800)
	check(VisibilityQuery.can_hear(listener, source), "footsteps not heard at 500 px")
	source.is_slow_walking = true
	check(not source.net_sync.is_making_footstep_noise(), "slow walker reports footstep noise")
	check(not VisibilityQuery.can_hear(listener, source), "slow walker heard at 500 px")
	source.net_sync.report_noise(1200.0, 1.0)
	check(VisibilityQuery.can_hear(listener, source), "slow walking suppressed equipment noise")
	source.net_sync.reset_state()
	source.is_slow_walking = false
	source.velocity = Vector2.ZERO
	source.net_sync.report_noise(300.0, 1.0)
	check(not VisibilityQuery.can_hear(listener, source), "300 px sound heard at 500 px")
	source.net_sync.report_noise(1200.0, 1.0)
	check(VisibilityQuery.can_hear(listener, source), "1200 px sound not heard at 500 px")
	listener.queue_free()
	source.queue_free()

func test_slow_walk_silences_local_footstep_audio() -> void:
	var player := await _spawn_player(Vector2(-2400, -2400))
	player._footstep_moving = true
	player.movement_component.is_moving = true
	player.is_slow_walking = true
	player._update_footstep_audio(NetworkTick.get_tick_delta())
	check(not player.footstep_player.playing, "local slow walker played footsteps")
	player.is_slow_walking = false
	player._update_footstep_audio(NetworkTick.get_tick_delta())
	check(player.footstep_player.playing, "local runner did not play footsteps")
	player.footstep_player.stop()
	player.queue_free()

func test_world_snapshot_keeps_visibility_and_footstep_bits_separate() -> void:
	var viewer := await _spawn_player(Vector2(-2400, -2400))
	var target := await _spawn_player(Vector2(-1900, -2400))
	viewer.owner_peer_id = 2
	target.owner_peer_id = 3
	viewer.rotation = 0.0
	target.velocity = Vector2(200, 0)
	var packet := WorldSnapshots.build_packet(2)
	var ids: PackedInt32Array = packet[WorldSnapshotService.P_IDS]
	var index := ids.find(3)
	check(index >= 0, "visible runner absent from packet")
	if index >= 0:
		var flags: PackedByteArray = packet[WorldSnapshotService.P_FLAGS]
		check((flags[index] & WorldSnapshotService.FLAG_VISIBLE) != 0, "running cleared visibility bit")
		check((flags[index] & WorldSnapshotService.FLAG_FOOTSTEPS) != 0, "running missing footstep bit")
		target.is_slow_walking = true
		packet = WorldSnapshots.build_packet(2)
		ids = packet[WorldSnapshotService.P_IDS]
		flags = packet[WorldSnapshotService.P_FLAGS]
		index = ids.find(3)
		check(index >= 0 and flags[index] == WorldSnapshotService.FLAG_VISIBLE, "visible slow walker has wrong bits")
	target.net_sync.net_footsteps = true
	target.net_sync.set_net_presence(PlayerNetSync.NetPresence.CULLED)
	check(not target.net_sync.net_footsteps, "culled player kept footstep flag")
	viewer.queue_free()
	target.queue_free()

func _send_screen_touch(index: int, position: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = position
	event.pressed = pressed
	get_viewport().push_input(event, true)

func test_touch_walk_toggle_keeps_joystick_touch_and_saves_position() -> void:
	var player := await _spawn_player(Vector2(-2400, -2400))
	var collector := player.player_input
	collector.input_mode = PlayerInputCollector.InputMode.TOUCH
	await get_tree().process_frame
	var walk := player.hud.controls_root.get_node("Walk") as TouchScreenButton
	var joystick := collector._resolve_move_joystick()
	check(walk.visible, "touch Walk toggle is hidden")
	var move_position := joystick.get_global_rect().get_center() + Vector2(0, -50)
	_send_screen_touch(6, move_position, true)
	await get_tree().process_frame
	var walk_position := walk.get_global_transform_with_canvas() * Vector2(42, 42)
	_send_screen_touch(7, walk_position, true)
	await get_tree().process_frame
	check(joystick.is_pressed, "Walk tap released the joystick's other finger")
	check(collector.touch_slow_walk and collector.build_input_frame(10).slow_walk_held, "Walk tap did not enable slow-walk input")
	_send_screen_touch(7, walk_position, false)
	check(collector.build_input_frame(11).slow_walk_held, "Walk did not stay toggled after release")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--walk-preview="):
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(arg.trim_prefix("--walk-preview="))
	_send_screen_touch(7, walk_position, true)
	_send_screen_touch(7, walk_position, false)
	_send_screen_touch(6, move_position, false)
	check(not collector.touch_slow_walk and not collector.build_input_frame(12).slow_walk_held, "second tap did not disable slow walk")
	var saved_layout: Dictionary = PlayerProfile.get_touch_layout()["Walk"]
	PlayerProfile.set_touch_control_position_norm("Walk", Vector2(0.4, 0.8))
	PlayerProfile.apply_touch_layout_to_controls(player.hud.controls_root)
	check(walk.position.is_equal_approx(get_viewport().get_visible_rect().size * Vector2(0.4, 0.8)), "Walk position was not restored from the profile")
	PlayerProfile.set_touch_control_layout("Walk", saved_layout)
	collector.input_mode = PlayerInputCollector.InputMode.MOUSE_KEYBOARD
	check(not walk.visible and not collector.build_input_frame(13).slow_walk_held, "touch Walk leaked into keyboard mode")
	player.queue_free()

func test_lobby_rosters_show_every_player_in_their_team() -> void:
	var view := LobbyView.new()
	view.size = Vector2(1280, 720)
	add_child(view)
	var names := {1: "Host", -1: "Bot 1", -2: "Bot 2", -3: "Bot 3", -4: "Bot 4"}
	var teams := {}
	for id in names:
		teams[id] = Teams.pick_team_for_new_player(teams)
	var payload := {"player_names": names, "player_teams": teams, "local_peer_id": 1,
		"is_connected": true, "is_server": true, "map_scene_path": "res://scenes/maps/map_1/map_1.tscn"}
	view.render(payload)
	await get_tree().process_frame
	await get_tree().process_frame
	var alpha := view.find_child("AlphaRoster", true, false)
	var bravo := view.find_child("BravoRoster", true, false)
	check(alpha.find_children("player_slot_*", "Label", true, false).size() == 3, "Alpha roster did not show three players")
	check(bravo.find_children("player_slot_*", "Label", true, false).size() == 2, "Bravo roster did not show two players")
	var balance := view.find_child("TeamBalance", true, false) as Label
	check(balance.text.begins_with("3 VS 2"), "five-player balance is not explicit")
	# Optional graphical capture for reviewing this fixture in a real renderer.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lobby-preview="):
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(arg.trim_prefix("--lobby-preview="))
	for id in [-5, -6, -7]:
		names[id] = "Bot %d" % -id
		teams[id] = Teams.pick_team_for_new_player(teams)
	view.render(payload)
	await get_tree().process_frame
	check(view.find_children("player_slot_*", "Label", true, false).size() == 8, "lobby hid players beyond the old five-card limit")
	view.size = Vector2(800, 600)
	await get_tree().process_frame
	await get_tree().process_frame
	for button_name in ["start_match", "SwitchTeam", "AddBot", "RemoveBot"]:
		var button := view.find_child(button_name, true, false) as Button
		check(view.get_global_rect().encloses(button.get_global_rect()), "%s overflows the lobby" % button_name)
	view.queue_free()
