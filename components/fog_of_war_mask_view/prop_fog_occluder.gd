extends Node

## Existing prop scenes supply collision. Derive fog from it at runtime so
## generated maps never maintain a second set of prop polygons by hand.
var _occluders: Array[LightOccluder2D] = []

func _ready() -> void:
	var viewport := MaskViewProvider.viewport
	if not is_instance_valid(viewport):
		return
	var level := viewport.get_node_or_null("Level") as Node2D
	if level == null:
		return
	for child in get_parent().get_children():
		var points := PackedVector2Array()
		if child is CollisionPolygon2D:
			points = child.polygon
		elif child is CollisionShape2D and child.shape is RectangleShape2D:
			var half: Vector2 = child.shape.size * 0.5
			points = PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)])
		if points.is_empty():
			continue
		var occluder := LightOccluder2D.new()
		var polygon := OccluderPolygon2D.new()
		polygon.polygon = points
		occluder.occluder = polygon
		level.add_child(occluder)
		occluder.global_transform = (child as Node2D).global_transform
		_occluders.append(occluder)

func _exit_tree() -> void:
	for occluder in _occluders:
		if is_instance_valid(occluder):
			occluder.queue_free()
