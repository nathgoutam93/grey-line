extends Node2D
class_name ImpactSpawner2D

@export var default_effect_scene: PackedScene = preload("res://scenes/impact/default.tscn")
@export var surface_effects: Dictionary = {
    "metal": null,
    "wood": null,
    "flesh": null
}

func spawn_impact_effect(_position: Vector2, normal: Vector2 = Vector2.UP, surface_type: String = "") -> void:
    var effect_scene: PackedScene = surface_effects.get(surface_type, default_effect_scene)
    if not effect_scene:
        return

    var effect_instance: Node2D = effect_scene.instantiate()
    effect_instance.global_position = _position
    effect_instance.rotation = normal.angle()
    get_tree().current_scene.add_child(effect_instance)
