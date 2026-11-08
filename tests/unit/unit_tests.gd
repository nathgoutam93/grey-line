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

func test_frag_protects_teammates_but_keeps_self_damage_and_knockback() -> void:
	var thrower := await _spawn_player(Vector2(-2400, -2400))
	var teammate := await _spawn_player(Vector2(-2300, -2400))
	thrower.owner_peer_id = 1
	teammate.owner_peer_id = 2
	thrower.team = Teams.ALPHA
	teammate.team = Teams.ALPHA
	var saved_teams := MultiplayerSession.player_teams.duplicate()
	MultiplayerSession.player_teams = {1: Teams.ALPHA, 2: Teams.ALPHA}
	var frag := FragProjectile.new()
	frag.instigator_peer_id = 1
	frag.position = Vector2(-2350, -2400)
	frag.detonate_smoke_scene = null
	add_child(frag)
	frag._detonate()
	check(thrower.health_component.current_health < 100, "own grenade did not cause self damage")
	check(teammate.health_component.current_health == 100, "grenade damaged a teammate")
	check(teammate.movement_component.external_velocity.length() > 0.0, "friendly grenade lost its knockback")
	MultiplayerSession.player_teams = saved_teams
	thrower.queue_free()
	teammate.queue_free()

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
	source.velocity = Vector2.ZERO
	source.net_sync.report_noise(300.0, 1.0)
	check(not VisibilityQuery.can_hear(listener, source), "300 px sound heard at 500 px")
	source.net_sync.report_noise(1200.0, 1.0)
	check(VisibilityQuery.can_hear(listener, source), "1200 px sound not heard at 500 px")
	listener.queue_free()
	source.queue_free()
