extends Resource
class_name PlayerInputFrame

const FLAG_FIRE_PRESSED := 1 << 0
const FLAG_FIRE_HELD := 1 << 1
const FLAG_RELOAD := 1 << 2
const FLAG_SWITCH_NEXT := 1 << 3
const FLAG_SWITCH_PREV := 1 << 4
const FLAG_DROP := 1 << 5
const FLAG_INTERACT := 1 << 6
const FLAG_SLOW_WALK := 1 << 7
const PACKED_SIZE := 7

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
## Server tick the client was rendering remote players at when this input was
## sampled. Used for lag compensation. -1 means "use the current server tick".
@export var view_tick: int = -1

## Client-local only (never sent): tick offset used to stamp this frame.
var stamp_offset: float = 0.0

func has_one_shot_actions() -> bool:
	return reload_pressed or switch_next_pressed or switch_prev_pressed \
		or drop_pressed or interact_pressed or fire_pressed or slot_select >= 0

## Folds one-shot actions from an earlier frame into this one so they are not
## lost when frames are coalesced. Continuous state (move/aim/held) is kept.
func merge_actions_from(earlier: PlayerInputFrame) -> void:
	if earlier == null:
		return
	fire_pressed = fire_pressed or earlier.fire_pressed
	reload_pressed = reload_pressed or earlier.reload_pressed
	switch_next_pressed = switch_next_pressed or earlier.switch_next_pressed
	switch_prev_pressed = switch_prev_pressed or earlier.switch_prev_pressed
	drop_pressed = drop_pressed or earlier.drop_pressed
	interact_pressed = interact_pressed or earlier.interact_pressed
	if slot_select < 0:
		slot_select = earlier.slot_select

## Copy that repeats continuous input (movement, aim, held buttons) without
## any one-shot actions. Used when the server has to predict a missing frame
## or the client fills skipped ticks.
func copy_continuous(new_tick: int) -> PlayerInputFrame:
	var frame := PlayerInputFrame.new()
	frame.tick = new_tick
	frame.move = move
	frame.aim_dir = aim_dir
	frame.fire_held = fire_held
	frame.slow_walk_held = slow_walk_held
	frame.shot_intent = shot_intent
	frame.view_tick = view_tick
	frame.stamp_offset = stamp_offset
	return frame

func _flags() -> int:
	var flags := 0
	if fire_pressed: flags |= FLAG_FIRE_PRESSED
	if fire_held: flags |= FLAG_FIRE_HELD
	if reload_pressed: flags |= FLAG_RELOAD
	if switch_next_pressed: flags |= FLAG_SWITCH_NEXT
	if switch_prev_pressed: flags |= FLAG_SWITCH_PREV
	if drop_pressed: flags |= FLAG_DROP
	if interact_pressed: flags |= FLAG_INTERACT
	if slow_walk_held: flags |= FLAG_SLOW_WALK
	return flags

## Compact wire format: [tick, move, aim_dir, flags, slot_select, shot_intent, view_tick]
func to_packed() -> Array:
	return [tick, move, aim_dir, _flags(), slot_select, shot_intent, view_tick]

## Parses data received from a remote peer. Returns null for malformed input.
static func from_packed(data: Variant) -> PlayerInputFrame:
	if not (data is Array):
		return null
	var arr: Array = data
	if arr.size() != PACKED_SIZE:
		return null
	if typeof(arr[0]) != TYPE_INT or typeof(arr[1]) != TYPE_VECTOR2 or typeof(arr[2]) != TYPE_VECTOR2:
		return null
	if typeof(arr[3]) != TYPE_INT or typeof(arr[4]) != TYPE_INT or typeof(arr[5]) != TYPE_INT or typeof(arr[6]) != TYPE_INT:
		return null
	var frame := PlayerInputFrame.new()
	frame.tick = arr[0]
	var move_value: Vector2 = arr[1]
	frame.move = move_value.limit_length(1.0) if move_value.is_finite() else Vector2.ZERO
	var aim_value: Vector2 = arr[2]
	if aim_value.is_finite() and aim_value.length_squared() > 0.0001:
		frame.aim_dir = aim_value.normalized()
	var flags: int = arr[3]
	frame.fire_pressed = (flags & FLAG_FIRE_PRESSED) != 0
	frame.fire_held = (flags & FLAG_FIRE_HELD) != 0
	frame.reload_pressed = (flags & FLAG_RELOAD) != 0
	frame.switch_next_pressed = (flags & FLAG_SWITCH_NEXT) != 0
	frame.switch_prev_pressed = (flags & FLAG_SWITCH_PREV) != 0
	frame.drop_pressed = (flags & FLAG_DROP) != 0
	frame.interact_pressed = (flags & FLAG_INTERACT) != 0
	frame.slow_walk_held = (flags & FLAG_SLOW_WALK) != 0
	frame.slot_select = arr[4]
	frame.shot_intent = arr[5]
	frame.view_tick = arr[6]
	return frame

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
		"shot_intent": shot_intent,
		"view_tick": view_tick
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
	frame.view_tick = int(data.get("view_tick", -1))
	return frame
