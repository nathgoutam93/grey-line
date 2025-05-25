extends PointLight2D


@export_range(0, 30) var fog_offset: float = 0.0

@onready var player_camera: Camera2D = get_tree().get_current_scene().get_node_or_null("Player/Camera2D")

func _ready():
	blend_mode = Light2D.BLEND_MODE_SUB
	shadow_enabled = true

	if not player_camera:
		push_warning("Player with a camera not found in active scene")

func _process(_delta: float) -> void:
	if not player_camera:
		return

	# 1. Move the light with the player
	global_position = player_camera.global_position
	offset = Vector2(-fog_offset, 0)

	# 2. Rotate toward the mouse using the camera
	if player_camera:
		var mouse_pos = player_camera.get_global_mouse_position()
		look_at(mouse_pos)
