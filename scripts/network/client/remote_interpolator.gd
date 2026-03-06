extends RefCounted
class_name RemoteInterpolator

var snapshot_buffer: Array = []
var interpolation_delay_ticks := 2
var max_buffer_size := 32

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

func apply_latest(player: PlayerController) -> void:
	if snapshot_buffer.is_empty():
		return
	var latest: Dictionary = snapshot_buffer[snapshot_buffer.size() - 1]
	player.global_position = latest.get("position", player.global_position)
	player.rotation = float(latest.get("rotation", player.rotation))

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
