extends SubViewport

@export var player_camera: Camera2D
@export var player: PlayerController

@export var los: PointLight2D
@export_range(0, 30) var los_offset: float = 0.0

func _ready() -> void:
	MaskViewProvider.set_viewport(self)

func _process(_delta: float) -> void:
	if not is_instance_valid(player_camera):
		return

	var viewport_camera := get_camera_2d()
	if is_instance_valid(viewport_camera):
		viewport_camera.global_position = player_camera.global_position
		viewport_camera.ignore_rotation = player_camera.ignore_rotation
		if not viewport_camera.ignore_rotation:
			viewport_camera.global_rotation = player_camera.global_rotation

	if is_instance_valid(los):
		if is_instance_valid(player):
			los.global_position = player.global_position
		else:
			los.global_position = player_camera.global_position
		los.offset = Vector2(-los_offset, 0)

		if is_instance_valid(player) and is_instance_valid(player.player_input):
			if player.player_input.input_mode == PlayerInput.InputMode.MOUSE_KEYBOARD:
				los.global_rotation = player.global_rotation
				return

		var aim_world_pos := player_camera.get_global_mouse_position()
		if is_instance_valid(player) and is_instance_valid(player.player_input) and player.player_input.has_method("get_aim_world_position"):
			aim_world_pos = player.player_input.get_aim_world_position()
		los.look_at(aim_world_pos)
