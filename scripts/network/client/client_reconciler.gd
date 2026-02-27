extends RefCounted
class_name ClientReconciler

func reconcile(player: PlayerController, authoritative_position: Vector2, ack_tick: int, input_buffer: Dictionary, movement_component: MovementCompoent) -> void:
	var error := authoritative_position - player.global_position
	if error.length() > 24.0:
		player.global_position = authoritative_position
	else:
		player.global_position += error * 0.25

	var replay_ticks := input_buffer.keys()
	replay_ticks.sort()
	for t in replay_ticks:
		var tick := int(t)
		if tick <= ack_tick:
			input_buffer.erase(tick)
			continue
		var frame := input_buffer[tick] as PlayerInputFrame
		if frame != null:
			movement_component.simulate(frame)
