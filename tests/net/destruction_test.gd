extends "res://tests/net/net_test_base.gd"

## Walls are indestructible; doors (doors suite) and breakable props are the
## destructibles. This suite covers a crate between the client and the host.
const FIXTURE := preload("res://tests/fixtures/test_crate.tscn")
var _crate: BreakableProp

func _spawn_fixture(pose: Array) -> void:
	_crate = FIXTURE.instantiate() as BreakableProp
	_crate.name = "TestCrate"
	_crate.position = pose[0]
	_crate.rotation = pose[1]
	game_mode().map.add_child(_crate)

func _fog_blocking() -> bool:
	if _crate._fog_occluders.is_empty():
		return false
	for occluder in _crate._fog_occluders:
		if not occluder.visible:
			return false
	return true

func on_message(key: String, value: Variant) -> void:
	if role != "client":
		return
	if key == "spawn_fixture":
		_spawn_fixture(value)
		await get_tree().process_frame # fog occluders link deferred
		send("fixture_ready")
	elif key == "attempt_damage":
		_crate.apply_damage(1000, DestructionMaterial.KIND_BULLET)
		DestructionService.current(get_tree()).reset_all()
		send("authority_guard", not _crate.broken and _crate.collision_layer == 1)
	elif key.begins_with("sample:"):
		_reply_sample(key.trim_prefix("sample:"))

func _reply_sample(tag: String) -> void:
	if tag == "broken":
		await wait_until(func(): return _crate.broken, 0.45)
	elif tag == "visible":
		await wait_until(func(): return player(1).net_sync._net_presence == PlayerNetSync.NetPresence.VISIBLE, 0.5)
	elif tag == "resync":
		# Simulate a stale map: the client missed the break event.
		_crate.set_broken_local(false)
		var service := DestructionService.current(get_tree())
		service.request_state.rpc_id(1)
		service.request_state.rpc_id(1)
		await wait_until(func(): return _crate.broken, 1.0)
	elif tag == "reset":
		await wait_until(func(): return not _crate.broken, 0.5)
	var host_player := player(1)
	send("result:" + tag, {
		"broken": _crate.broken,
		"collision": _crate.collision_layer,
		"drawn_crate": _crate.visible,
		"fog": _fog_blocking(),
		"fog_count": _crate._fog_occluders.size(),
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
	var center := open + facing * 160
	var pose := [center, facing.angle()]
	_spawn_fixture(pose)
	send("spawn_fixture", pose)
	if await wait_for("fixture_ready", 5.0) == null:
		finish_with_failure("setup", "client fixture missing")
		return
	me.global_position = center + facing * 160
	await hold(1.0)
	send("attempt_damage")
	var guarded: Variant = await wait_for("authority_guard", 3.0)
	check("client_cannot_damage_or_reset_props", guarded == true and not _crate.broken and _crate.hp() == _crate.max_hp, "client damage and reset calls left the crate intact on both peers")
	var intact := await _sample("intact")
	check("intact_crate_blocks_vision", intact.get("presence") == PlayerNetSync.NetPresence.CULLED and not intact.get("drawn", true) and intact.get("fog", false), "client=%s server_see=%s viewer=%s host=%s crate=%s" % [intact, VisibilityQuery.can_see(viewer, me, []), viewer.global_position, me.global_position, _crate.global_transform])
	var start_tick := NetworkTick.tick
	_crate.apply_damage(_crate.max_hp, DestructionMaterial.KIND_BULLET)
	var broken := await _sample("broken")
	var elapsed := int(broken.get("received_tick", NetworkTick.tick)) - start_tick
	check("broken_prop_replicates", broken.get("broken", false) and broken.get("collision") == 0 and not broken.get("drawn_crate", true) and not broken.get("fog", true) and elapsed <= 30, "break, collision, sprite and fog replicated in %d ticks: %s" % [elapsed, broken])
	var visible := await _sample("visible")
	check("broken_prop_opens_server_sight", visible.get("presence") == PlayerNetSync.NetPresence.VISIBLE and visible.get("drawn", false), "host becomes visible where the crate stood")
	var resync := await _sample("resync")
	check("late_state_resync", resync.get("broken", false) and resync.get("collision") == 0 and not resync.get("fog", true), "repeated full state repairs a missed break")
	DestructionService.current(get_tree()).reset_all()
	var reset := await _sample("reset")
	check("reset_restores_props", not reset.get("broken", true) and reset.get("collision") == 1 and reset.get("drawn_crate", false) and reset.get("fog", false) and not _crate.broken and _crate.hp() == _crate.max_hp, "crate HP, collision, sprite and fog restored on both peers")
