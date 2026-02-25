extends MultiplayerSynchronizer
class_name PlayerInput

enum InputMode {
	MOUSE_KEYBOARD,
	TOUCH
}

@export var input_vector := Vector2()
@export var mouse_pos := Vector2()
@export var touch_aim_distance := 1200.0
@export_range(0.0, 1.0) var touch_aim_deadzone := 0.2
@export var touch_crosshair_radius := 180.0
@export_range(0.0, 1.0) var touch_look_zone_start_x := 0.5
@export var touch_look_drag_deadzone_pixels := 18.0
@export var input_mode: InputMode = InputMode.MOUSE_KEYBOARD:
	set(value):
		input_mode = value
		_apply_input_mode()

@export var player: PlayerController

func get_aim_world_position() -> Vector2:
	return mouse_pos

var _aim_screen_pos := Vector2.ZERO
var _aim_initialized := false
var _touch_reload_was_pressed := false
var _touch_swap_was_pressed := false
var _touch_aim_dir := Vector2.RIGHT
var _touch_look_pointer_id := -1
var _touch_look_start_screen_pos := Vector2.ZERO
var _touch_look_current_screen_pos := Vector2.ZERO
var _touch_look_start_angle := 0.0
var _mouse_look_delta_x := 0.0
var _look_angle := 0.0
var _was_local_player := false
var _active_fire_mode := -1

func get_aim_screen_position() -> Vector2:
	return _aim_screen_pos

func set_authority(peer_id: int):
	set_multiplayer_authority(peer_id)
	if peer_id == multiplayer.get_unique_id():
		set_process(true)
		set_process_input(true)
	else:
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
		_update_touch_look_from_drag()

		mouse_pos = player.global_position + (_touch_aim_dir * touch_aim_distance)
		_aim_screen_pos = screen_half + (_touch_aim_dir * touch_crosshair_radius)
		return

	_aim_screen_pos = screen_half
	var look_dir := Vector2.RIGHT.rotated(_look_angle)
	mouse_pos = player.global_position + (look_dir * touch_aim_distance)

func _resolve_look_joystick() -> VirtualJoystick:
	if not is_instance_valid(player) or not is_instance_valid(player.hud):
		return null
	if player.hud.has_method("get_look_joystick"):
		return player.hud.get_look_joystick()
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
	_touch_reload_was_pressed = false
	_touch_swap_was_pressed = false
	_touch_aim_dir = Vector2.RIGHT
	_touch_look_pointer_id = -1
	_touch_look_start_screen_pos = Vector2.ZERO
	_touch_look_current_screen_pos = Vector2.ZERO
	_touch_look_start_angle = 0.0
	if is_instance_valid(player):
		_look_angle = player.global_rotation

	_set_touch_controls_visible(_is_touch_mode())

	var move_joystick := _resolve_move_joystick()
	if move_joystick != null:
		move_joystick.use_input_actions = false

	var look_joystick := _resolve_look_joystick()
	if look_joystick != null:
		look_joystick.use_input_actions = false

func _process_touch_input() -> void:
	var move_joystick := _resolve_move_joystick()
	if move_joystick != null and move_joystick.is_pressed:
		input_vector = move_joystick.output
	else:
		input_vector = Vector2.ZERO

	var shoot_button := _resolve_touch_button("Shoot")
	var is_shoot_pressed := shoot_button != null and shoot_button.is_pressed()
	var headshot_button := _resolve_touch_button("Headshot")
	var is_headshot_pressed := headshot_button != null and headshot_button.is_pressed()
	if is_headshot_pressed:
		_set_fire_state(true, PlayerController.ShotIntent.HEAD)
	elif is_shoot_pressed:
		_set_fire_state(true, PlayerController.ShotIntent.BODY)
	else:
		_set_fire_state(false)
	
	var reload_button := _resolve_touch_button("Reload")
	var is_reload_pressed := reload_button != null and reload_button.is_pressed()
	if is_reload_pressed and not _touch_reload_was_pressed:
		player.request_reload.rpc_id(1)
	_touch_reload_was_pressed = is_reload_pressed

	var swap_button := _resolve_touch_button("Swap")
	var is_swap_pressed := swap_button != null and swap_button.is_pressed()
	if is_swap_pressed and not _touch_swap_was_pressed:
		player.request_switch_weapon_previous.rpc_id(1)
	_touch_swap_was_pressed = is_swap_pressed

func _process_mouse_keyboard_input() -> void:
	input_vector = Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
	).normalized()

	if Input.is_action_just_pressed("slow_walk"):
		player.request_start_slow_walk.rpc_id(1)

	if Input.is_action_just_released("slow_walk"):
		player.request_stop_slow_walk.rpc_id(1)

	var is_body_fire_pressed := Input.is_action_pressed("shoot")
	var is_head_fire_pressed := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if is_head_fire_pressed:
		_set_fire_state(true, PlayerController.ShotIntent.HEAD)
	elif is_body_fire_pressed:
		_set_fire_state(true, PlayerController.ShotIntent.BODY)
	else:
		_set_fire_state(false)

	if Input.is_action_just_pressed("reload"):
		player.request_reload.rpc_id(1)

	if Input.is_action_just_pressed("scroll_up"):
		player.request_switch_weapon_previous.rpc_id(1)

	if Input.is_action_just_pressed("scroll_down"):
		player.request_switch_weapon_next.rpc_id(1)

	if Input.is_action_just_pressed("primary"):
		player.request_switch_weapon_slot.rpc_id(1, WeaponManager.WeaponSlot.PRIMARY)

	if Input.is_action_just_pressed("secondary"):
		player.request_switch_weapon_slot.rpc_id(1, WeaponManager.WeaponSlot.SECONDARY)

	if Input.is_action_just_pressed("malee"):
		player.request_switch_weapon_slot.rpc_id(1, WeaponManager.WeaponSlot.MELEE)

	if Input.is_action_just_pressed("drop_weapon"):
		player.request_drop_weapon.rpc_id(1)

	if Input.is_action_just_pressed("pickup"):
		player.request_interact.rpc_id(1)

func _input(event: InputEvent) -> void:
	if _is_touch_mode():
		_process_touch_look_event(event)
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
			_mouse_look_delta_x += event.relative.x
			if is_instance_valid(player):
				_look_angle += event.relative.x * player.mouse_turn_sensitivity

func consume_mouse_look_delta_x() -> float:
	var look_delta := _mouse_look_delta_x
	_mouse_look_delta_x = 0.0
	return look_delta

func on_local_player_spawned() -> void:
	_was_local_player = true
	if _can_control_mouse_capture() and not _is_touch_mode():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _can_control_mouse_capture() -> bool:
	if get_multiplayer_authority() != multiplayer.get_unique_id():
		return false
	if not is_instance_valid(player):
		return false
	return player.is_local_player

func _set_touch_controls_visible(is_visible: bool) -> void:
	if not is_instance_valid(player) or not is_instance_valid(player.hud):
		return

	var touch_nodes := ["MovementJoystick", "Shoot", "Headshot", "Swap"]
	for node_name in touch_nodes:
		var node := player.hud.get_node_or_null("Controls/%s" % node_name)
		if node is CanvasItem:
			node.visible = is_visible

	var look_joystick := player.hud.get_node_or_null("Controls/LookJoystick")
	if look_joystick is CanvasItem:
		look_joystick.visible = false

func _set_fire_state(is_pressed: bool, shot_mode: int = PlayerController.ShotIntent.BODY) -> void:
	if not is_pressed:
		if _active_fire_mode != -1:
			player.request_stop_fire.rpc_id(1)
			_active_fire_mode = -1
		return

	if _active_fire_mode == shot_mode:
		return

	if _active_fire_mode != -1:
		player.request_stop_fire.rpc_id(1)

	player.request_start_fire.rpc_id(1, shot_mode)
	_active_fire_mode = shot_mode

func _process_touch_look_event(event: InputEvent) -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var screen_size := viewport.get_visible_rect().size
	if screen_size.x <= 0.0:
		return

	if event is InputEventScreenTouch:
		var touch_event := event as InputEventScreenTouch
		if touch_event.pressed:
			if _touch_look_pointer_id == -1 and touch_event.position.x >= screen_size.x * touch_look_zone_start_x:
				_touch_look_pointer_id = touch_event.index
				_touch_look_start_screen_pos = touch_event.position
				_touch_look_current_screen_pos = touch_event.position
				_touch_look_start_angle = _look_angle
		elif touch_event.index == _touch_look_pointer_id:
			_touch_look_pointer_id = -1
		return

	if event is InputEventScreenDrag:
		var drag_event := event as InputEventScreenDrag
		if drag_event.index != _touch_look_pointer_id:
			return
		_touch_look_current_screen_pos = drag_event.position
		_update_touch_look_from_drag()

func _update_touch_look_from_drag() -> void:
	if _touch_look_pointer_id == -1:
		return

	var drag_x := _touch_look_current_screen_pos.x - _touch_look_start_screen_pos.x
	if abs(drag_x) < touch_look_drag_deadzone_pixels:
		return

	if is_instance_valid(player):
		_look_angle = _touch_look_start_angle + (drag_x * player.mouse_turn_sensitivity)
	else:
		_look_angle = _touch_look_start_angle + (drag_x * 0.01)

	_touch_aim_dir = Vector2.RIGHT.rotated(_look_angle)
