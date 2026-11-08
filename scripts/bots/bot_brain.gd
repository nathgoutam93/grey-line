extends RefCounted
class_name BotBrain

## Scripted puppet input for a server-side player. Tests and debug tools
## set these fields; each frame goes through the normal server simulation.
var move := Vector2.ZERO
var aim_dir := Vector2.RIGHT
var fire_held := false
var slow_walk_held := false
var slot_select := -1
var reload := false

var _was_fire_held := false

func build_input_frame(tick: int) -> PlayerInputFrame:
	var frame := PlayerInputFrame.new()
	frame.tick = tick
	frame.view_tick = tick
	frame.move = move.limit_length(1.0)
	frame.aim_dir = aim_dir.normalized() if not aim_dir.is_zero_approx() else Vector2.RIGHT
	frame.fire_held = fire_held
	frame.fire_pressed = fire_held and not _was_fire_held
	frame.slow_walk_held = slow_walk_held
	frame.slot_select = slot_select
	frame.reload_pressed = reload
	_was_fire_held = fire_held
	slot_select = -1
	reload = false
	return frame

func face_point(from: Vector2, target: Vector2) -> void:
	aim_dir = target - from

func stop() -> void:
	move = Vector2.ZERO
	fire_held = false
