@tool
extends EditorPlugin

func _enter_tree():
	add_tool_menu_item("Create Occluder", Callable(self, "_on_create_occluder"))

func _exit_tree():
	remove_tool_menu_item("Create Occluder")

func _on_create_occluder():
	var selected_nodes = get_editor_interface().get_selection().get_selected_nodes()
	if selected_nodes.is_empty():
		push_error("No node selected.")
		return

	for node in selected_nodes:
		if node is CollisionPolygon2D:
			_create_occluder_from_polygon(node)
		elif node is CollisionShape2D:
			_create_occluder_from_shape(node)
		else:
			push_warning("Unsupported node type: %s" % node)

func _create_occluder_from_polygon(collision_node: CollisionPolygon2D):
	var polygon = OccluderPolygon2D.new()
	polygon.polygon = collision_node.polygon

	var occluder = LightOccluder2D.new()
	occluder.occluder = polygon
	occluder.transform = collision_node.transform
	collision_node.get_parent().add_child(occluder)
	occluder.owner = collision_node.owner
	print("✅ LightOccluder2D created from CollisionPolygon2D")

func _create_occluder_from_shape(collision_node: CollisionShape2D):
	var shape = collision_node.shape
	var points: PackedVector2Array = []

	if shape is RectangleShape2D:
		var e = shape.extents
		points = [
			Vector2(-e.x, -e.y),
			Vector2(e.x, -e.y),
			Vector2(e.x, e.y),
			Vector2(-e.x, e.y)
		]
	elif shape is CircleShape2D:
		var r = shape.radius
		for i in range(16):
			var angle = i * (2 * PI / 16)
			points.append(Vector2(cos(angle), sin(angle)) * r)
	elif shape is CapsuleShape2D:
		var r = shape.radius
		var h = shape.height
		points = [
			Vector2(-r, -h / 2),
			Vector2(r, -h / 2),
			Vector2(r, h / 2),
			Vector2(-r, h / 2)
		]
	else:
		push_warning("Unsupported shape in: %s" % collision_node.name)
		return

	var polygon = OccluderPolygon2D.new()
	polygon.polygon = points

	var occluder = LightOccluder2D.new()
	occluder.occluder = polygon
	occluder.transform = collision_node.transform
	collision_node.get_parent().add_child(occluder)
	occluder.owner = collision_node.owner
	print("✅ LightOccluder2D created from CollisionShape2D")
