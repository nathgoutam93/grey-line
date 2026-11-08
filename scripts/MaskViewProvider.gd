extends Node

@export var viewport: FowViewportController

func _ready() -> void:
	find_viewport()

func find_viewport() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		viewport = null
		return

	viewport = scene.find_child("FowMaskView", true, false) as FowViewportController
	if viewport == null:
		viewport = scene.find_child("MaskView", true, false) as FowViewportController

	if not viewport:
		push_warning("Mask Viewport not found")

func set_viewport(_viewport: FowViewportController) -> void:
	viewport = _viewport
