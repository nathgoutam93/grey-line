extends MultiplayerSynchronizer
class_name PlayerInput

enum InputMode {
	MOUSE_KEYBOARD,
	TOUCH
}

@export var input_vector := Vector2()
@export var mouse_pos := Vector2()
@export var touch_look_speed := 1400.0
@export var touch_aim_distance := 1200.0
@export var input_mode: InputMode = InputMode.MOUSE_KEYBOARD:
	set(value):
		input_mode = value
		_apply_input_mode()

@export var player: PlayerController

func get_aim_world_position() -> Vector2:
	return mouse_pos

var _aim_screen_pos := Vector2.ZERO
var _aim_initialized := false
var _touch_shoot_was_pressed := false
var _touch_swap_was_pressed := false

func get_aim_screen_position() -> Vector2:
	return _aim_screen_pos

func set_authority(peer_id: int):
	set_multiplayer_authority(peer_id)
	if peer_id == multiplayer.get_unique_id():
		set_process(true)

func _ready() -> void:
	set_process(false)
	_apply_input_mode()

func _process(delta: float) -> void:
	_update_aim(delta)

	if _is_touch_mode():
		_process_touch_input()
	else:
		_process_mouse_keyboard_input()

func _update_aim(delta: float) -> void:
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

	if _is_touch_mode():
		var look_joystick := _resolve_look_joystick()
		if look_joystick != null and look_joystick.is_pressed:
			_aim_screen_pos += look_joystick.output * touch_look_speed * delta
		_aim_screen_pos.x = clampf(_aim_screen_pos.x, 0.0, screen_size.x)
		_aim_screen_pos.y = clampf(_aim_screen_pos.y, 0.0, screen_size.y)

		var look_dir := _aim_screen_pos - screen_half
		if look_dir.length_squared() > 0.0001:
			mouse_pos = player.global_position + (look_dir.normalized() * touch_aim_distance)
		else:
			mouse_pos = player.global_position + Vector2.RIGHT * touch_aim_distance
		return

	_aim_screen_pos = viewport.get_mouse_position()
	mouse_pos = player.get_global_mouse_position()

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
	_touch_shoot_was_pressed = false
	_touch_swap_was_pressed = false

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
	if is_shoot_pressed and not _touch_shoot_was_pressed:
		player.request_start_fire.rpc_id(1)
	if not is_shoot_pressed and _touch_shoot_was_pressed:
		player.request_stop_fire.rpc_id(1)
	_touch_shoot_was_pressed = is_shoot_pressed

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

	if Input.is_action_just_pressed("shoot"):
		player.request_start_fire.rpc_id(1)

	if Input.is_action_just_released("shoot"):
		player.request_stop_fire.rpc_id(1)

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

func _set_touch_controls_visible(is_visible: bool) -> void:
	if not is_instance_valid(player) or not is_instance_valid(player.hud):
		return

	var touch_nodes := ["MovementJoystick", "LookJoystick", "Shoot", "Swap"]
	for node_name in touch_nodes:
		var node := player.hud.get_node_or_null("Controls/%s" % node_name)
		if node is CanvasItem:
			node.visible = is_visible
