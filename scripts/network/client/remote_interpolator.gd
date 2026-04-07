extends RefCounted
class_name RemoteInterpolator

var snapshot_buffer: Array = []
var interpolation_delay_ticks := 2
var max_buffer_size := 32
const MAX_EXTRAPOLATION_TICKS := 2
const FALLBACK_POSITION_SMOOTHING := 0.55
const FALLBACK_ROTATION_SMOOTHING := 0.6

func push_snapshot(snapshot: Dictionary) -> void:
	var snapshot_tick := int(snapshot.get("tick", 0))
	if snapshot_tick <= 0:
		return

	for i in range(snapshot_buffer.size() - 1, -1, -1):
		var existing: Dictionary = snapshot_buffer[i]
		var existing_tick := int(existing.get("tick", 0))
		if existing_tick == snapshot_tick:
			snapshot_buffer[i] = snapshot
			return
		if existing_tick < snapshot_tick:
			snapshot_buffer.insert(i + 1, snapshot)
			while snapshot_buffer.size() > max_buffer_size:
				snapshot_buffer.pop_front()
			return

	snapshot_buffer.insert(0, snapshot)
	while snapshot_buffer.size() > max_buffer_size:
		snapshot_buffer.pop_front()

func apply_latest(player: PlayerController, render_tick: int = -1) -> void:
	if snapshot_buffer.is_empty():
		return
	var latest: Dictionary = snapshot_buffer[snapshot_buffer.size() - 1]
	var latest_tick := int(latest.get("tick", 0))
	var latest_pos: Vector2 = latest.get("position", player.global_position)
	var latest_rot := float(latest.get("rotation", player.rotation))
	var target_pos := latest_pos
	if render_tick >= 0 and latest_tick > 0:
		var extra_ticks := clampi(render_tick - latest_tick, 0, MAX_EXTRAPOLATION_TICKS)
		if extra_ticks > 0:
			var latest_vel: Vector2 = latest.get("velocity", Vector2.ZERO)
			target_pos += latest_vel * (float(extra_ticks) / float(NetworkTick.tick_rate))
	player.global_position = player.global_position.lerp(target_pos, FALLBACK_POSITION_SMOOTHING)
	player.rotation = lerp_angle(player.rotation, latest_rot, FALLBACK_ROTATION_SMOOTHING)

func interpolate(player: PlayerController, render_tick: int) -> void:
	if snapshot_buffer.size() < 2:
		return

	while snapshot_buffer.size() >= 2 and int(snapshot_buffer[1].get("tick", 0)) <= render_tick:
		snapshot_buffer.pop_front()

	if snapshot_buffer.size() < 2:
		return

	var from : Dictionary = snapshot_buffer[0]
	var to : Dictionary = snapshot_buffer[1]
	var from_tick := int(from.get("tick", 0))
	var to_tick := int(to.get("tick", 0))
	if to_tick <= from_tick:
		return

	var t := float(render_tick - from_tick) / float(to_tick - from_tick)
	var from_pos: Vector2 = from.get("position", player.global_position)
	var to_pos: Vector2 = to.get("position", player.global_position)
	var from_rot := float(from.get("rotation", player.rotation))
	var to_rot := float(to.get("rotation", player.rotation))
	player.global_position = from_pos.lerp(to_pos, clampf(t, 0.0, 1.0))
	player.rotation = lerp_angle(from_rot, to_rot, clampf(t, 0.0, 1.0))
