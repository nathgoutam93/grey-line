extends Node
class_name PlayerInputCollector

enum InputMode {
	MOUSE_KEYBOARD,
	TOUCH
}

@export var input_mode: InputMode = InputMode.MOUSE_KEYBOARD:
	set(value):
		input_mode = value
		_apply_input_mode()

@export var touch_aim_distance := 1200.0
@export var touch_crosshair_radius := 180.0
@export var player: PlayerController

var input_vector := Vector2.ZERO
var mouse_pos := Vector2.ZERO

var _aim_screen_pos := Vector2.ZERO
var _aim_initialized := false
var _touch_aim_dir := Vector2.RIGHT
var _look_angle := 0.0
var _was_local_player := false
var _touch_look_start_angle := 0.0
var _pending_reload_ticks := 0
var _pending_switch_prev_ticks := 0
var _pending_switch_next_ticks := 0
var _pending_drop_ticks := 0
var _pending_interact_ticks := 0
var _pending_slot_select_ticks := 0
var _pending_slot_select_value := -1
const EDGE_HOLD_TICKS := 3

func get_aim_world_position() -> Vector2:
	return mouse_pos

func get_aim_screen_position() -> Vector2:
	return _aim_screen_pos

func set_authority(peer_id: int) -> void:
	if peer_id == multiplayer.get_unique_id():
		set_process(true)
		set_process_input(true)
	else:
		set_process(false)
		set_process_input(false)

func _ready() -> void:
	set_process(false)
	set_process_input(false)
	_apply_input_mode()

func _exit_tree() -> void:
	if _was_local_player or _can_control_mouse_capture():
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _process(delta: float) -> void:
	_update_aim(delta)
	if _is_touch_mode():
		_process_touch_input()
	else:
		_process_mouse_keyboard_input()

func build_input_frame(tick: int) -> PlayerInputFrame:
	var frame := PlayerInputFrame.new()
	frame.tick = tick
	frame.move = input_vector
	var aim_dir := mouse_pos - player.global_position
	if aim_dir.length_squared() > 0.0001:
		frame.aim_dir = aim_dir.normalized()
	var touch_mode := _is_touch_mode()
	var shoot_pressed := _is_touch_button_pressed("Shoot") if touch_mode else Input.is_action_just_pressed("shoot")
	var shoot_held := (_is_touch_button_pressed("Shoot") or _is_touch_button_pressed("Headshot")) if touch_mode else Input.is_action_pressed("shoot")
	var headshot_requested := _is_touch_button_pressed("Headshot") if touch_mode else Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	frame.fire_pressed = shoot_pressed
	frame.fire_held = shoot_held
	frame.shot_intent = PlayerController.ShotIntent.HEAD if headshot_requested else PlayerController.ShotIntent.BODY
	if (touch_mode and _just_pressed_touch("Reload")) or (not touch_mode and Input.is_action_just_pressed("reload")):
		_pending_reload_ticks = EDGE_HOLD_TICKS
	if (touch_mode and _just_pressed_touch("Swap")) or (not touch_mode and Input.is_action_just_pressed("scroll_up")):
		_pending_switch_prev_ticks = EDGE_HOLD_TICKS
	if not touch_mode and Input.is_action_just_pressed("scroll_down"):
		_pending_switch_next_ticks = EDGE_HOLD_TICKS
	if not touch_mode and Input.is_action_just_pressed("drop_weapon"):
		_pending_drop_ticks = EDGE_HOLD_TICKS
	if not touch_mode and Input.is_action_just_pressed("pickup"):
		_pending_interact_ticks = EDGE_HOLD_TICKS

	if not touch_mode and Input.is_action_just_pressed("primary"):
		_pending_slot_select_ticks = EDGE_HOLD_TICKS
		_pending_slot_select_value = EquipmentManager.EquipmentSlot.PRIMARY
	elif not touch_mode and Input.is_action_just_pressed("secondary"):
		_pending_slot_select_ticks = EDGE_HOLD_TICKS
		_pending_slot_select_value = EquipmentManager.EquipmentSlot.SECONDARY
	elif not touch_mode and Input.is_action_just_pressed("malee"):
		_pending_slot_select_ticks = EDGE_HOLD_TICKS
		_pending_slot_select_value = EquipmentManager.EquipmentSlot.MELEE

	# Reload should be an edge trigger to avoid repeated reload RPCs per press.
	frame.reload_pressed = _pending_reload_ticks == EDGE_HOLD_TICKS
	# Weapon swap must be edge-triggered; holding it for multiple ticks can
	# cycle through slots and land back on the original weapon.
	frame.switch_prev_pressed = _pending_switch_prev_ticks == EDGE_HOLD_TICKS
	frame.switch_next_pressed = _pending_switch_next_ticks == EDGE_HOLD_TICKS
	# Drop should be a single-shot action per press; holding this edge for
	# multiple ticks can drop multiple weapons in sequence.
	frame.drop_pressed = _pending_drop_ticks == EDGE_HOLD_TICKS
	# Interact and slot-select are single-shot actions.
	frame.interact_pressed = _pending_interact_ticks == EDGE_HOLD_TICKS
	if _pending_slot_select_ticks == EDGE_HOLD_TICKS:
		frame.slot_select = _pending_slot_select_value

	_pending_reload_ticks = maxi(_pending_reload_ticks - 1, 0)
	_pending_switch_prev_ticks = maxi(_pending_switch_prev_ticks - 1, 0)
	_pending_switch_next_ticks = maxi(_pending_switch_next_ticks - 1, 0)
	_pending_drop_ticks = maxi(_pending_drop_ticks - 1, 0)
	_pending_interact_ticks = maxi(_pending_interact_ticks - 1, 0)
	_pending_slot_select_ticks = maxi(_pending_slot_select_ticks - 1, 0)
	if _pending_slot_select_ticks == 0:
		_pending_slot_select_value = -1

	frame.slow_walk_held = false if touch_mode else Input.is_action_pressed("slow_walk")
	return frame

func _resolve_touch_aim_zone() -> TouchAimZone:
	if not is_instance_valid(player) or not is_instance_valid(player.hud):
		return null
	if player.hud.has_method("get_touch_aim_zone"):
		return player.hud.get_touch_aim_zone()
	var node := player.hud.get_node_or_null("Controls/TouchAimZone")
	if node is TouchAimZone:
		return node
	return null

func _resolve_move_joystick() -> VirtualJoystick:
	if not is_instance_valid(player) or not is_instance_valid(player.hud):
		return null
	var node := player.hud.get_node_or_null("Controls/MovementJoystick")
	if node is VirtualJoystick:
		return node
	return null

func _resolve_touch_button(node_name: String) -> TouchScreenButton:
	if not is_instance_valid(player) or not is_instance_valid(player.hud):
		return null
	var node := player.hud.get_node_or_null("Controls/%s" % node_name)
	if node is TouchScreenButton:
		return node
	return null

func _is_touch_mode() -> bool:
	return input_mode == InputMode.TOUCH

func _apply_input_mode() -> void:
	_aim_initialized = false
	_touch_aim_dir = Vector2.RIGHT
	_touch_look_start_angle = 0.0
	if is_instance_valid(player):
		_look_angle = player.global_rotation
	if _is_touch_mode():
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_set_touch_controls_visible(_is_touch_mode())
	var move_joystick := _resolve_move_joystick()
	if move_joystick != null:
		move_joystick.use_input_actions = false
	var touch_aim_zone := _resolve_touch_aim_zone()
	if touch_aim_zone != null:
		touch_aim_zone.reset_drag()

func _process_touch_input() -> void:
	var move_joystick := _resolve_move_joystick()
	if move_joystick != null and move_joystick.is_pressed:
		input_vector = move_joystick.output
	else:
		input_vector = Vector2.ZERO

func _process_mouse_keyboard_input() -> void:
	input_vector = Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
	).normalized()

func _input(event: InputEvent) -> void:
	if _is_touch_mode():
		return
	if not _can_control_mouse_capture():
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_ESCAPE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			return
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			if is_instance_valid(player):
				_look_angle += event.relative.x * player.mouse_turn_sensitivity

func on_local_player_spawned() -> void:
	_was_local_player = true
	if _can_control_mouse_capture() and not _is_touch_mode():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _can_control_mouse_capture() -> bool:
	if not is_instance_valid(player):
		return false
	return player.is_local_player

func _set_touch_controls_visible(is_visible: bool) -> void:
	if not is_instance_valid(player) or not is_instance_valid(player.hud):
		return
	var touch_nodes := ["MovementJoystick", "Shoot", "Reload", "Headshot", "Swap", "TouchAimZone"]
	for node_name in touch_nodes:
		var node := player.hud.get_node_or_null("Controls/%s" % node_name)
		if node is CanvasItem:
			node.visible = is_visible

func _update_aim(_delta: float) -> void:
	if not is_instance_valid(player):
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var screen_size := viewport.get_visible_rect().size
	var screen_half := screen_size * 0.5
	if not _aim_initialized:
		_aim_initialized = true
		_aim_screen_pos = screen_half
		mouse_pos = player.get_global_mouse_position()
		_look_angle = player.global_rotation
	if _is_touch_mode():
		_update_touch_look_from_zone()
		mouse_pos = player.global_position + (_touch_aim_dir * touch_aim_distance)
		_aim_screen_pos = screen_half + (_touch_aim_dir * touch_crosshair_radius)
		return
	_aim_screen_pos = screen_half
	var look_dir := Vector2.RIGHT.rotated(_look_angle)
	mouse_pos = player.global_position + (look_dir * touch_aim_distance)

func _update_touch_look_from_zone() -> void:
	var touch_aim_zone := _resolve_touch_aim_zone()
	if touch_aim_zone == null:
		return
	if not touch_aim_zone.is_drag_active():
		_touch_look_start_angle = _look_angle
		return
	var aim_input := touch_aim_zone.get_aim_input_vector()
	if aim_input == Vector2.ZERO:
		return
	if is_instance_valid(player):
		_look_angle = _touch_look_start_angle + (aim_input.x * player.mouse_turn_sensitivity)
	else:
		_look_angle = _touch_look_start_angle + (aim_input.x * 0.01)
	_touch_aim_dir = Vector2.RIGHT.rotated(_look_angle)

func _is_touch_button_pressed(node_name: String) -> bool:
	var button := _resolve_touch_button(node_name)
	return button != null and button.is_pressed()

func _just_pressed_touch(node_name: String) -> bool:
	var button := _resolve_touch_button(node_name)
	if button == null:
		return false
	var key := "_prev_%s" % node_name
	var was_pressed := bool(get_meta(key, false))
	var is_pressed := button.is_pressed()
	set_meta(key, is_pressed)
	return is_pressed and not was_pressed
