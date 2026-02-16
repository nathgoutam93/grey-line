extends Sprite2D

func _ready() -> void:
	pass

func set_aim_screen_position(screen_pos: Vector2) -> void:
	position = screen_pos

	var screen_size := get_viewport_rect().size
	position.x = clampf(position.x, 0.0, screen_size.x)
	position.y = clampf(position.y, 0.0, screen_size.y)
