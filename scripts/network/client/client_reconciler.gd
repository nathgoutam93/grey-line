extends RefCounted
class_name ClientReconciler

const POSITION_DEADZONE := 2.0

## Compares the server's authoritative state for `ack_tick` against what this
## client predicted for that same tick. Only on a mismatch do we snap to the
## server position and replay the not-yet-acknowledged inputs.
func reconcile(player: PlayerController, authoritative_position: Vector2, authoritative_velocity: Vector2, ack_tick: int, input_buffer: Dictionary, predicted_positions: Dictionary, movement_component: MovementCompoent) -> void:
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

	# Keep the prediction for ack_tick itself: the server may re-send the same
	# ack (when it had to repeat an input) and we still need to compare to it.
	var predicted: Variant = predicted_positions.get(ack_tick, null)
	for t in predicted_positions.keys():
		if int(t) < ack_tick:
			predicted_positions.erase(t)

	# Keep velocity authoritative even when positional error is tiny.
	# This prevents subtle divergence after impulses/knockback.
	player.velocity = authoritative_velocity

	if predicted != null:
		if (authoritative_position - (predicted as Vector2)).length() <= POSITION_DEADZONE:
			return
	elif pending_frames.is_empty() and (authoritative_position - player.global_position).length() <= POSITION_DEADZONE:
		return

	player.global_position = authoritative_position
	predicted_positions[ack_tick] = authoritative_position
	for frame in pending_frames:
		# Speed depends on slow-walk state, so replay it per frame.
		player.is_slow_walking = frame.slow_walk_held
		movement_component.simulate(frame)
		predicted_positions[frame.tick] = player.global_position
