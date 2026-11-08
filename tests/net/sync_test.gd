extends "res://tests/net/net_test_base.gd"

## Input clock, movement prediction and snapshots: the client walks a fixed
## pattern for 10 s, then stands still. Checks: its final position matches the
## server, it needed (almost) no corrections after warm-up, the input lead
## settled on target, (nearly) every snapshot packet the server sent arrived,
## and the server rarely ran out of client input.

const PHASES := ["move_up", "move_right", "", "move_left", "move_down", ""]
const WARMUP_TICKS := 120
const MOVE_TICKS := 600
const MAX_CORRECTIONS := 2
# Share of the server's snapshot packets that must arrive (localhost: ~all).
const MIN_SNAPSHOT_DELIVERY := 0.95

# client
var _pos_after_sim := Vector2.INF
var _corrections := 0
var _correction_px := 0.0
var _snapshots_at_warmup := -1
var _sent_at_mark := -1 # host: packets sent to the client when it marked warm-up
var _player_ticks := 0

# host
var _missing_input_ticks := 0
var _prev_applied_tick := -1
var _host_ticks := 0

func _ready() -> void:
	# Before any player exists, so this runs first in each tick (before the
	# client's own prediction): a position change since the end of the last
	# physics frame is a correction applied in between.
	NetworkTick.tick_started.connect(_on_tick_first)
	super._ready()

func _on_tick_first(_tick: int) -> void:
	if role != "client":
		return
	var me := local_player()
	if me == null:
		return
	_player_ticks += 1
	if _player_ticks > WARMUP_TICKS and _pos_after_sim != Vector2.INF:
		var jump := me.global_position.distance_to(_pos_after_sim)
		if jump > 0.5:
			_corrections += 1
			_correction_px += jump
	for action in ["move_up", "move_down", "move_left", "move_right"]:
		Input.action_release(action)
	if _player_ticks <= MOVE_TICKS:
		var action: String = PHASES[int(_player_ticks / 60) % PHASES.size()]
		if action != "":
			Input.action_press(action)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if role == "client":
		var me := local_player()
		if me != null:
			_pos_after_sim = me.global_position
			# Count every accepted snapshot (NetSync counter) against what the
			# server actually sent (it sends at most once per physics frame, so
			# fewer than one per interval when busy). Robust to bunching/stalls.
			if _player_ticks > WARMUP_TICKS and _snapshots_at_warmup < 0:
				_snapshots_at_warmup = me.net_sync.snapshots_received
				send("mark")
	elif role == "host":
		var remote := player(client_peer())
		if remote != null:
			_host_ticks += 1
			if _host_ticks > WARMUP_TICKS and remote.net_sync._last_applied_input_tick == _prev_applied_tick:
				_missing_input_ticks += 1
			_prev_applied_tick = remote.net_sync._last_applied_input_tick

func on_message(key: String, _value: Variant) -> void:
	if role == "host" and key == "mark":
		_sent_at_mark = int(WorldSnapshots.packets_sent.get(client_peer(), 0))

func run_client() -> void:
	await wait_until(func(): return _player_ticks > MOVE_TICKS + 120, 30.0)
	var me := local_player()
	send("report", {
		"snapshots_received": me.net_sync.snapshots_received - _snapshots_at_warmup,
		"position": me.global_position,
		"corrections": _corrections,
		"correction_px": _correction_px,
		"input_lead_offset": me.net_sync._input_tick_offset - me.net_sync._tick_offset,
	})

func run_host() -> void:
	var report: Variant = await wait_for("report", 40.0)
	if report == null:
		results.fail("client_report", "no report from the client")
		return
	var remote := player(client_peer())
	var distance: float = remote.global_position.distance_to(report["position"])
	check("final_position_matches_server", distance < 0.5, "client vs server %.3f px" % distance)
	check("no_corrections_after_warmup", int(report["corrections"]) <= MAX_CORRECTIONS,
		"%d corrections (%.1f px total)" % [int(report["corrections"]), float(report["correction_px"])])
	var lead := remote.net_sync._lead_sample_value
	check("input_lead_on_target", lead >= 1 and lead <= 4, "server-measured lead %d ticks (target %d)" % [lead, PlayerNetSync.TARGET_INPUT_LEAD_TICKS])
	var received := int(report["snapshots_received"])
	# Packets sent over the same window (+/- a couple in flight on each end).
	var sent := int(WorldSnapshots.packets_sent.get(client_peer(), 0)) - _sent_at_mark
	check("snapshots_delivered", _sent_at_mark >= 0 and sent > 0 and float(received) >= float(sent) * MIN_SNAPSHOT_DELIVERY and received <= sent + 2,
		"client received %d of %d packets sent" % [received, sent])
	check("server_rarely_missing_input", _missing_input_ticks <= 5, "%d ticks without fresh client input after warm-up" % _missing_input_ticks)
