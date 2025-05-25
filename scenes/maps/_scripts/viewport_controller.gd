extends SubViewport

var main_camera: Camera2D

func _process(_delta: float) -> void:
	if main_camera:
		var offset = Vector2(size) / 2 - main_camera.get_screen_center_position()
		canvas_transform.origin = offset
