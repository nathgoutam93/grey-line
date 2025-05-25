extends PointLight2D

@export var player_character: CharacterBody2D
@onready var player_camera: Camera2D = player_character.get_viewport().get_camera_2d()

@export_range(0, 30) var fog_offset: float = 0.0


func _ready():
	blend_mode = Light2D.BLEND_MODE_SUB
	shadow_enabled = true

	if not player_character:
		push_warning("Player character is not set. Please assign it in the inspector.")

	# Ensure the light is initially positioned correctly
	if player_character:
		global_position = player_character.global_position

func _process(_delta: float) -> void:
	if not player_character:
		return

	# 1. Move the light with the player
	global_position = player_character.global_position
	offset = Vector2(-fog_offset, 0)

	# 2. Rotate toward the mouse using the camera
	if player_camera:
		var mouse_pos = player_camera.get_global_mouse_position()
		look_at(mouse_pos)
