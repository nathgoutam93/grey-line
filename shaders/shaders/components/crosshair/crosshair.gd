extends Sprite2D

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN) # MOUSE_MODE_CONFINED_HIDDEN

func _process(_delta: float) -> void:
		position = get_viewport().get_mouse_position()
