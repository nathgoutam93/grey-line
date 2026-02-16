extends MultiplayerSynchronizer
class_name PlayerInput

@export var input_vector := Vector2()
@export var mouse_pos := Vector2()
@export var touch_look_speed := 700.0
@export var touch_aim_distance := 1200.0

@export var player: PlayerController

func get_aim_world_position() -> Vector2:
	return mouse_pos

var _aim_screen_pos := Vector2.ZERO
var _aim_initialized := false

func get_aim_screen_position() -> Vector2:
	return _aim_screen_pos

func set_authority(peer_id: int):
	set_multiplayer_authority(peer_id)
	if peer_id == multiplayer.get_unique_id():
		set_process(true)

func _ready() -> void:
	set_process(false)

func _process(delta: float) -> void:
	_update_aim(delta)
	
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

	var look_joystick := _resolve_look_joystick()
	var is_touch_aim := look_joystick != null and (
		DisplayServer.is_touchscreen_available() or look_joystick.is_pressed
	)

	if is_touch_aim:
		if look_joystick.is_pressed:
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
