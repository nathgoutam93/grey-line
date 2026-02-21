extends Node

@export var viewport: SubViewport

func _ready() -> void:
	find_viewport()

func find_viewport() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		viewport = null
		return

	viewport = scene.find_child("FowMaskView", true, false) as SubViewport
	if viewport == null:
		viewport = scene.find_child("MaskView", true, false) as SubViewport

	if not viewport:
		push_warning("Mask Viewport not found")

func set_viewport(_viewport: SubViewport) -> void:
	viewport = _viewport
