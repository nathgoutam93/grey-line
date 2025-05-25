extends Node

var fow_vp: Viewport = null
var mirror_map := {}

func _ready():
    var cs = get_tree().get_current_scene()
    if cs:
        fow_vp = cs.get_node_or_null("MaskView")
        if not fow_vp:
            push_error("FogOccluderSync: No FOWViewport found in the current scene — occluder syncing disabled.")
            return

    for obj in get_tree().get_nodes_in_group("DynamicOccluder"):
        _add_mirror(obj)

    get_tree().connect("node_added", _on_node_added)


func _on_node_added(node):
    if not fow_vp:
        return
    if node.is_in_group("DynamicOccluder"):
        _add_mirror(node)


func _add_mirror(orig):
    if not fow_vp or not is_instance_valid(orig):
        return

    # only mirror if it has an Occluder2D child
    if not orig.has_node("Occluder2D"):
        return

    var oc = orig.get_node("Occluder2D")
    # duplicate just the occluder
    var mirror = oc.duplicate()
    # parent under the FOW viewport so it lives in its World2D
    fow_vp.add_child(mirror)
    mirror_map[orig] = mirror

    # clean up mirror when orig is removed
    orig.connect("tree_exited", self, "_on_obj_exited", [orig])


func _on_obj_exited(orig):
    if mirror_map.has(orig):
        mirror_map[orig].queue_free()
        mirror_map.erase(orig)


func _process(_delta):
    if not fow_vp:
        return
    # sync transforms each frame
    for orig in mirror_map.keys():
        if not is_instance_valid(orig):
            continue
        var oc = orig.get_node("Occluder2D")
        var mir = mirror_map[orig]
        mir.global_position = oc.global_position
        mir.global_rotation = oc.global_rotation
