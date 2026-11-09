extends "res://tests/net/net_test_base.gd"

const FIXTURE := preload("res://tests/fixtures/test_wall.tscn")
const HOLE_CELLS: Array[Vector2i] = [Vector2i(0, 4), Vector2i(0, 5), Vector2i(0, 6)]
var _walls: DestructibleWalls

func _spawn_fixture(pose: Array) -> void:
	_walls = FIXTURE.instantiate() as DestructibleWalls
	_walls.name = "TestWall"
	_walls.position = pose[0]
	_walls.rotation = pose[1]
	game_mode().map.add_child(_walls)

func _has_holes(cells: Array) -> bool:
	if cells.size() != HOLE_CELLS.size():
		return false
	for cell in HOLE_CELLS:
		if not cells.has(cell):
			return false
	return true

func on_message(key: String, value: Variant) -> void:
	if role != "client":
		return
	if key == "spawn_fixture":
		_spawn_fixture(value)
		send("fixture_ready")
	elif key == "attempt_damage":
		var service := DestructionService.current(get_tree())
		service.apply_cell_damage(_walls, Vector2i.ZERO, 1000, DestructionMaterial.KIND_BULLET)
		service.reset_all()
		send("authority_guard", _walls.get_used_cells().size() == 12)
	elif key.begins_with("sample:"):
		_reply_sample(key.trim_prefix("sample:"))

func _reply_sample(tag: String) -> void:
	if tag == "holes":
		await wait_until(func(): return _has_holes(_walls.destroyed_cells()), 0.45)
	elif tag == "visible":
		await wait_until(func(): return player(1).net_sync._net_presence == PlayerNetSync.NetPresence.VISIBLE, 0.5)
	elif tag == "resync":
		# Simulate a stale map: both missing authoritative holes and an extra local hole.
		_walls.restore_all()
		_walls.destroy_cells([Vector2i.ZERO])
		var service := DestructionService.current(get_tree())
		service.request_state.rpc_id(1)
		service.request_state.rpc_id(1)
		await wait_until(func(): return _has_holes(_walls.destroyed_cells()), 1.0)
	elif tag == "reset":
		await wait_until(func(): return _walls.get_used_cells().size() == 12, 0.5)
	var host_player := player(1)
	send("result:" + tag, {
		"cells": _walls.destroyed_cells(),
		"count": _walls.get_used_cells().size(),
		"mirror_count": _walls.mirror.get_used_cells().size() if is_instance_valid(_walls.mirror) else -1,
		"presence": host_player.net_sync._net_presence if host_player != null else -1,
		"drawn": host_player.visible if host_player != null else false,
	})
	await capture_frame(tag)
	send("captured:" + tag)

func _sample(tag: String) -> Dictionary:
	send("sample:" + tag)
	var reply: Variant = await wait_for("result:" + tag, 5.0)
	if reply is Dictionary:
		reply["received_tick"] = NetworkTick.tick
	# Keep screenshot encoding outside replication timing, but finish the frame before changing geometry.
	if await wait_for("captured:" + tag, 5.0) == null:
		results.fail("sample", "client did not complete capture checkpoint %s" % tag)
	return reply if reply is Dictionary else {}

func run_host() -> void:
	var viewer := player(client_peer())
	var me := player(1)
	var facing := Vector2.RIGHT.rotated(viewer.rotation)
	var open := find_open_spot(facing, 400)
	if open == Vector2.INF:
		finish_with_failure("setup", "no clear fixture location")
		return
	viewer.global_position = open
	await hold(0.8)
	facing = Vector2.RIGHT.rotated(viewer.rotation)
	var center := open + facing * 120
	var pose := [center - facing * 8 - Vector2.DOWN.rotated(facing.angle()) * 96, facing.angle()]
	_spawn_fixture(pose)
	send("spawn_fixture", pose)
	if await wait_for("fixture_ready", 5.0) == null:
		finish_with_failure("setup", "client fixture missing")
		return
	me.global_position = center + facing * 120
	await hold(1.0)
	send("attempt_damage")
	var guarded: Variant = await wait_for("authority_guard", 3.0)
	check("client_cannot_damage_or_reset_walls", guarded == true and _walls.get_used_cells().size() == 12, "client damage and reset calls left both grids intact")
	var intact := await _sample("intact")
	check("intact_wall_blocks_vision", intact.get("presence") == PlayerNetSync.NetPresence.CULLED and not intact.get("drawn", true), "client=%s server_see=%s noise=%.1f viewer=%s host=%s wall=%s" % [intact, VisibilityQuery.can_see(viewer, me, []), me.net_sync.get_noise_radius(), viewer.global_position, me.global_position, _walls.global_transform])
	var service := DestructionService.current(get_tree())
	var start_tick := NetworkTick.tick
	for cell in HOLE_CELLS:
		service.apply_cell_damage(_walls, cell, 40, DestructionMaterial.KIND_BULLET)
	var holes := await _sample("holes")
	var elapsed := int(holes.get("received_tick", NetworkTick.tick)) - start_tick
	check("destroyed_cells_replicate", _has_holes(holes.get("cells", [])) and holes.get("mirror_count") == 9 and elapsed <= 30, "three holes and fog mirror replicated in %d ticks" % elapsed)
	var visible := await _sample("visible")
	check("hole_opens_server_sight", visible.get("presence") == PlayerNetSync.NetPresence.VISIBLE and visible.get("drawn", false), "host becomes visible through the breach")
	var resync := await _sample("resync")
	check("late_state_resync", _has_holes(resync.get("cells", [])) and resync.get("mirror_count") == 9, "repeated full state repairs missing and extra holes")
	service.reset_all()
	var reset := await _sample("reset")
	check("reset_restores_walls", reset.get("count") == 12 and reset.get("mirror_count") == 12 and _walls.get_used_cells().size() == 12, "all twelve cells restored on both peers and in fog mirror")
