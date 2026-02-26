extends Control
class_name TouchAimZone

signal drag_started(pointer_id: int)
signal drag_ended(pointer_id: int)

@export var drag_deadzone_pixels := 18.0
@export var max_drag_pixels := 320.0
@export var debug_draw_enabled := true
@export var debug_draw_in_game := false
@export var debug_fill_color := Color(0.1, 0.7, 1.0, 0.14)
@export var debug_border_color := Color(0.1, 0.7, 1.0, 0.55)

var _pointer_id := -1
var _start_screen_pos := Vector2.ZERO
var _current_screen_pos := Vector2.ZERO

func _ready() -> void:
	set_process_input(true)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
		return

	if event is InputEventScreenDrag:
		_handle_screen_drag(event as InputEventScreenDrag)

func _draw() -> void:
	if not debug_draw_enabled:
		return
	if not Engine.is_editor_hint() and not debug_draw_in_game:
		return

	draw_rect(Rect2(Vector2.ZERO, size), debug_fill_color, true)
	draw_rect(Rect2(Vector2.ZERO, size), debug_border_color, false, 2.0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

func _handle_screen_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _pointer_id != -1:
			return
		if not _contains_screen_point(event.position):
			return

		_pointer_id = event.index
		_start_screen_pos = event.position
		_current_screen_pos = event.position
		drag_started.emit(_pointer_id)
		return

	if event.index == _pointer_id:
		var ended_pointer := _pointer_id
		_pointer_id = -1
		_start_screen_pos = Vector2.ZERO
		_current_screen_pos = Vector2.ZERO
		drag_ended.emit(ended_pointer)

func _handle_screen_drag(event: InputEventScreenDrag) -> void:
	if event.index != _pointer_id:
		return
	_current_screen_pos = event.position

func _contains_screen_point(screen_pos: Vector2) -> bool:
	return get_global_rect().has_point(screen_pos)

func reset_drag() -> void:
	_pointer_id = -1
	_start_screen_pos = Vector2.ZERO
	_current_screen_pos = Vector2.ZERO

func is_drag_active() -> bool:
	return _pointer_id != -1

func get_aim_input_vector() -> Vector2:
	if _pointer_id == -1:
		return Vector2.ZERO

	var drag_x := _current_screen_pos.x - _start_screen_pos.x
	if abs(drag_x) < drag_deadzone_pixels:
		return Vector2.ZERO

	var processed_drag_x : float = drag_x - (sign(drag_x) * drag_deadzone_pixels)
	if max_drag_pixels > 0.0:
		processed_drag_x = clamp(processed_drag_x, -max_drag_pixels, max_drag_pixels)

	return Vector2(processed_drag_x, 0.0)
