extends Node

@export var viewport: SubViewport

func _ready() -> void:
	find_viewport()

func find_viewport():
	viewport = get_tree().current_scene.find_child("MaskView");

	if not viewport:
		push_warning("Mask Viewport not found")

func set_viewport(_viewport: SubViewport):
	viewport = _viewport
