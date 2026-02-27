extends Resource
class_name PlayerInputFrame

@export var tick: int = 0
@export var move: Vector2 = Vector2.ZERO
@export var aim_dir: Vector2 = Vector2.RIGHT
@export var fire_pressed: bool = false
@export var fire_held: bool = false
@export var reload_pressed: bool = false
@export var switch_next_pressed: bool = false
@export var switch_prev_pressed: bool = false
@export var slot_select: int = -1
@export var drop_pressed: bool = false
@export var interact_pressed: bool = false
@export var slow_walk_held: bool = false
@export var shot_intent: int = 0

func to_dict() -> Dictionary:
	return {
		"tick": tick,
		"move": move,
		"aim_dir": aim_dir,
		"fire_pressed": fire_pressed,
		"fire_held": fire_held,
		"reload_pressed": reload_pressed,
		"switch_next_pressed": switch_next_pressed,
		"switch_prev_pressed": switch_prev_pressed,
		"slot_select": slot_select,
		"drop_pressed": drop_pressed,
		"interact_pressed": interact_pressed,
		"slow_walk_held": slow_walk_held,
		"shot_intent": shot_intent
	}

static func from_dict(data: Dictionary) -> PlayerInputFrame:
	var frame := PlayerInputFrame.new()
	frame.tick = int(data.get("tick", 0))
	frame.move = data.get("move", Vector2.ZERO)
	frame.aim_dir = data.get("aim_dir", Vector2.RIGHT)
	frame.fire_pressed = bool(data.get("fire_pressed", false))
	frame.fire_held = bool(data.get("fire_held", false))
	frame.reload_pressed = bool(data.get("reload_pressed", false))
	frame.switch_next_pressed = bool(data.get("switch_next_pressed", false))
	frame.switch_prev_pressed = bool(data.get("switch_prev_pressed", false))
	frame.slot_select = int(data.get("slot_select", -1))
	frame.drop_pressed = bool(data.get("drop_pressed", false))
	frame.interact_pressed = bool(data.get("interact_pressed", false))
	frame.slow_walk_held = bool(data.get("slow_walk_held", false))
	frame.shot_intent = int(data.get("shot_intent", 0))
	return frame
