extends "res://tests/net/net_test_base.gd"

const FIXTURE := preload("res://tests/fixtures/test_door.tscn")
var _door: Door

func _spawn_fixture(pose: Array) -> void:
	_door = FIXTURE.instantiate() as Door
	_door.name = "TestDoor"
	_door.position = pose[0]
	_door.rotation = pose[1]
	game_mode().map.add_child(_door)

func on_message(key: String, value: Variant) -> void:
	if role != "client":
		return
	if key == "spawn_fixture":
		_spawn_fixture(value)
		send("fixture_ready")
	elif key == "attempt_interaction":
		_door.on_interact(local_player())
		_door.apply_damage(1000, DestructionMaterial.KIND_MELEE, local_player())
		send("authority_guard", _door.state == Door.State.CLOSED)
	elif key.begins_with("sample:"):
		_reply_sample(key.trim_prefix("sample:"), int(value))

func _reply_sample(tag: String, source_id: int) -> void:
	await wait_until(func(): return player(source_id) != null, 2.0)
	if tag == "open":
		await wait_until(func(): return _door.state == Door.State.OPEN and player(source_id).net_sync._net_presence == PlayerNetSync.NetPresence.VISIBLE, 0.5)
	elif tag == "broken":
		await wait_until(func(): return _door.state == Door.State.BROKEN and player(source_id).net_sync._net_presence == PlayerNetSync.NetPresence.AUDIBLE, 0.6)
	elif tag == "resync":
		_door.set_state_local(Door.State.CLOSED)
		DestructionService.current(get_tree()).request_state.rpc_id(1)
		await wait_until(func(): return _door.state == Door.State.BROKEN, 1.0)
	elif tag == "reset":
		await wait_until(func(): return _door.state == Door.State.CLOSED, 0.5)
	var source := player(source_id)
	send("result:" + tag, {
		"state": _door.state,
		"collision": _door.collision_layer,
		"occlusion": _door.occluder.visible if is_instance_valid(_door.occluder) else false,
		"presence": source.net_sync._net_presence if source != null else -1,
		"drawn": source.visible if source != null else false,
	})
	await capture_frame(tag)
	send("captured:" + tag)

func _sample(tag: String, source_id: int = 1) -> Dictionary:
	send("sample:" + tag, source_id)
	var reply: Variant = await wait_for("result:" + tag, 5.0)
	if await wait_for("captured:" + tag, 5.0) == null:
		results.fail("sample", "client did not complete capture checkpoint %s" % tag)
	return reply if reply is Dictionary else {}

func run_host() -> void:
	var viewer := player(client_peer())
	var me := player(1)
	var facing := Vector2.RIGHT.rotated(viewer.rotation)
	var open := find_open_spot(facing, 800)
	if open == Vector2.INF:
		finish_with_failure("setup", "no clear door fixture location")
		return
	viewer.global_position = open
	await hold(0.8)
	facing = Vector2.RIGHT.rotated(viewer.rotation)
	var center := open + facing * 120
	var pose := [center, facing.angle() - PI * 0.5]
	_spawn_fixture(pose)
	send("spawn_fixture", pose)
	if await wait_for("fixture_ready", 5.0) == null:
		finish_with_failure("setup", "client door fixture missing")
		return
	me.global_position = center + facing * 45
	await hold(1.0)
	send("attempt_interaction")
	var guarded: Variant = await wait_for("authority_guard", 3.0)
	check("client_cannot_change_door_state", guarded == true and _door.state == Door.State.CLOSED, "client-side interaction and damage are ignored")
	var closed := await _sample("closed")
	check("closed_door_blocks_vision", closed.get("state") == Door.State.CLOSED and closed.get("occlusion", false) and closed.get("presence") == PlayerNetSync.NetPresence.CULLED, "closed door blocks collision, fog and server sight")
	me.net_sync._remote_interact(_door.get_node("Interactable").get_path())
	var quiet_radius := me.net_sync.get_noise_radius()
	var opened := await _sample("open")
	check("interact_opens_quietly", opened.get("state") == Door.State.OPEN and opened.get("collision") == 0 and not opened.get("occlusion", true) and opened.get("presence") == PlayerNetSync.NetPresence.VISIBLE and is_equal_approx(quiet_radius, 250.0), "server interaction replicated OPEN, visibility and 250 px noise")
	DestructionService.current(get_tree()).reset_all()
	me.global_position = center + facing.orthogonal() * 800
	var bot_id := await add_bot()
	if bot_id == 0:
		return
	MultiplayerSession.set_team(bot_id, Teams.ALPHA)
	MultiplayerSession.set_team(viewer.owner_peer_id, Teams.BRAVO)
	var puppet := player(bot_id)
	var brain := bot(bot_id)
	brain.slot_select = EquipmentManager.EquipmentSlot.MELEE
	brain.aim_dir = -facing
	puppet.global_position = center + facing * 50
	await hold(1.0)
	var knife := puppet.get_current_equipment() as WeaponInstance
	if knife == null or knife.data.uses_ammo:
		finish_with_failure("setup", "puppet did not equip the knife")
		return
	# Align the normal knife ray within its 30 px reach, independent of idle hand pose.
	puppet.global_position += center + facing * 20 - knife.global_position
	viewer.global_position = puppet.global_position + facing * 600
	await hold(0.3)
	check("kick_listener_is_out_of_sight", not VisibilityQuery.can_see(viewer, puppet, []) and is_equal_approx(viewer.global_position.distance_to(puppet.global_position), 600.0), "listener is 600 px away, facing away from the source")
	brain.fire_held = true
	var kicked := await wait_until(func(): return _door.state == Door.State.BROKEN, 2.0)
	brain.stop()
	var loud_radius := puppet.net_sync.get_noise_radius()
	var broken := await _sample("broken", bot_id)
	check("kick_breaks_loudly", kicked and broken.get("state") == Door.State.BROKEN and broken.get("collision") == 0 and not broken.get("occlusion", true) and broken.get("presence") == PlayerNetSync.NetPresence.AUDIBLE and not broken.get("drawn", true) and is_equal_approx(loud_radius, 900.0), "normal bot knife input breaks the door; the hidden source is audible at 600 px with 900 px noise")
	var resync := await _sample("resync", bot_id)
	check("late_state_restores_broken_door", resync.get("state") == Door.State.BROKEN and resync.get("collision") == 0, "full state restores the permanent breach")
	DestructionService.current(get_tree()).reset_all()
	var reset := await _sample("reset", bot_id)
	check("reset_restores_door", _door.state == Door.State.CLOSED and _door._hp == 60 and reset.get("state") == Door.State.CLOSED and reset.get("collision") == 1 and reset.get("occlusion", false), "reset restores HP, collision and fog on both peers")
