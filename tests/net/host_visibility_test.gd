extends "res://tests/net/net_test_base.gd"

const WALL := preload("res://tests/fixtures/test_wall.tscn")
var _ally_id := 0
var _enemy_id := 0
var _wall: DestructibleWalls

func run_host_lobby() -> void:
	_ally_id = MultiplayerSession.add_bot()
	_enemy_id = MultiplayerSession.add_bot()
	for id in [1, _ally_id]:
		MultiplayerSession.set_team(id, Teams.ALPHA)
	for id in [client_peer(), _enemy_id]:
		MultiplayerSession.set_team(id, Teams.BRAVO)
	MultiplayerSession.set_selected_map_scene_path("res://scenes/maps/map_1/map_1_rounds.tscn")

func _spawn_wall(pose: Vector2) -> void:
	_wall = WALL.instantiate() as DestructibleWalls
	_wall.name = "HostVisibilityWall"
	_wall.position = pose
	game_mode().map.add_child(_wall)

func on_message(key: String, value: Variant) -> void:
	if role != "client":
		return
	if key == "wall":
		_spawn_wall(value)
		send("wall_ready")
	elif key.begins_with("probe:"):
		var target := player(int(value))
		send("state:" + key.trim_prefix("probe:"), {"drawn": target != null and target.visible, "presence": target.net_sync._net_presence if target != null else -1})

func _sample(tag: String, id: int) -> Dictionary:
	send("probe:" + tag, id)
	var report: Variant = await wait_for("state:" + tag, 4.0)
	return report if report is Dictionary else {}

## Compare a rendered actor patch with/without its mesh. A masked body must
## produce the same pixels; an in-view enemy and an unmasked ally must not.
func _mesh_pixel_difference(actor: PlayerController) -> int:
	# Centre the fixture camera on the target; vision still originates at the host.
	player(1).camera.global_position = actor.global_position
	await get_tree().process_frame
	await get_tree().process_frame
	var point := actor.get_global_transform_with_canvas().origin
	var region := Rect2i(Vector2i(point) - Vector2i(48, 48), Vector2i(96, 96))
	if not Rect2i(Vector2i.ZERO, Vector2i(get_viewport().get_visible_rect().size)).encloses(region):
		results.fail("render_setup", "actor patch is off-screen: %s" % region)
		return -1
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	var visible_patch := get_viewport().get_texture().get_image().get_region(region)
	actor.skeletal_character.hide()
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	var hidden_patch := get_viewport().get_texture().get_image().get_region(region)
	actor.skeletal_character.show()
	var changed := 0
	for y in range(region.size.y):
		for x in range(region.size.x):
			var delta := visible_patch.get_pixel(x, y) - hidden_patch.get_pixel(x, y)
			if absf(delta.r) + absf(delta.g) + absf(delta.b) > 0.05:
				changed += 1
	return changed

func run_host() -> void:
	var mode := game_mode() as RoundGameMode
	if not await wait_until(func(): return mode.phase == RoundGameMode.Phase.LIVE, 8.0):
		finish_with_failure("setup", "round did not become live")
		return
	var host := player(1)
	var enemy := player(_enemy_id)
	var ally := player(_ally_id)
	var origin := find_open_spot(Vector2.RIGHT, 1000.0)
	if origin == Vector2.INF:
		finish_with_failure("setup", "no clear host fixture location")
		return
	host.global_position = origin
	host.rotation = 0.0
	host.player_input.set_process(false)
	host.player_input.input_vector = Vector2.ZERO
	host.player_input.mouse_pos = origin + Vector2(1000, 0)
	host.camera.position = Vector2.ZERO
	host.camera.zoom = Vector2.ONE
	host.reset_footstep_tracking()
	player(client_peer()).global_position = origin + Vector2(650, -150)
	enemy.global_position = origin + Vector2(400, 0)
	ally.global_position = origin + Vector2(400, 60)
	for actor in [enemy, ally]:
		actor.reset_footstep_tracking()
		bot(actor.owner_peer_id).stop()
	_spawn_wall(origin + Vector2(192, -96))
	send("wall", _wall.position)
	if await wait_for("wall_ready", 4.0) == null:
		finish_with_failure("setup", "client wall missing")
		return
	await hold(0.6)
	check("host_enemy_behind_wall_is_hidden", not VisibilityQuery.can_see(host, enemy, []) and not enemy.visible and enemy.net_sync._net_presence == PlayerNetSync.NetPresence.CULLED, "host culls an occluded enemy")
	check("host_teammate_behind_wall_is_visible", ally.visible and ally.skeletal_character.material == null, "host keeps its teammate visible through cover")
	var client := await _sample("teammate", _enemy_id)
	check("host_culling_does_not_hide_client_teammate", client.get("drawn", false) and client.get("presence") == PlayerNetSync.NetPresence.VISIBLE, "the same actor is hidden on host and visible to its allied client")
	await capture_frame("occluded")

	var before := enemy.global_position
	enemy.health_component.take_damage(1, 1)
	bot(_enemy_id).slow_walk_held = true
	bot(_enemy_id).aim_dir = Vector2.UP
	bot(_enemy_id).move = Vector2(0, -1)
	await hold(0.25)
	bot(_enemy_id).stop()
	check("hidden_host_enemy_still_simulates", enemy.global_position.distance_to(before) > 20.0 and enemy.health_component.current_health == 99 and not enemy.visible, "render culling leaves authoritative movement and damage active")
	enemy.global_position = before
	enemy.reset_footstep_tracking()
	enemy.net_sync.report_noise(1200, 0.5)
	await hold(0.1)
	check("host_audible_enemy_stays_hidden", enemy.net_sync._net_presence == PlayerNetSync.NetPresence.AUDIBLE and not enemy.visible, "hearing the enemy does not reveal its body")

	var service := DestructionService.current(get_tree())
	for cell in [Vector2i(0, 4), Vector2i(0, 5), Vector2i(0, 6)]:
		service.apply_cell_damage(_wall, cell, 40, DestructionMaterial.KIND_BULLET)
	await hold(0.3)
	check("host_enemy_reappears_through_breach", VisibilityQuery.can_see(host, enemy, []) and enemy.visible, "host reveals the enemy when the wall opens")
	await capture_frame("breached")
	if DisplayServer.get_name() != "headless":
		var pixels := await _mesh_pixel_difference(enemy)
		check("host_visible_enemy_has_rendered_pixels", pixels > 20, "%d body pixels visible in front" % pixels)
		enemy.global_position = origin + Vector2.RIGHT.rotated(deg_to_rad(70.0)) * 250.0
		enemy.reset_footstep_tracking()
		await hold(0.15)
		check("host_render_margin_fixture", enemy.visible and VisibilityQuery.can_see(host, enemy, []), "server margin includes the enemy outside the exact visual cone")
		pixels = await _mesh_pixel_difference(enemy)
		check("host_body_respects_exact_fog_mask", pixels == 0, "%d body pixels outside visual cone" % pixels)
		await capture_frame("masked-margin")
		ally.global_position = origin + Vector2(-300, 100)
		ally.reset_footstep_tracking()
		await hold(0.1)
		pixels = await _mesh_pixel_difference(ally)
		check("host_allied_body_bypasses_fog_mask", pixels > 20, "%d allied body pixels outside visual cone" % pixels)
		host.camera.position = Vector2.ZERO

	ally.global_position = origin + Vector2(-300, 0)
	enemy.global_position = origin + Vector2(-450, 0)
	bot(_ally_id).aim_dir = Vector2.LEFT
	for actor in [enemy, ally]:
		actor.reset_footstep_tracking()
	await hold(0.6)
	check("host_teammate_sight_does_not_reveal_enemy", VisibilityQuery.can_see(ally, enemy, []) and not enemy.visible, "teammate sight cannot reveal an enemy behind the host")

	ally.global_position = origin + Vector2(500, 0)
	bot(_ally_id).aim_dir = Vector2.RIGHT
	enemy.global_position = origin + Vector2(300, 0)
	for actor in [enemy, ally]:
		actor.reset_footstep_tracking()
	await hold(0.3)
	host.health_component.take_damage(500, client_peer())
	await hold(0.5)
	check("host_spectator_uses_ally_view", mode.local_spectate_target == _ally_id and MaskViewProvider.viewport.player == ally and not enemy.visible, "dead host loses corpse sight and uses its ally's view")
	enemy.global_position = origin + Vector2(900, 0)
	enemy.reset_footstep_tracking()
	await hold(0.3)
	check("host_spectator_sees_ally_visible_enemy", enemy.visible, "spectated teammate's visible enemy appears")
	ally.health_component.take_damage(500, client_peer())
	await hold(0.3)
	check("host_without_living_teammate_has_no_enemy_view", mode.local_spectate_target == 0 and not enemy.visible, "no remaining teammate means no enemy vision")
