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

func _destructible_wall(at: Vector2, cells: Array[Vector2i], material: int = DestructionMaterial.SOFT) -> DestructibleWalls:
	var walls := DestructibleWalls.new()
	walls.position = at
	walls.tile_set = load("res://resources/destruction/destructible_walls_tileset.tres")
	for cell in cells:
		walls.set_cell(cell, 0, Vector2i(material, 0))
	add_child(walls)
	return walls

# --- Destruction ------------------------------------------------------------

func test_input_ingress_rejects_missing_dead_and_previous_lives() -> void:
	var owner := await _spawn_player(Vector2(-2400, -2400))
	var teammate := await _spawn_player(Vector2(-2200, -2400))
	owner.owner_peer_id = 2
	owner.net_sync.life_id = 202
	teammate.owner_peer_id = 3
	teammate.net_sync.life_id = 303
	var frame := _move_frame(NetworkTick.tick + 1, Vector2.RIGHT)
	var packed := [frame.to_packed()]
	WorldSnapshots._receive_player_input(2, 101, packed) # Previous life.
	WorldSnapshots._receive_player_input(2, 303, packed) # Someone else's life.
	WorldSnapshots._receive_player_input(4, 202, packed) # No owned player.
	check(owner.net_sync._input_queue.is_empty() and teammate.net_sync._input_queue.is_empty(), "invalid life or sender queued input")
	WorldSnapshots._receive_player_input(2, 202, packed)
	check(owner.net_sync._input_queue.has(frame.tick), "current life input was rejected")
	owner.net_sync._input_queue.clear()
	owner.is_dead = true
	WorldSnapshots._receive_player_input(2, 202, packed)
	check(owner.net_sync._input_queue.is_empty() and teammate.net_sync._input_queue.is_empty(), "dead viewer input affected a player or spectator target")
	owner.queue_free()
	await get_tree().process_frame
	WorldSnapshots._receive_player_input(2, 202, packed) # In flight during respawn gap.
	check(teammate.net_sync._input_queue.is_empty(), "input with no owned life affected a teammate")
	teammate.queue_free()
	await get_tree().process_frame

func test_game_mode_lookup_uses_group() -> void:
	var mode := MatchGameMode.new()
	mode.name = "CustomRules"
	add_child(mode)
	mode.add_to_group("game_mode")
	mode.teams_enabled = false
	mode.friendly_fire = true
	check(MatchGameMode.current(get_tree()) == mode, "game mode lookup depends on deathmatch name or type")
	check(MatchGameMode.is_friendly_fire_enabled(get_tree()), "generic mode friendly-fire rule ignored")
	check(MultiplayerSession.get_team(1) == Teams.NONE, "generic FFA mode did not disable team assignment")
	mode.queue_free()
	await get_tree().process_frame

func test_action_lock_blocks_movement_but_keeps_aim() -> void:
	var player := await _spawn_player(Vector2(-2400, -2400))
	player.actions_locked = true
	player.movement_component.external_velocity = Vector2(150, 0)
	var frame := _move_frame(NetworkTick.tick, Vector2(0, -1))
	frame.aim_dir = Vector2.UP
	var start := player.global_position
	PlayerSimulation.simulate(player, player.movement_component, frame)
	check(player.global_position.is_equal_approx(start), "locked movement or knockback moved player")
	check_near(player.rotation, -PI * 0.5, 0.001, "locked player could not aim")
	check(not player.movement_component.is_moving and player.velocity.is_zero_approx(), "locked player retained movement state")
	player.actions_locked = false
	PlayerSimulation.simulate(player, player.movement_component, frame)
	check(player.global_position.distance_to(start) > 0.1, "unlock did not restore movement")
	player.queue_free()
	await get_tree().process_frame

func test_action_lock_cancels_and_blocks_combat_and_interactions() -> void:
	var player := await _spawn_player(Vector2(-2400, -2400))
	var equipment := player.equipment_manager
	var rifle := equipment.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance
	equipment.current_slot = EquipmentManager.EquipmentSlot.PRIMARY
	equipment.current_item = rifle
	rifle.force_interrupt()
	rifle.ammo_in_mag -= 5
	rifle.is_firing = true
	rifle.reload()
	var door := (load("res://scenes/props/door/door.tscn") as PackedScene).instantiate() as Door
	door.position = player.global_position + Vector2(40, 0)
	add_child(door)
	await get_tree().physics_frame
	await get_tree().physics_frame
	player.actions_locked = true
	var ammo := rifle.ammo_in_mag
	check(not rifle.is_firing and not rifle.is_reloading, "locking failed to cancel firing or reload")
	var frame := _move_frame(NetworkTick.tick + 1, Vector2.ZERO)
	frame.fire_held = true
	frame.reload_pressed = true
	frame.slot_select = EquipmentManager.EquipmentSlot.SECONDARY
	frame.drop_pressed = true
	frame.interact_pressed = true
	player.net_sync._apply_input_actions(frame)
	player.net_sync._remote_switch_weapon_slot(EquipmentManager.EquipmentSlot.SECONDARY)
	player.net_sync._remote_drop_weapon()
	player.net_sync._remote_interact(door.get_node("Interactable").get_path())
	rifle.start_use()
	rifle.reload()
	check(not rifle._single_shot() and rifle.ammo_in_mag == ammo, "locked weapon consumed ammo")
	check(not rifle.is_firing and not rifle.is_reloading, "locked weapon started firing or reloading")
	check(equipment.current_item == rifle and is_instance_valid(rifle), "locked input switched or dropped equipment")
	check(door.state == Door.State.CLOSED, "locked input opened door")
	var throwable := equipment.get_item_in_slot(EquipmentManager.EquipmentSlot.UTILITY_1) as ThrowableInstance
	var throw_request := throwable._throw_request_id
	throwable.start_use()
	check(throwable._throw_request_id == throw_request, "locked player began throwing a grenade")
	player.actions_locked = false
	frame = _move_frame(NetworkTick.tick + 2, Vector2.ZERO)
	frame.fire_held = true
	player.net_sync._apply_input_actions(frame)
	check(rifle.is_firing, "unlock did not restore fire input")
	player.net_sync._remote_interact(door.get_node("Interactable").get_path())
	check(door.state == Door.State.OPEN, "unlock did not restore interaction")
	door.queue_free()
	player.queue_free()
	await get_tree().process_frame

func test_round_phase_clock_and_round_end_movement() -> void:
	var mode := (load("res://components/round_mode/round_game_mode.tscn") as PackedScene).instantiate() as RoundGameMode
	add_child(mode)
	mode.set_process(false)
	mode.freeze_seconds = 2.0
	mode.round_seconds = 3.0
	mode._clock_tick = 100
	mode._publish_phase(RoundGameMode.Phase.FREEZE, 2.0)
	check(mode.phase_end_tick == 220 and mode.displayed_seconds() == 2, "freeze end tick or countdown wrong")
	check(mode.local_end_tick - NetworkTick.tick == 120, "client-style countdown did not use relative end tick")
	mode._on_network_tick(220)
	check(mode.phase == RoundGameMode.Phase.LIVE and mode.phase_end_tick == 400, "freeze did not become live on its end tick")
	mode._on_network_tick(400)
	check(mode.phase == RoundGameMode.Phase.ROUND_END and mode.team_scores[Teams.BRAVO] == 1, "timeout did not award defender round")
	check(mode.is_actions_locked() and not mode.is_movement_locked(), "ROUND_END did not retain the movement exception")
	var player := await _spawn_player(Vector2(-2400, -2400))
	mode.configure_player(player)
	var start := player.global_position
	PlayerSimulation.simulate(player, player.movement_component, _move_frame(NetworkTick.tick, Vector2(0, -1)))
	check(player.actions_locked and player.global_position.distance_to(start) > 0.1, "ROUND_END blocked walking or unlocked combat")
	mode._on_network_tick(mode.phase_end_tick)
	check(mode.phase == RoundGameMode.Phase.WAITING, "empty team did not leave next round waiting")
	player.queue_free()
	mode.queue_free()
	await get_tree().process_frame

func test_round_respawn_restores_loadout_walls_and_role_spawns() -> void:
	var saved_names := MultiplayerSession.player_names.duplicate()
	var saved_teams := MultiplayerSession.player_teams.duplicate()
	var saved_bots := MultiplayerSession.bot_ids.duplicate()
	MultiplayerSession.player_names = {1: "Host", -1: "Puppet"}
	MultiplayerSession.player_teams = {1: Teams.ALPHA, -1: Teams.BRAVO}
	MultiplayerSession.bot_ids = [-1]
	var fixture := Node2D.new()
	add_child(fixture)
	var map := Node2D.new()
	map.name = "Map"
	fixture.add_child(map)
	var spawns := Node2D.new()
	map.add_child(spawns)
	var points: Array[Node2D] = []
	for role_name in ["AttackerSpawns", "DefenderSpawns"]:
		var container := Node2D.new()
		container.name = role_name
		spawns.add_child(container)
		var point := Node2D.new()
		point.position = Vector2(-2400 if role_name == "AttackerSpawns" else -2000, -2400)
		container.add_child(point)
		points.append(point)
	var service := DestructionService.new()
	fixture.add_child(service)
	var walls := _destructible_wall(Vector2(-2200, -2500), [Vector2i.ZERO])
	walls.reparent(map)
	var mode := (load("res://components/round_mode/round_game_mode.tscn") as PackedScene).instantiate() as RoundGameMode
	mode.map = map
	mode.spawn_point_container = spawns
	mode.freeze_seconds = 100.0
	fixture.add_child(mode)
	for frame in range(60):
		await get_tree().process_frame
		if mode.phase == RoundGameMode.Phase.FREEZE and map.has_node("1") and map.has_node("-1"):
			break
	check(mode.phase == RoundGameMode.Phase.FREEZE, "round did not spawn a ready roster")
	await get_tree().process_frame
	await get_tree().process_frame # Default equipment is built after the player's ready callback.
	var host := map.get_node("1") as PlayerController
	var original_id := host.get_instance_id()
	check(host.global_position == points[0].global_position and host.actions_locked, "attacker spawn or initial freeze lock wrong")
	host.health_component.current_health = 25
	(host.equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance).ammo_in_mag = 2
	service.apply_cell_damage(walls, Vector2i.ZERO, 40, DestructionMaterial.KIND_BULLET)
	mode.attacking_team = Teams.BRAVO
	check(mode.spawning.spawn_point_for(1) == points[1], "role change did not switch Alpha's spawn pool")
	mode._start_round()
	for frame in range(60):
		await get_tree().process_frame
		var current := map.get_node_or_null("1") as PlayerController
		if current != null and current.get_instance_id() != original_id and not mode._starting_round:
			break
	await get_tree().process_frame
	await get_tree().process_frame
	host = map.get_node("1") as PlayerController
	var rifle := host.equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance
	check(host.get_instance_id() != original_id and host.health_component.current_health == 100, "round reset reused a damaged life")
	check(rifle != null and rifle.ammo_in_mag == rifle.data.mag_size, "round reset did not restore default ammo")
	check(walls.has_wall(Vector2i.ZERO), "round reset did not restore destroyed cell")
	check(host.global_position == points[1].global_position and not mode.spawning.spawning_enabled, "new role spawn or no-respawn flag wrong")
	MultiplayerSession.player_names = saved_names
	MultiplayerSession.player_teams = saved_teams
	MultiplayerSession.bot_ids = saved_bots
	fixture.queue_free()
	await get_tree().process_frame

func _round_fixture() -> Dictionary:
	var saved := {"names": MultiplayerSession.player_names.duplicate(), "teams": MultiplayerSession.player_teams.duplicate(), "bots": MultiplayerSession.bot_ids.duplicate()}
	MultiplayerSession.player_names = {1: "Host", -1: "Ally", -2: "Enemy"}
	MultiplayerSession.player_teams = {1: Teams.ALPHA, -1: Teams.ALPHA, -2: Teams.BRAVO}
	MultiplayerSession.bot_ids = [-1, -2]
	var root := Node2D.new()
	add_child(root)
	var map := Node2D.new()
	map.name = "Map"
	root.add_child(map)
	var spawns := Node2D.new()
	map.add_child(spawns)
	for role_name in ["AttackerSpawns", "DefenderSpawns"]:
		var container := Node2D.new()
		container.name = role_name
		spawns.add_child(container)
		for i in range(3):
			var point := Node2D.new()
			point.position = Vector2((-2400 - i * 100) if role_name == "AttackerSpawns" else (-1800 + i * 100), -2400)
			container.add_child(point)
	var zone := (load("res://components/round_mode/objective_zone.tscn") as PackedScene).instantiate() as ObjectiveZone
	zone.position = Vector2(-2100, -2000)
	map.add_child(zone)
	var mode := (load("res://components/round_mode/round_game_mode.tscn") as PackedScene).instantiate() as RoundGameMode
	mode.map = map
	mode.spawn_point_container = spawns
	mode.freeze_seconds = 100
	mode.round_seconds = 100
	mode.round_end_seconds = 100
	root.add_child(mode)
	for frame in range(60):
		await get_tree().process_frame
		if mode.phase == RoundGameMode.Phase.FREEZE:
			break
	await get_tree().process_frame
	await get_tree().process_frame
	NetworkTick.tick_started.disconnect(mode._on_network_tick)
	mode.set_process(false)
	return {"root": root, "map": map, "mode": mode, "zone": zone, "saved": saved}

func _free_round_fixture(fixture: Dictionary) -> void:
	MultiplayerSession.player_names = fixture.saved.names
	MultiplayerSession.player_teams = fixture.saved.teams
	MultiplayerSession.bot_ids = fixture.saved.bots
	fixture.root.queue_free()
	await get_tree().process_frame

func _flush_area_monitoring() -> void:
	# Teleports are submitted to physics, then overlap notifications are flushed to Area2D.
	for frame in range(3):
		await get_tree().physics_frame
	await get_tree().process_frame

func test_round_elimination_scores_once_and_blocks_round_end_damage() -> void:
	var fixture := await _round_fixture()
	var mode: RoundGameMode = fixture.mode
	mode._publish_phase(RoundGameMode.Phase.LIVE, 100)
	var enemy := fixture.map.get_node("-2") as PlayerController
	enemy.health_component.take_damage(500, 1)
	check(mode.phase == RoundGameMode.Phase.ROUND_END and mode.winner_team == Teams.ALPHA, "elimination did not finish round for survivors")
	check(mode.team_scores[Teams.ALPHA] == 1 and mode.scoreboard.player_stats[1]["kills"] == 1, "kill changed round score more than once or lost kill stats")
	var survivor := fixture.map.get_node("1") as PlayerController
	survivor.health_component.take_damage(500, -2)
	check(survivor.health_component.current_health == 100, "ROUND_END allowed damage")
	enemy.queue_free() # Exercise the same exit callback used by delayed death despawn.
	await get_tree().process_frame
	await get_tree().process_frame
	check(not fixture.map.has_node("-2"), "eliminated player respawned during the round")
	await _free_round_fixture(fixture)

func test_objective_counts_contest_pause_and_accumulated_capture() -> void:
	var fixture := await _round_fixture()
	var mode: RoundGameMode = fixture.mode
	var zone: ObjectiveZone = fixture.zone
	mode.objective_hold_seconds = 1.0
	mode._publish_phase(RoundGameMode.Phase.LIVE, 100)
	var attacker := fixture.map.get_node("-1") as PlayerController
	var defender := fixture.map.get_node("-2") as PlayerController
	attacker.global_position = zone.global_position
	await _flush_area_monitoring()
	check(zone.living_counts(Teams.ALPHA) == Vector2i(1, 0), "zone count=%s attacker_team=%d attacker=%s physics=%s zone=%s bodies=%s selected=%s" % [zone.living_counts(Teams.ALPHA), attacker.team, attacker.global_position, PhysicsServer2D.body_get_state(attacker.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM), zone.global_position, zone.get_overlapping_bodies(), mode.objective == zone])
	for tick in range(20):
		mode._clock_tick += 1
		mode._tick_objective()
	var saved := mode.objective_progress
	mode._refresh_hud()
	check(mode.objective_bar.visible and is_equal_approx(mode.objective_bar.value, saved), "HUD did not show objective progress")
	defender.global_position = zone.global_position + Vector2(40, 0)
	await _flush_area_monitoring()
	check(zone.living_counts(Teams.ALPHA) == Vector2i(1, 1), "contested fixture missing a defender")
	mode._tick_objective()
	check(is_equal_approx(mode.objective_progress, saved), "contested objective advanced or decayed")
	attacker.global_position += Vector2(500, 0)
	defender.global_position += Vector2(500, 0)
	await _flush_area_monitoring()
	check(zone.living_counts(Teams.ALPHA) == Vector2i.ZERO, "unattended fixture retained players")
	mode._tick_objective()
	check(is_equal_approx(mode.objective_progress, saved), "unattended objective lost accumulated progress")
	attacker.global_position = zone.global_position
	await _flush_area_monitoring()
	for tick in range(41):
		if mode.phase != RoundGameMode.Phase.LIVE:
			break
		mode._clock_tick += 1
		mode._tick_objective()
	check(mode.phase == RoundGameMode.Phase.ROUND_END and mode.winner_team == Teams.ALPHA, "accumulated uncontested hold did not win for attackers")
	await _free_round_fixture(fixture)

func test_round_halftime_and_first_to_two_match_end() -> void:
	var fixture := await _round_fixture()
	var mode: RoundGameMode = fixture.mode
	mode.rounds_to_win = 2
	mode._publish_phase(RoundGameMode.Phase.LIVE, 100)
	mode._finish_round(Teams.ALPHA)
	mode._on_network_tick(mode.phase_end_tick)
	for frame in range(60):
		await get_tree().process_frame
		if not mode._starting_round:
			break
	check(mode.phase == RoundGameMode.Phase.FREEZE and mode.attacking_team == Teams.BRAVO and mode.round_index == 1, "halftime did not swap roles after the first finished round")
	check(mode.role_of(Teams.ALPHA) == RoundGameMode.Role.DEFEND, "fixed Alpha team did not become defender")
	check(mode.role_label.text.contains("DEFEND") and mode.round_score_label.text.contains("ALPHA 1"), "HUD did not refresh role or round score at halftime")
	mode._on_network_tick(mode.phase_end_tick)
	mode._finish_round(Teams.ALPHA)
	mode._on_network_tick(mode.phase_end_tick)
	check(mode.phase == RoundGameMode.Phase.MATCH_END and mode.team_scores[Teams.ALPHA] == 2, "first to two did not end match")
	check(mode.match_result_label.text == "VICTORY", "winning host did not receive match result")
	await _free_round_fixture(fixture)

func test_host_round_clock_cycles_without_client_timer_rpcs() -> void:
	var fixture := await _round_fixture()
	var mode: RoundGameMode = fixture.mode
	mode.freeze_seconds = 0.1
	mode.round_seconds = 0.1
	mode.round_end_seconds = 0.1
	mode._clock_tick = NetworkTick.tick
	mode._publish_phase(RoundGameMode.Phase.FREEZE, 0.1)
	NetworkTick.tick_started.connect(mode._on_network_tick)
	var deadline := NetworkTick.tick + 300
	while mode.phase != RoundGameMode.Phase.MATCH_END and NetworkTick.tick < deadline:
		await get_tree().process_frame
	check(mode.phase == RoundGameMode.Phase.MATCH_END and mode.round_index == 7, "host clock failed to complete the default first-to-four match")
	check(mode.team_scores[Teams.ALPHA] == 4 and mode.team_scores[Teams.BRAVO] == 3, "defender timeout wins or halftime after three rounds wrong during real host ticks")
	await _free_round_fixture(fixture)

func test_spectating_uses_teammate_visibility_and_cycles_only_allies() -> void:
	var fixture := await _round_fixture()
	var mode: RoundGameMode = fixture.mode
	mode._publish_phase(RoundGameMode.Phase.LIVE, 100)
	var me := fixture.map.get_node("1") as PlayerController
	var ally := fixture.map.get_node("-1") as PlayerController
	var enemy := fixture.map.get_node("-2") as PlayerController
	me.global_position = Vector2(-2400, -2400)
	ally.global_position = Vector2(-2000, -2400)
	ally.rotation = 0.0
	enemy.global_position = Vector2(-2450, -2400)
	me.health_component.take_damage(500, -2)
	check(mode.spectate_target.get(1) == -1 and WorldSnapshots._find_player_node(1) == ally, "dead viewer did not switch to living ally")
	WorldSnapshots._last_visible_tick[1] = {-2: NetworkTick.tick}
	var hidden := WorldSnapshots.build_packet(1)
	check(not (hidden[WorldSnapshotService.P_IDS] as PackedInt32Array).has(-2), "spectator retained enemy information from corpse sight or grace")
	enemy.global_position = Vector2(-1600, -2400)
	var spectated := WorldSnapshots.build_packet(1)
	var teammate := WorldSnapshots.build_packet(-1)
	check(spectated[WorldSnapshotService.P_IDS] == teammate[WorldSnapshotService.P_IDS] and spectated[WorldSnapshotService.P_FLAGS] == teammate[WorldSnapshotService.P_FLAGS], "spectator packet reveals a different set of players from teammate view")
	check(ally.camera.is_current(), "spectator camera did not follow teammate")
	MultiplayerSession.player_names[-3] = "Second ally"
	MultiplayerSession.player_teams[-3] = Teams.ALPHA
	MultiplayerSession.bot_ids.append(-3)
	mode.spawning.spawning_enabled = true
	mode.spawning.spawn_player(-3)
	mode.spawning.spawning_enabled = false
	await get_tree().process_frame
	await get_tree().process_frame
	mode.cycle_spectate(1)
	check(mode.spectate_target.get(1) == -3, "spectate-next did not cycle to another living ally")
	mode.cycle_spectate(-2)
	check(not mode.spectate_target.has(-2), "living opponent could request spectator information")
	WorldSnapshots._last_visible_tick.clear()
	await _free_round_fixture(fixture)

func test_ascii_map_generator_rejects_invalid_layouts() -> void:
	var builder := preload("res://tools/map_builder.gd")
	var source := FileAccess.get_file_as_string("res://tests/fixtures/mini_layout.txt")
	check(String(builder.parse(source).error).is_empty(), "valid mini layout rejected")
	var invalid := {
		"ragged": source.replace("################################", "###############################"),
		"unknown": source.replace("c", "?"),
		"door length": source.replace("----", "---."),
		"no objective": source.replace("O", "."),
		"split objective": source.replace("#..a", "#O.a"),
		"spawn count": source.replace("a", "."),
		"edge door": "----" + source.substr(4),
		"wall overlap": source.replace("#.............----", "#............R----"),
	}
	# Place a wall directly in front of an existing horizontal doorway.
	var rows := source.split("\n")
	rows[6] = rows[6].substr(0, 14) + "#" + rows[6].substr(15)
	invalid["wall overlap"] = "\n".join(rows)
	for reason in invalid:
		check(not String(builder.parse(invalid[reason]).error).is_empty(), "generator accepted " + reason)
	var warned := builder.parse(source)
	check(warned.warnings.is_empty(), "fixture has unexpected prop/wall overlap")
	rows = source.replace("c", ".").split("\n")
	rows[4] = rows[4].substr(0, 16) + "c" + rows[4].substr(17)
	check(not builder.parse("\n".join(rows)).warnings.is_empty(), "overlapping prop did not warn")

func test_map_generator_cli_returns_nonzero_for_invalid_input() -> void:
	var file := FileAccess.open("user://invalid_layout.txt", FileAccess.WRITE)
	file.store_string("?\n")
	file.close()
	var output: Array = []
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://tools/build_map.gd", "--", "--ephemeral-profile", "--layout=user://invalid_layout.txt", "--out=user://invalid_map.tscn"])
	var code := OS.execute(OS.get_executable_path(), args, output, true)
	check(code != 0 and "\n".join(output).contains("Unknown character"), "CLI did not exit with a clear validation failure")

func test_generated_mini_map_preserves_cells_instances_and_fog() -> void:
	var builder := preload("res://tools/map_builder.gd")
	var source := FileAccess.get_file_as_string("res://tests/fixtures/mini_layout.txt")
	var data := builder.parse(source)
	var packed := load("res://tests/fixtures/mini_map.tscn") as PackedScene
	check(packed != null, "generated mini map failed to load")
	if packed == null:
		return
	var saved_viewport := MaskViewProvider.viewport
	var world := packed.instantiate()
	add_child(world)
	var walls := world.get_node("Map/DestructibleWalls") as DestructibleWalls
	check(walls.get_used_cells().size() == data.walls.size() and is_instance_valid(walls.mirror), "saved walls or automatic fog mirror wrong")
	for cell in data.walls:
		check(walls.cell_material(cell) == data.walls[cell], "wrong wall material at %s" % cell)
	check(world.get_node("Map/Doors").get_child_count() == 2, "door runs did not become two instances")
	var vertical := world.get_node("Map/Doors/Door2") as Door
	check_near(vertical.rotation, PI * 0.5, 0.0001, "vertical door rotation wrong")
	check((world.get_node("Map/ObjectiveZone/CollisionShape2D") as CollisionShape2D).shape.size == Vector2(64, 64), "objective bounding box shape was not saved")
	check((world.get_node("Map/ObjectiveZone") as Node2D).position == Vector2(256, 192), "objective centre omitted last row or column")
	check(world.get_node("FowMaskView/Level").get_child_count() == 5, "prop or door fog occluder not derived from collision")
	world.queue_free()
	await get_tree().process_frame
	MaskViewProvider.set_viewport(saved_viewport)
	var generated := builder.build(data, "res://tests/fixtures/mini_layout.txt")
	check(builder.save(generated, "user://mini_map_first.tscn") == OK and builder.save(generated, "user://mini_map_second.tscn") == OK, "could not save deterministic comparison")
	check(FileAccess.get_file_as_string("user://mini_map_first.tscn") == FileAccess.get_file_as_string("user://mini_map_second.tscn"), "identical map generation changed bytes")
	generated.free()

func test_round_map_template_loads_without_legacy_level_geometry() -> void:
	var saved_viewport := MaskViewProvider.viewport
	var packed := load("res://scenes/maps/_template/round_map_template.tscn") as PackedScene
	check(packed != null, "round template failed to load")
	if packed == null:
		return
	var world := packed.instantiate()
	add_child(world)
	check(world.get_node("RoundGameMode") is RoundGameMode and world.get_node("DestructionService") is DestructionService, "template missing round services")
	check(world.get_node("Map/DestructibleWalls") is DestructibleWalls, "template missing typed wall layer")
	check(not world.has_node("FowMaskView/Level/GeneratedOccluders") and not world.has_node("Map/Level"), "template retained legacy geometry")
	for path in ["Map/Floor", "Map/Doors", "Map/Props", "Map/SpawnPoints/AttackerSpawns", "Map/SpawnPoints/DefenderSpawns", "PlayerSpawner", "PickupSpawner", "ProjectileSpawner"]:
		check(world.has_node(path), "template missing " + path)
	world.queue_free()
	await get_tree().process_frame
	MaskViewProvider.set_viewport(saved_viewport)

func test_cqc_map_loads_and_lobby_shows_its_mode_and_preview() -> void:
	var packed := load("res://scenes/maps/cqc_1/cqc_1.tscn") as PackedScene
	check(packed != null, "CQC 1 scene failed to load")
	if packed == null:
		return
	var saved_viewport := MaskViewProvider.viewport
	var world := packed.instantiate()
	add_child(world)
	var walls := world.get_node("Map/DestructibleWalls") as DestructibleWalls
	check(walls.cell_material(Vector2i.ZERO) == DestructionMaterial.HARD and walls.cell_material(Vector2i(188, 64)) == DestructionMaterial.REINFORCED and walls.cell_material(Vector2i(150, 50)) == DestructionMaterial.SOFT, "CQC boundary, exterior and interior material rules wrong")
	check(world.get_node("Map/Doors").get_child_count() == 9, "expected three exterior and six interior doors")
	check(world.get_node("Map/Props").get_child_count() == 15, "outdoor cover instances missing")
	check(world.get_meta("layout_size") == Vector2i(200, 130), "CQC metrics metadata missing")
	world.queue_free()
	await get_tree().process_frame
	MaskViewProvider.set_viewport(saved_viewport)
	var view := LobbyView.new()
	add_child(view)
	view.render({"player_names": {}, "player_avatar_ids": {}, "player_teams": {}, "is_connected": false, "is_server": false, "local_peer_id": 1, "match_started": false, "map_scene_path": "res://scenes/maps/cqc_1/cqc_1.tscn"})
	check((view.find_child("ModeTitle", true, false) as Label).text == "ATTACK / DEFEND", "CQC picker incorrectly shows deathmatch")
	check((view.find_child("MapPreview", true, false) as TextureRect).texture == LobbyView.CQC_PREVIEW, "CQC picker uses the old map preview")
	view.queue_free()
	await get_tree().process_frame

func test_every_lobby_round_map_satisfies_spawn_and_generation_contract() -> void:
	var validator := preload("res://tests/unit/map_validation_tests.gd")
	var saved_viewport := MaskViewProvider.viewport
	var count := 0
	for path in MultiplayerSession.MAPS:
		var world := (load(path) as PackedScene).instantiate() as Node2D
		if not world.has_node("RoundGameMode"):
			world.free()
			continue
		count += 1
		add_child(world)
		await _flush_area_monitoring()
		var errors := validator.validate(world)
		check(errors.is_empty(), "%s: %s" % [path, errors])
		world.queue_free()
		await get_tree().process_frame
		MaskViewProvider.set_viewport(saved_viewport)
	check(count == 2, "did not validate the dev and CQC round maps")

func test_map_validation_catches_blocked_spawns_and_stale_cells() -> void:
	var validator := preload("res://tests/unit/map_validation_tests.gd")
	var saved_viewport := MaskViewProvider.viewport
	var world := (load("res://scenes/maps/cqc_1/cqc_1.tscn") as PackedScene).instantiate() as Node2D
	add_child(world)
	var point := world.get_node("Map/SpawnPoints/AttackerSpawns/Spawn1") as Node2D
	var original := point.position
	point.position = Vector2(8, 8)
	await _flush_area_monitoring()
	check("\n".join(validator.validate(world)).contains("Blocked spawn"), "validation accepted a spawn inside the boundary")
	point.position = original
	var walls := world.get_node("Map/DestructibleWalls") as DestructibleWalls
	walls.destroy_cells([Vector2i(134, 50)])
	check("\n".join(validator.validate(world)).contains("stale"), "validation accepted generated scene drift")
	world.queue_free()
	await get_tree().process_frame
	MaskViewProvider.set_viewport(saved_viewport)

func test_cqc_travel_time_open_sight_lines_and_spawn_privacy() -> void:
	var builder := preload("res://tools/map_builder.gd")
	var routes := preload("res://tests/helpers/map_route.gd")
	var data := builder.parse(FileAccess.get_file_as_string("res://scenes/maps/cqc_1/layout.txt"))
	var grid := routes.grid_for(data)
	var target: Vector2i = data.objective.get_center()
	var runner := PLAYER_SCENE.instantiate() as PlayerController
	var running_speed := runner.speed
	runner.free()
	for spawn in data.attacks:
		var path := grid.get_point_path(spawn, target)
		var seconds := routes.length(path) / running_speed
		check(not path.is_empty() and seconds >= 15.0 and seconds <= 20.0, "attacker %s route %.2f s outside target" % [spawn, seconds])
	var saved_viewport := MaskViewProvider.viewport
	var world := (load("res://scenes/maps/cqc_1/cqc_1.tscn") as PackedScene).instantiate() as Node2D
	add_child(world)
	for door in world.get_node("Map/Doors").get_children():
		(door as Door).set_state_local(Door.State.OPEN)
	await _flush_area_monitoring()
	var sight := routes.longest_sight_line(world, data, grid)
	check(float(sight.length) <= 1440.0, "open sight line exceeds 1440 px: %s" % [sight])
	for attacker in data.attacks:
		for defender in data.defends:
			var query := PhysicsRayQueryParameters2D.create(builder.cell_center(attacker), builder.cell_center(defender), 1)
			check(not world.get_world_2d().direct_space_state.intersect_ray(query).is_empty(), "spawns can see each other")
	world.queue_free()
	await get_tree().process_frame
	MaskViewProvider.set_viewport(saved_viewport)

func test_rounds_dev_map_loads_role_spawns_and_clear_objective() -> void:
	var saved_viewport := MaskViewProvider.viewport
	var world := (load("res://scenes/maps/map_1/map_1_rounds.tscn") as PackedScene).instantiate()
	add_child(world)
	await _flush_area_monitoring()
	var mode := world.get_node("RoundGameMode") as RoundGameMode
	check(mode != null and world.get_node("DestructionService") is DestructionService, "round map missing mode or destruction service")
	check(world.get_node("Map/SpawnPoints/AttackerSpawns").get_child_count() == 5 and world.get_node("Map/SpawnPoints/DefenderSpawns").get_child_count() == 5, "dev round map needs five spawns per role")
	var zone := world.get_node("Map/ObjectiveZone") as ObjectiveZone
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = (zone.get_node("CollisionShape2D") as CollisionShape2D).shape
	query.transform = zone.global_transform
	query.collision_mask = 1
	var hits := get_viewport().world_2d.direct_space_state.intersect_shape(query, 8)
	check(hits.is_empty(), "dev objective overlaps environment: %s" % [hits])
	check(mode.phase_label.text == "Waiting for players" and not mode.objective_bar.visible, "waiting HUD or hidden empty objective bar wrong")
	world.queue_free()
	await get_tree().process_frame
	MaskViewProvider.set_viewport(saved_viewport)

func test_lobby_map_picker_is_host_only_and_updates_mode_title() -> void:
	var view := LobbyView.new()
	add_child(view)
	var payload := {"player_names": {1: "Host", 2: "Client"}, "player_avatar_ids": {}, "player_teams": {1: Teams.ALPHA, 2: Teams.BRAVO}, "is_connected": true, "is_server": true, "local_peer_id": 1, "match_started": false, "map_scene_path": MultiplayerSession.MAPS[1]}
	view.render(payload)
	var picker := view.find_child("CycleMap", true, false) as Button
	var changes: Array = []
	view.map_cycle_requested.connect(func(): changes.append(true))
	check(picker.visible and (view.find_child("ModeTitle", true, false) as Label).text == "ATTACK / DEFEND", "host map picker or round-mode title missing")
	picker.pressed.emit()
	check(changes.size() == 1, "map picker did not emit host selection action")
	payload["is_server"] = false
	payload["local_peer_id"] = 2
	view.render(payload)
	check(not picker.visible, "client can see a map-change control")
	view.queue_free()
	await get_tree().process_frame

func test_weapon_wall_damage_survives_pickups() -> void:
	var weapon := (load("res://resources/weapons/rifle.tres") as Weapon).duplicate() as Weapon
	weapon.wall_damage = 17
	weapon.melee_wall_damage = 33
	var data := weapon.to_dict()
	var restored := Weapon.new_from_dict(data)
	check(restored.wall_damage == 17 and restored.melee_wall_damage == 33, "pickup lost custom wall damage")
	data.erase("wall_damage")
	data.erase("melee_wall_damage")
	restored = Weapon.new_from_dict(data)
	check(restored.wall_damage == 10 and restored.melee_wall_damage == 20, "old pickup missing damage defaults")

func test_bullet_damage_rules() -> void:
	var shooter := await _spawn_player(Vector2(-2400, -2400))
	shooter.rotation = 0.0
	var rifle := shooter.equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance
	var service := DestructionService.new()
	add_child(service)
	var walls := _destructible_wall(rifle.global_position + Vector2(100, -8), [Vector2i.ZERO])
	walls.set_cell(Vector2i(1, 0), 0, Vector2i(DestructionMaterial.REINFORCED, 0))
	walls.update_internals()
	await get_tree().physics_frame
	await get_tree().physics_frame
	for hit in range(3):
		rifle._shoot_raycast()
		check(walls.has_wall(Vector2i.ZERO), "soft cell broke before fourth bullet")
	rifle._shoot_raycast()
	check(not walls.has_wall(Vector2i.ZERO), "four bullets did not break soft cell")
	check(walls.has_wall(Vector2i(1, 0)), "bullet penetrated into the next cell")
	for hit in range(20):
		rifle._shoot_raycast()
	check(walls.has_wall(Vector2i(1, 0)), "bullets broke reinforced cell")
	walls.queue_free()
	service.queue_free()
	shooter.queue_free()
	await get_tree().process_frame

func test_melee_damages_soft_wall() -> void:
	var shooter := await _spawn_player(Vector2(-2400, -2400))
	shooter.rotation = 0.0
	var knife := shooter.equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.MELEE) as WeaponInstance
	var service := DestructionService.new()
	add_child(service)
	var walls := _destructible_wall(knife.global_position + Vector2(20, -8), [Vector2i.ZERO])
	await get_tree().physics_frame
	await get_tree().physics_frame
	knife._shoot_raycast()
	check(walls.has_wall(Vector2i.ZERO), "one knife hit broke 40 HP cell")
	knife._shoot_raycast()
	check(not walls.has_wall(Vector2i.ZERO), "two knife hits did not break soft cell")
	walls.queue_free()
	service.queue_free()
	shooter.queue_free()
	await get_tree().process_frame

func test_explosion_shielded_by_hard_wall() -> void:
	var service := DestructionService.new()
	add_child(service)
	var walls := _destructible_wall(Vector2(-2400, -2400), [Vector2i.ZERO], DestructionMaterial.HARD)
	walls.set_cell(Vector2i(2, 0), 0, Vector2i.ZERO)
	walls.update_internals()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var blast := walls.global_position + Vector2(-24, 8)
	service.apply_explosion(blast, 320.0, 200)
	check(walls.has_wall(Vector2i.ZERO), "hard cell was destroyed")
	check(walls.has_wall(Vector2i(2, 0)) and service._cell_hp.is_empty(), "hard cell failed to shield soft cell")
	walls.destroy_cells([Vector2i.ZERO])
	service.apply_explosion(blast, 320.0, 200)
	check(not walls.has_wall(Vector2i(2, 0)), "exposed soft cell was not damaged")
	walls.queue_free()
	service.queue_free()
	await get_tree().process_frame

func test_frag_respects_cover_and_breaches_reinforced() -> void:
	var service := DestructionService.new()
	add_child(service)
	var protected := await _spawn_player(Vector2(-2200, -2400))
	var exposed := await _spawn_player(Vector2(-2350, -2500))
	var cover := _wall(Vector2(-2280, -2400), Vector2(16, 400))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var frag := FragProjectile.new()
	frag.position = Vector2(-2350, -2400)
	frag.detonate_smoke_scene = null
	add_child(frag)
	frag._detonate()
	check(protected.health_component.current_health == 100, "frag damaged a player through hard cover")
	check(protected.movement_component.external_velocity.is_zero_approx(), "frag pushed player through cover")
	check(exposed.health_component.current_health < 100, "cover blocked an exposed player")
	cover.queue_free()
	await get_tree().process_frame
	var walls := _destructible_wall(Vector2(-2320, -2416), [Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2)], DestructionMaterial.REINFORCED)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var breach_frag := FragProjectile.new()
	breach_frag.position = Vector2(-2350, -2400)
	breach_frag.detonate_smoke_scene = null
	add_child(breach_frag)
	breach_frag._detonate()
	check(walls.destroyed_cells().size() == 3, "200 wall damage failed to breach nearby reinforced cells")
	check(protected.health_component.current_health < 100, "new breach failed to expose the player in the same blast")
	protected.queue_free()
	exposed.queue_free()
	walls.queue_free()
	service.queue_free()
	await get_tree().process_frame

func test_door_states() -> void:
	var old_viewport := MaskViewProvider.viewport
	var viewport := FowViewportController.new()
	var level := Node2D.new()
	level.name = "Level"
	viewport.add_child(level)
	add_child(viewport)
	var door := (load("res://scenes/props/door/door.tscn") as PackedScene).instantiate() as Door
	door.position = Vector2(-2200, -2400)
	add_child(door)
	var source := await _spawn_player(door.global_position + Vector2(0, 50))
	source.net_sync._noise_until_tick = NetworkTick.tick
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_viewport().world_2d.direct_space_state
	var ray := PhysicsRayQueryParameters2D.create(door.global_position + Vector2(0, 60), door.global_position - Vector2(0, 60), 1)
	check(not space.intersect_ray(ray).is_empty() and door.occluder.visible, "closed door missing collision or fog occlusion")
	door.on_interact(source)
	check(door.state == Door.State.OPEN and space.intersect_ray(ray).is_empty() and not door.occluder.visible, "open door still blocks ray or fog")
	check_near(source.net_sync.get_noise_radius(), 250.0, 0.01, "quiet interaction noise wrong")
	door.on_interact(source)
	check(door.state == Door.State.CLOSED and not space.intersect_ray(ray).is_empty(), "interaction did not close door immediately")
	door.apply_damage(59, DestructionMaterial.KIND_BULLET, source)
	check(door.state == Door.State.CLOSED, "door broke before HP depleted")
	door.apply_damage(1, DestructionMaterial.KIND_BULLET, source)
	check(door.state == Door.State.BROKEN and space.intersect_ray(ray).is_empty() and not door.occluder.visible, "broken door still blocks")
	check_near(source.net_sync.get_noise_radius(), 900.0, 0.01, "break noise wrong")
	door.on_interact(source)
	check(door.state == Door.State.BROKEN, "broken door accepted interaction")
	door.restore_all()
	door.apply_damage(59, DestructionMaterial.KIND_BULLET, source)
	check(door.state == Door.State.CLOSED, "restore did not reset door HP")
	door.queue_free()
	source.queue_free()
	await get_tree().process_frame
	check(level.get_child_count() == 0, "door fog occluder leaked")
	MaskViewProvider.set_viewport(old_viewport)
	viewport.queue_free()

func test_door_combat_and_full_state() -> void:
	var source := await _spawn_player(Vector2(-2400, -2400))
	source.rotation = 0.0
	var knife := source.equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.MELEE) as WeaponInstance
	var door := (load("res://scenes/props/door/door.tscn") as PackedScene).instantiate() as Door
	door.position = knife.global_position + Vector2(20, 0)
	door.rotation = PI * 0.5
	add_child(door)
	var service := DestructionService.new()
	add_child(service)
	await get_tree().physics_frame
	await get_tree().physics_frame
	knife._shoot_raycast()
	check(door.state == Door.State.BROKEN, "one knife hit failed to kick door open")
	service.reset_all()
	check(door.state == Door.State.CLOSED and door._hp == 60, "service reset failed to restore door")
	var shield := _wall(door.global_position - Vector2(20, 0), Vector2(8, 120))
	await get_tree().physics_frame
	await get_tree().physics_frame
	service.apply_explosion(door.global_position - Vector2(40, 0), 320, 200, source)
	check(door._hp == 60, "hard cover failed to shield door from blast")
	shield.queue_free()
	await get_tree().process_frame
	service.apply_explosion(door.global_position - Vector2(40, 0), 320, 200, source)
	check(door.state == Door.State.BROKEN, "exposed door did not break in blast")
	var path := get_path_to(door)
	service._full_state({}, {path: Door.State.OPEN})
	service._full_state({}, {path: Door.State.OPEN})
	check(door.state == Door.State.OPEN and door.collision_layer == 0, "door full state was not applied idempotently")
	service.reset_all()
	# Step back after the kick so the animated hand socket cannot start the bullet ray inside the door.
	source.global_position -= Vector2(100, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var rifle := source.equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance
	for hit in range(5):
		rifle._shoot_raycast()
	check(door.state == Door.State.CLOSED, "door broke before six 10-damage bullets")
	rifle._shoot_raycast()
	check(door.state == Door.State.BROKEN, "bullets failed to break door: hp=%d, origin=%s, door=%s, aim=%s" % [door._hp, rifle.global_position, door.global_position, source.global_transform.x])
	door.queue_free()
	service.queue_free()
	source.queue_free()
	await get_tree().process_frame

func test_server_interaction_keeps_pickups_working() -> void:
	var map := Node2D.new()
	map.name = "Map"
	add_child(map)
	var source := await _spawn_player(Vector2(-2400, -2400))
	var pickup := (load("res://scenes/weapon_pickup/base_pickup.tscn") as PackedScene).instantiate() as WeaponPickup
	pickup.name = "InteractTestPickup"
	pickup.position = source.global_position + Vector2(40, 0)
	pickup.freeze = true
	var data := (load("res://resources/weapons/rifle.tres") as Weapon).duplicate() as Weapon
	data.wall_damage = 17
	pickup.set_weapon_data(data)
	pickup.ammo_in_mag = 5
	pickup.ammo_reserve = 10
	map.add_child(pickup)
	await get_tree().create_timer(0.3).timeout
	check(source.interactables.has(pickup.interactable_component), "pickup did not register nearby player")
	source.net_sync._remote_interact(pickup.interactable_component.get_path())
	var rifle := source.equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance
	check(rifle.data.wall_damage == 17 and rifle.ammo_in_mag == 5 and rifle.ammo_reserve == 10, "server interaction failed to pick up weapon and ammo")
	await get_tree().process_frame
	check(not is_instance_valid(pickup), "picked-up weapon remained in the world")
	map.queue_free()
	source.queue_free()
	await get_tree().process_frame

func test_interactable_tracks_multiple_players() -> void:
	var first := await _spawn_player(Vector2(-2400, -2400))
	var second := await _spawn_player(Vector2(-2400, -2360))
	var door := (load("res://scenes/props/door/door.tscn") as PackedScene).instantiate() as Door
	door.position = Vector2(-2400, -2370)
	add_child(door)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var interactable := door.get_node("Interactable") as Interactable
	check(first.interactables.has(interactable) and second.interactables.has(interactable), "door did not register both players")
	first.global_position += Vector2(-300, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(not first.interactables.has(interactable) and second.interactables.has(interactable), "departing player left stale or removed another player's interaction")
	first.net_sync._remote_interact(interactable.get_path())
	check(door.state == Door.State.CLOSED, "out-of-range player interacted with door")
	second.net_sync._remote_interact(interactable.get_path())
	check(door.state == Door.State.OPEN, "nearby player could not interact with door")
	door.queue_free()
	first.queue_free()
	second.queue_free()
	await get_tree().process_frame

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

func test_hearing_attenuates_soft_walls_and_holes() -> void:
	var listener := await _spawn_player(Vector2(-2400, -2400))
	var source := await _spawn_player(Vector2(-1900, -2400))
	source.net_sync.report_noise(800, 2.0)
	var walls := _destructible_wall(Vector2(-2150, -2408), [Vector2i.ZERO])
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_viewport().world_2d.direct_space_state
	check_near(VisibilityQuery.occlusion_factor(listener.global_position, source.global_position, space), 0.6, 0.001, "soft wall factor wrong")
	check(not VisibilityQuery.can_hear(listener, source), "single soft wall should reduce 800 px to 480, below 500 px")
	source.global_position = listener.global_position + Vector2(450, 0)
	check(VisibilityQuery.can_hear(listener, source), "one soft wall should still carry sound to 450 px")
	walls.set_cell(Vector2i(2, 0), 0, Vector2i.ZERO)
	walls.update_internals()
	await get_tree().physics_frame
	await get_tree().physics_frame
	check_near(VisibilityQuery.occlusion_factor(listener.global_position, source.global_position, space), 0.36, 0.001, "stacked soft wall factors do not multiply")
	check(not VisibilityQuery.can_hear(listener, source), "stacked walls should block footsteps at 450 px")
	walls.destroy_cells([Vector2i.ZERO, Vector2i(2, 0)])
	check(VisibilityQuery.can_hear(listener, source), "holes did not restore hearing immediately")
	walls.queue_free()
	listener.queue_free()
	source.queue_free()
	await get_tree().process_frame

func test_hearing_materials_doors_and_hit_limit() -> void:
	var from := Vector2(-2400, -2400)
	var to := Vector2(-1900, -2400)
	var space := get_viewport().world_2d.direct_space_state
	for material in [DestructionMaterial.REINFORCED, DestructionMaterial.HARD]:
		var walls := _destructible_wall(Vector2(-2150, -2408), [Vector2i.ZERO], material)
		await get_tree().physics_frame
		await get_tree().physics_frame
		check_near(VisibilityQuery.occlusion_factor(from, to, space), DestructionMaterial.sound_factor(material), 0.001, "wall material factor wrong")
		walls.queue_free()
		await get_tree().process_frame
	var wall := _wall(Vector2(-2150, -2400), Vector2(8, 100))
	await get_tree().physics_frame
	await get_tree().physics_frame
	check_near(VisibilityQuery.occlusion_factor(from, to, space), 0.35, 0.001, "static wall factor wrong")
	wall.queue_free()
	await get_tree().process_frame
	var door := (load("res://scenes/props/door/door.tscn") as PackedScene).instantiate() as Door
	door.position = Vector2(-2150, -2400)
	door.rotation = PI * 0.5
	add_child(door)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check_near(VisibilityQuery.occlusion_factor(from, to, space), 0.7, 0.001, "closed door factor wrong")
	door.set_state_local(Door.State.OPEN)
	check_near(VisibilityQuery.occlusion_factor(from, to, space), 1.0, 0.001, "open door still attenuates sound")
	door.queue_free()
	await get_tree().process_frame
	var cells: Array[Vector2i] = []
	for x in range(5):
		cells.append(Vector2i(x * 2, 0))
	var stacked := _destructible_wall(Vector2(-2250, -2408), cells)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check_near(VisibilityQuery.occlusion_factor(from, to, space), pow(0.6, 4), 0.001, "hearing ray did not stop at four hits")
	stacked.queue_free()
	await get_tree().process_frame

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

func test_host_hides_enemies_with_no_remote_peers() -> void:
	var host := await _spawn_player(Vector2(-2400, -2400))
	var enemy := await _spawn_player(Vector2(-2800, -2400))
	var ally := await _spawn_player(Vector2(-2800, -2300))
	host.owner_peer_id = 1
	host.team = Teams.ALPHA
	enemy.owner_peer_id = -10
	enemy.team = Teams.BRAVO
	ally.owner_peer_id = -11
	ally.team = Teams.ALPHA
	host.rotation = 0.0
	WorldSnapshots._last_visible_tick.clear()
	WorldSnapshots._last_sent_tick = NetworkTick.tick - WorldSnapshotService.SEND_INTERVAL_TICKS
	WorldSnapshots._physics_process(NetworkTick.get_tick_delta())
	check(multiplayer.get_peers().is_empty() and not enemy.visible and ally.visible and host.visible, "host with no remote clients did not filter its own enemy view")
	enemy.global_position = host.global_position + Vector2(400, 0)
	WorldSnapshots._last_sent_tick = NetworkTick.tick - WorldSnapshotService.SEND_INTERVAL_TICKS
	WorldSnapshots._physics_process(NetworkTick.get_tick_delta())
	check(enemy.visible, "enemy did not reappear in host line of sight")
	host.queue_free()
	enemy.queue_free()
	ally.queue_free()
	await get_tree().process_frame
	WorldSnapshots._last_visible_tick.clear()

func _effective_canvas_material(item: CanvasItem) -> Material:
	while item.use_parent_material:
		item = item.get_parent() as CanvasItem
		if item == null:
			return null
	return item.material

func test_character_body_inherits_enemy_fog_and_allied_unmasking() -> void:
	var actor := await _spawn_player(Vector2(-2400, -2400))
	actor.owner_peer_id = -20
	actor.team = Teams.BRAVO
	actor.apply_team_visuals(Teams.ALPHA)
	var body := actor.skeletal_character.get_node("polygons")
	for child in body.get_children():
		var polygon := child as Polygon2D
		if polygon != null:
			check(_effective_canvas_material(polygon) == actor._fog_material, "body polygon bypasses the enemy fog material: " + polygon.name)
	actor.apply_team_visuals(Teams.BRAVO)
	for child in body.get_children():
		var polygon := child as Polygon2D
		if polygon != null:
			check(_effective_canvas_material(polygon) == null, "allied body polygon remained masked: " + polygon.name)
	actor.queue_free()
	await get_tree().process_frame

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
