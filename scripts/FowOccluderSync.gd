extends Node

var fow_vp: Viewport = null
var mirror_map := {}

func _ready():
    get_tree().connect("node_added", _on_node_added)

    var cs = get_tree().get_current_scene()
    if cs:
        var fow = cs.get_node_or_null("MaskView")
        if fow:
            set_fow_viewport(fow)

func set_fow_viewport(viewport: Viewport) -> void:
    fow_vp = viewport

    for obj in get_tree().get_nodes_in_group("DynamicOccluder"):
        add_dynamic_occluder(obj)

func _on_node_added(node):
    if node.is_in_group("DynamicOccluder"):
        add_dynamic_occluder(node)

func add_dynamic_occluder(orig: Node) -> void:
    if not fow_vp or not is_instance_valid(orig):
        return

    if mirror_map.has(orig):
        return # already mirrored

    if not orig.has_node("Occluder2D"):
        return

    var oc = orig.get_node("Occluder2D")
    var mirror = oc.duplicate()
    fow_vp.add_child(mirror)
    mirror_map[orig] = mirror

    orig.connect("tree_exited", _on_obj_exited)

func _on_obj_exited(orig):
    if mirror_map.has(orig):
        mirror_map[orig].queue_free()
        mirror_map.erase(orig)

func _process(_delta):
    if not fow_vp:
        return

    for orig in mirror_map.keys():
        if not is_instance_valid(orig):
            continue
        var oc = orig.get_node("Occluder2D")
        var mir = mirror_map[orig]
        mir.global_position = oc.global_position
        mir.global_rotation = oc.global_rotation
