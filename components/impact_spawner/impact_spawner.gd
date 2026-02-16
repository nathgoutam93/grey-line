extends Node2D
class_name ImpactSpawner2D

@export var default_effect_scene: PackedScene = preload("res://scenes/impact/default.tscn")
@export var impact_scene_map: Dictionary = {
	"default": preload("res://scenes/impact/default.tscn"),
	"metal": preload("res://scenes/impact/default.tscn"),
	"wood": preload("res://scenes/impact/default.tscn"),
	"flesh": preload("res://scenes/impact/blood_particle.tscn")
}

func spawn_impact_effect(_position: Vector2, normal: Vector2 = Vector2.UP, surface_type: String = "default") -> void:
	var effect_scene: PackedScene = impact_scene_map.get(surface_type, default_effect_scene)
	print(
		"[ImpactSpawner] surface_type=", surface_type,
		" mapped=", impact_scene_map.has(surface_type),
		" scene=", effect_scene
	)
	if not effect_scene:
		return

	var effect_instance: Node2D = effect_scene.instantiate()
	effect_instance.global_position = _position
	effect_instance.rotation = normal.angle()
	get_tree().current_scene.add_child(effect_instance)
