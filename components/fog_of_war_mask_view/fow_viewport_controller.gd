extends SubViewport

@export var player_camera: Camera2D

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

	if is_instance_valid(los):
		los.global_position = player_camera.global_position
		los.offset = Vector2(-los_offset, 0)

		# 2. Rotate toward the mouse using the camera
		var mouse_pos = player_camera.get_global_mouse_position()
		los.look_at(mouse_pos)
