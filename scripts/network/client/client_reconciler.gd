extends RefCounted
class_name ClientReconciler

const POSITION_DEADZONE := 6.0

func reconcile(player: PlayerController, authoritative_position: Vector2, authoritative_velocity: Vector2, ack_tick: int, input_buffer: Dictionary, movement_component: MovementCompoent) -> void:
	if player == null or movement_component == null:
		return

	var replay_ticks := input_buffer.keys()
	replay_ticks.sort()
	var pending_frames: Array[PlayerInputFrame] = []
	for t in replay_ticks:
		var tick := int(t)
		if tick <= ack_tick:
			input_buffer.erase(tick)
			continue
		var frame := input_buffer[tick] as PlayerInputFrame
		if frame != null:
			pending_frames.append(frame)

	var error := authoritative_position - player.global_position
	if error.length() <= POSITION_DEADZONE:
		return

	player.global_position = authoritative_position
	player.velocity = authoritative_velocity
	for frame in pending_frames:
		movement_component.simulate(frame)
