extends Node
class_name CameraShake

var rng = RandomNumberGenerator.new()

var owner_camera: Camera2D
var shake_strength := 0.0
var shake_fade := 20.0

func _ready() -> void:
	owner_camera = get_parent() as Camera2D
	if not owner_camera:
		push_warning("Camera Shake must be a child of Camera2D")

func _process(delta: float) -> void:
	if not owner_camera:
		return

	if shake_strength > 0:
		shake_strength = lerpf(shake_strength, 0, shake_fade * delta)

	owner_camera.offset = _randomOffset(-shake_strength, shake_strength)

func apply(strength: float = 1):
	shake_strength = strength

func _randomOffset(min_offset: float, max_offset: float):
	return Vector2(rng.randf_range(min_offset, max_offset), rng.randf_range(min_offset, max_offset))
