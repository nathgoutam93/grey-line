extends Node

@export var smoke_scene: PackedScene = preload("res://scenes/smoke/smoke.tscn")
@export var mask_smoke_scene: PackedScene = preload("res://scenes/smoke/smoke_mask.tscn")

func spawn_smoke_at(pos: Vector2):
	var smoke = smoke_scene.instantiate()
	get_tree().current_scene.add_child(smoke)
	smoke.global_position = pos
	
	var mask = mask_smoke_scene.instantiate()
	get_tree().current_scene.get_node('MaskView/Level').add_child(mask)
	mask.global_position = pos
	
