extends "res://tests/net/net_test_base.gd"

## Server-side fog of war + audio presence. The host moves its own player
## around the (idle) client's player and, at the end of each scenario, asks
## the client how it perceives the host player. Expected:
##   in view            -> VISIBLE, drawn
##   behind, silent     -> CULLED, not drawn
##   behind, walking    -> AUDIBLE, not drawn, footsteps playing, true position
##   behind, shooting   -> the shot plays from the true position
##   behind a wall      -> CULLED; walking there -> AUDIBLE with footsteps
##   smoke in between   -> CULLED
##   back in view       -> VISIBLE

const AUDIBLE_POSITION_TOLERANCE := 40.0 # interpolation delay while walking

var _expected_pos := {}
# client: proxy state when the host player's first shot was simulated
var _shot_seen: Variant = null
var _prev_firing := false

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if role != "client" or _shot_seen != null:
		return
	var host_player := player(1)
	if host_player == null:
		return
	var weapon := host_player.get_current_equipment() as WeaponInstance
	var firing := weapon != null and (weapon.is_firing or weapon._cooldown_ticks_remaining > 0)
	if firing and not _prev_firing:
		_shot_seen = {
			"presence": host_player.net_sync._net_presence,
			"position": host_player.global_position,
		}
	_prev_firing = firing

func on_message(key: String, value: Variant) -> void:
	if role != "client":
		return
	if key.begins_with("sample:"):
		var host_player := player(1)
		var reply := {}
		if host_player != null:
			var sounds := 0
			for node in host_player.find_children("*", "AudioStreamPlayer2D", true, false):
				if (node as AudioStreamPlayer2D).playing:
					sounds += 1
			reply = {
				"presence": host_player.net_sync._net_presence,
				"drawn": host_player.visible,
				"position": host_player.global_position,
				"footsteps": host_player.footstep_player.playing,
				"sounds": sounds,
			}
		send("result:" + key.trim_prefix("sample:"), reply)
	elif key == "shot?":
		send("result:shot", _shot_seen if _shot_seen != null else {})

func run_client() -> void:
	pass # the client only answers samples (on_message)

## Ask the client how it sees the host player right now.
func _sample(scenario: String) -> Dictionary:
	_inbox.erase("result:" + scenario)
	send("sample:" + scenario)
	var reply: Variant = await wait_for("result:" + scenario, 5.0)
	return reply if reply is Dictionary else {}

func _expect(scenario: String, reply: Dictionary, presence: PlayerNetSync.NetPresence, drawn: bool, footsteps: Variant = null, true_pos: Variant = null) -> void:
	if reply.is_empty():
		results.fail(scenario, "no answer from the client")
		return
	var got: int = reply["presence"]
	var ok: bool = got == presence and bool(reply["drawn"]) == drawn
	var detail := "presence=%s drawn=%s" % [PlayerNetSync.NetPresence.keys()[got], reply["drawn"]]
	if footsteps != null:
		ok = ok and bool(reply["footsteps"]) == footsteps
		detail += " footsteps=%s" % reply["footsteps"]
	if true_pos != null:
		var off: float = (reply["position"] as Vector2).distance_to(true_pos)
		ok = ok and off <= AUDIBLE_POSITION_TOLERANCE
		detail += " %.1f px from true position" % off
	check(scenario, ok, detail)

func run_host() -> void:
	var viewer := player(client_peer())
	var me := player(1)
	var facing := Vector2.RIGHT.rotated(viewer.rotation)
	var open := find_open_spot(facing, 750.0)
	if open == Vector2.INF:
		results.fail("setup", "no open spot on the map")
		return
	viewer.global_position = open # server-authoritative: the client is corrected to it
	me.global_position = open + Vector2(0, 2000)
	await hold(1.0)
	facing = Vector2.RIGHT.rotated(viewer.rotation)
	var front := open + facing * 450.0
	var behind := open - facing * 550.0

	me.global_position = front
	await hold(1.2)
	_expect("in_view_is_visible", await _sample("front"), PlayerNetSync.NetPresence.VISIBLE, true)

	me.global_position = behind
	await hold(1.2)
	_expect("behind_and_silent_is_culled", await _sample("behind"), PlayerNetSync.NetPresence.CULLED, false)

	Input.action_press("move_left")
	await hold(0.7)
	_expect("behind_and_walking_is_audible", await _sample("walking"), PlayerNetSync.NetPresence.AUDIBLE, false, true, me.global_position)
	Input.action_release("move_left")
	await hold(0.3)

	# Switch to the pistol (shots carry 1200 px), go quiet, then shoot.
	await tap("secondary")
	var shoot_from := open - facing * 450.0
	me.global_position = shoot_from
	await hold(1.2)
	var quiet := await _sample("quiet")
	check("hidden_shooter_is_culled_before_shooting", not quiet.is_empty() and int(quiet["presence"]) == PlayerNetSync.NetPresence.CULLED, "presence=%s" % [PlayerNetSync.NetPresence.keys()[int(quiet.get("presence", 0))]])
	await tap("shoot", 0.25)
	await hold(0.8)
	_inbox.erase("result:shot")
	send("shot?")
	var shot: Variant = await wait_for("result:shot", 5.0)
	if not (shot is Dictionary) or (shot as Dictionary).is_empty():
		results.fail("hidden_shot_heard_from_true_position", "the client never simulated the shot")
	else:
		var off: float = (shot["position"] as Vector2).distance_to(shoot_from)
		check("hidden_shot_heard_from_true_position", int(shot["presence"]) != PlayerNetSync.NetPresence.CULLED and off < 1.0,
			"presence=%s, %.2f px from the shooter" % [PlayerNetSync.NetPresence.keys()[int(shot["presence"])], off])

	var wall_setup := _find_wall_setup(facing)
	if wall_setup.is_empty():
		results.fail("behind_wall_is_culled", "no wall setup found on the map")
	else:
		viewer.global_position = wall_setup[0]
		me.global_position = wall_setup[1]
		await hold(1.5)
		_expect("behind_wall_is_culled", await _sample("wall"), PlayerNetSync.NetPresence.CULLED, false)
		Input.action_press("move_up")
		await hold(0.6)
		_expect("walking_behind_wall_is_audible", await _sample("wall_walk"), PlayerNetSync.NetPresence.AUDIBLE, false, true)
		Input.action_release("move_up")
		viewer.global_position = open
		await hold(1.0)

	me.global_position = front
	var smoke := (load("res://scenes/utilities/smoke/smoke_cloud_mask.tscn") as PackedScene).instantiate() as SmokeCloud
	smoke.start_scale_multiplier = 1.0
	smoke.duration = 3.0
	smoke.global_position = (open + front) * 0.5
	get_tree().current_scene.add_child(smoke) # server only: tests the server's check
	await hold(1.2)
	_expect("smoke_between_is_culled", await _sample("smoke"), PlayerNetSync.NetPresence.CULLED, false)
	smoke.queue_free()
	await hold(1.2)
	_expect("back_in_view_is_visible", await _sample("back"), PlayerNetSync.NetPresence.VISIBLE, true)

## [viewer_pos, target_pos]: the viewer faces a building 220-400 px ahead and
## the target stands right behind it with all three sight rays blocked.
func _find_wall_setup(facing: Vector2) -> Array:
	var space := get_viewport().world_2d.direct_space_state
	for gx in range(-30, 31):
		for gy in range(-30, 31):
			var p := Vector2(gx * 80.0, gy * 80.0)
			if not spot_free(p):
				continue
			var hit := space.intersect_ray(PhysicsRayQueryParameters2D.create(p, p + facing * 500.0, 1))
			if hit.is_empty():
				continue
			var d := p.distance_to(hit.position)
			if d < 220.0 or d > 400.0:
				continue
			var t: Vector2 = hit.position + facing * 160.0
			var side := facing.orthogonal() * 40.0
			if spot_free(t) and not ray_clear(p, t) and not ray_clear(p, t + side) and not ray_clear(p, t - side):
				return [p, t]
	return []
