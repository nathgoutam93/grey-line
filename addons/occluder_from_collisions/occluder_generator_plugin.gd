@tool
extends EditorPlugin

func _enter_tree():
   add_tool_menu_item("Generate Occluders", Callable(self, "_on_generate_pressed"))

func _exit_tree():
    remove_tool_menu_item("Generate Occluders")


func _on_generate_pressed():
    var root = get_tree().get_edited_scene_root()
    if not root:
        push_error("No scene is currently open.")
        return

    var container := root.get_node_or_null("GeneratedOccluders")
    if container:
        container.queue_free()
        container = null

    container = Node2D.new()
    container.name = "GeneratedOccluders"
    root.add_child(container)
    container.owner = root

    var count := _generate_occluders(root, container)
    print("%d Occluders generated!" % count)

func _generate_occluders(node: Node, container: Node2D) -> int:
    var count := 0

    if node is CollisionPolygon2D:
        _create_occluder_from_polygon_bulk(node, container)
        count += 1
    elif node is CollisionShape2D:
        _create_occluder_from_shape_bulk(node, container)
        count += 1

    for child in node.get_children():
        count += _generate_occluders(child, container)

    return count


func _create_occluder_from_polygon_bulk(collision_node: CollisionPolygon2D, container: Node2D):
    var polygon = OccluderPolygon2D.new()
    polygon.polygon = collision_node.polygon

    var occluder = LightOccluder2D.new()
    occluder.occluder = polygon
    occluder.transform = collision_node.global_transform
    container.add_child(occluder)
    occluder.owner = get_tree().get_edited_scene_root()


func _create_occluder_from_shape_bulk(collision_node: CollisionShape2D, container: Node2D):
    var shape = collision_node.shape
    var points: PackedVector2Array = []

    if shape is RectangleShape2D:
        var e = shape.extents
        points = PackedVector2Array([
            Vector2(-e.x, -e.y),
            Vector2(e.x, -e.y),
            Vector2(e.x, e.y),
            Vector2(-e.x, e.y)
        ])
    elif shape is CircleShape2D:
        var r = shape.radius
        points = PackedVector2Array()
        for i in range(16):
            var angle = i * (2 * PI / 16)
            points.append(Vector2(cos(angle), sin(angle)) * r)
    elif shape is CapsuleShape2D:
        var r = shape.radius
        var h = shape.height
        points = PackedVector2Array([
            Vector2(-r, -h / 2),
            Vector2(r, -h / 2),
            Vector2(r, h / 2),
            Vector2(-r, h / 2)
        ])
    else:
        push_warning("Unsupported shape in: %s" % collision_node.name)
        return

    var polygon = OccluderPolygon2D.new()
    polygon.polygon = points

    var occluder = LightOccluder2D.new()
    occluder.occluder = polygon
    occluder.transform = collision_node.global_transform
    container.add_child(occluder)
    occluder.owner = get_tree().get_edited_scene_root()
