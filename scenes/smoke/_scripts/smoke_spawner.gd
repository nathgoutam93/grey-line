extends Node

@export var smoke_scene: PackedScene = preload("res://scenes/smoke/smoke.tscn")
@export var mask_smoke_scene: PackedScene = preload("res://scenes/smoke/smoke_mask.tscn")

func spawn_smoke_at(pos: Vector2):
	var smoke = smoke_scene.instantiate()
	get_tree().current_scene.add_child(smoke)
	smoke.global_position = pos
	
	var mask = mask_smoke_scene.instantiate()
	var viewport := MaskViewProvider.viewport
	if not is_instance_valid(viewport):
		push_warning("Mask viewport not found; skipping mask smoke spawn")
		return

	var level := viewport.get_node_or_null("Level")
	if level == null:
		push_warning("Mask viewport Level node not found; skipping mask smoke spawn")
		return

	level.add_child(mask)
	mask.global_position = pos
	
