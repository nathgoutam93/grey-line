extends Node

## Base for two-process network tests (host + client on localhost).
##
## tests/run_tests.sh starts tests/net/net_test.tscn twice:
##   godot --headless --path . res://tests/net/net_test.tscn -- --ephemeral-profile --net-test=<name> --role=host|client --port=<n>
## The launcher adds the scenario script as /root/NetTest on both sides (so it
## survives the menu -> lobby -> map scene changes and both sides can RPC each
## other), this base hosts/joins and starts the match, then calls
## run_host() / run_client(). The client reports what it observed with send();
## the host checks it against the authoritative state and decides the result.
## Each process exits 0 when its checks passed.

const TestLog := preload("res://tests/test_log.gd")
const HARD_TIMEOUT_SECONDS := 90.0

var role := ""
var test_name := ""
var port := 3300
var results: TestLog
var ticks := 0

var _inbox := {}
var _finished := false

func _ready() -> void:
	name = "NetTest"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			role = arg.trim_prefix("--role=")
		elif arg.begins_with("--net-test="):
			test_name = arg.trim_prefix("--net-test=")
		elif arg.begins_with("--port="):
			port = int(arg.trim_prefix("--port="))
	results = TestLog.new("%s:%s" % [test_name, role])
	if PlayerProfile.persistence_enabled:
		# Never let a test rewrite the real profile.
		finish_with_failure("setup", "run with -- %s" % PlayerProfileStore.EPHEMERAL_ARG)
		return
	_hard_timeout()
	PlayerProfile.set_username("test_" + role)
	PlayerProfile.set_avatar_id(PlayerProfileStore.DEFAULT_AVATAR_ID)
	PlayerProfile.complete_profile_setup()
	MultiplayerSession.port = port
	MultiplayerSession.discovery_port = port + 1
	MultiplayerSession.enable_lan_discovery = false
	await get_tree().create_timer(0.3).timeout
	if role == "host":
		_start_host()
	else:
		_start_client()

func _physics_process(_delta: float) -> void:
	ticks += 1

func _start_host() -> void:
	MultiplayerSession.host_game()
	await multiplayer.peer_connected
	await get_tree().create_timer(1.5).timeout
	await run_host_lobby()
	MultiplayerSession.start_match()
	if not await wait_until(func(): return player(client_peer()) != null and player(1) != null, 15.0):
		finish_with_failure("setup", "players did not spawn on the host")
		return
	await get_tree().create_timer(1.0).timeout
	await run_host()
	if not _finished:
		send("done", results.failures == 0)
		await get_tree().create_timer(0.5).timeout
		_quit()

func _start_client() -> void:
	await get_tree().create_timer(0.5).timeout
	await MultiplayerSession.join_game("127.0.0.1")
	if not await wait_until(func(): return local_player() != null, 20.0):
		finish_with_failure("setup", "local player did not spawn on the client")
		return
	await get_tree().create_timer(1.0).timeout
	await run_client()
	# Stay connected until the host has checked everything we reported.
	await wait_for("done", 60.0)
	_quit()

## Override: host-side lobby checks before the map starts.
func run_host_lobby() -> void:
	pass

## Override: host-side scenario and checks.
func run_host() -> void:
	pass

## Override: client-side scenario; report observations with send().
func run_client() -> void:
	pass

## Override: react to a message from the other side.
func on_message(_key: String, _value: Variant) -> void:
	pass

# --- messaging --------------------------------------------------------------

## Sends `value` (never null: wait_for uses null for "timed out").
func send(key: String, value: Variant = true) -> void:
	if multiplayer.multiplayer_peer == null or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_deliver.rpc(key, value)

@rpc("any_peer", "call_remote", "reliable")
func _deliver(key: String, value: Variant) -> void:
	_inbox[key] = value
	on_message(key, value)

func wait_for(key: String, timeout: float) -> Variant:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not _inbox.has(key):
		if Time.get_ticks_msec() > deadline:
			return null
		await get_tree().process_frame
	return _inbox[key]

func wait_until(condition: Callable, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().process_frame
	return true

# --- checks -----------------------------------------------------------------

func check(test: String, condition: bool, detail: String) -> void:
	if condition:
		results.pass_test(test, detail)
	else:
		results.fail(test, detail)

func finish_with_failure(test: String, detail: String) -> void:
	results.fail(test, detail)
	send("done", false)
	_quit()

func _quit() -> void:
	if _finished:
		return
	_finished = true
	get_tree().quit(results.finish())

func _hard_timeout() -> void:
	await get_tree().create_timer(HARD_TIMEOUT_SECONDS).timeout
	if not _finished:
		finish_with_failure("timeout", "did not finish within %d s" % int(HARD_TIMEOUT_SECONDS))

# --- helpers ----------------------------------------------------------------

func hold(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

## Optional real-renderer captures when running a scenario without --headless.
func capture_frame(label: String) -> void:
	var output_dir := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			output_dir = arg.trim_prefix("--capture-dir=")
	if output_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(output_dir)
	await RenderingServer.frame_post_draw
	var path := output_dir.path_join("%s-%s-%s.png" % [test_name, role, label])
	var error := get_viewport().get_texture().get_image().save_png(path)
	if error != OK:
		results.fail("capture", "could not save %s: %s" % [path, error_string(error)])

func tap(action: String, seconds: float = 0.1) -> void:
	Input.action_press(action)
	await hold(seconds)
	Input.action_release(action)

func client_peer() -> int:
	for id in multiplayer.get_peers():
		return id
	return -1

## Host only: add a puppet during a match and wait for its player setup.
## Returns 0 and records a failure if registration or spawning fails.
func add_bot() -> int:
	var bot_id := MultiplayerSession.add_bot()
	if bot_id >= 0 or not await wait_until(func(): return player(bot_id) != null and bot(bot_id) != null, 8.0):
		results.fail("add_bot", "bot registration or spawn failed (id %d)" % bot_id)
		return 0
	return bot_id

func bot(bot_id: int) -> BotBrain:
	var puppet := player(bot_id)
	return puppet.net_sync.bot_brain if puppet != null else null

## Live player whose node is named after `owner_id`.
func player(owner_id: int) -> PlayerController:
	for node in get_tree().get_nodes_in_group("Player"):
		var p := node as PlayerController
		if p != null and is_instance_valid(p) and not p.is_dead and String(p.name) == str(owner_id):
			return p
	return null

func local_player() -> PlayerController:
	for node in get_tree().get_nodes_in_group("Player"):
		var p := node as PlayerController
		if p != null and is_instance_valid(p) and p.is_local_player and not p.is_dead:
			return p
	return null

func game_mode() -> Node:
	return get_tree().get_first_node_in_group("game_mode")

func ray_clear(from: Vector2, to: Vector2, exclude: Array[RID] = []) -> bool:
	var query := PhysicsRayQueryParameters2D.create(from, to, 1, exclude)
	return get_viewport().world_2d.direct_space_state.intersect_ray(query).is_empty()

func spot_free(p: Vector2, radius: float = 40.0) -> bool:
	var query := PhysicsShapeQueryParameters2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	query.shape = circle
	query.transform = Transform2D(0.0, p)
	query.collision_mask = 1
	return get_viewport().world_2d.direct_space_state.intersect_shape(query, 1).is_empty()

## Host only: an open spot on the map with `clearance` px of clear line both
## along `facing` and against it (and a little sideways).
func find_open_spot(facing: Vector2, clearance: float) -> Vector2:
	for gx in range(-30, 31):
		for gy in range(-30, 31):
			var p := Vector2(gx * 80.0, gy * 80.0)
			if spot_free(p) and ray_clear(p, p + facing * clearance) and ray_clear(p, p - facing * clearance) and ray_clear(p, p + facing.orthogonal() * 120.0):
				return p
	return Vector2.INF

## [viewer_pos, target_pos]: the viewer faces a building 220-400 px ahead and
## the target stands right behind it with all three sight rays blocked.
func find_wall_setup(facing: Vector2) -> Array:
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
