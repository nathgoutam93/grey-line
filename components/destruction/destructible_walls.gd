extends TileMapLayer
class_name DestructibleWalls

const GROUP := &"destructible_walls"

var mirror: TileMapLayer
var _original_data := PackedByteArray()
var _original_cells: Array[Vector2i] = []

func _ready() -> void:
	add_to_group(GROUP)
	occlusion_enabled = false
	# Body RIDs must identify individual cells for weapon and blast ray hits.
	physics_quadrant_size = 1
	_original_data = tile_map_data.duplicate()
	_original_cells = get_used_cells()
	var viewport := MaskViewProvider.viewport
	if is_instance_valid(viewport):
		var level := viewport.get_node_or_null("Level") as Node2D
		if level != null:
			mirror = TileMapLayer.new()
			mirror.name = "DestructibleWallsMirror"
			mirror.tile_set = tile_set
			mirror.tile_map_data = _original_data
			mirror.collision_enabled = false
			mirror.occlusion_enabled = true
			mirror.modulate = Color(1, 1, 1, 0)
			level.add_child(mirror)
			mirror.global_transform = global_transform
	update_internals()

func _exit_tree() -> void:
	if is_instance_valid(mirror):
		mirror.queue_free()

func cell_at_world(world_pos: Vector2) -> Vector2i:
	return local_to_map(to_local(world_pos))

func cell_from_hit(hit: Dictionary) -> Vector2i:
	var rid: RID = hit.get("rid", RID())
	if rid.is_valid():
		return get_coords_for_body_rid(rid)
	var position: Vector2 = hit.get("position", Vector2.ZERO)
	var normal: Vector2 = hit.get("normal", Vector2.ZERO)
	return cell_at_world(position - normal * 1.0)

func cell_material(cell: Vector2i) -> int:
	var data := get_cell_tile_data(cell)
	return int(data.get_custom_data("material")) if data != null else -1

func cell_max_hp(cell: Vector2i) -> int:
	var data := get_cell_tile_data(cell)
	return int(data.get_custom_data("max_hp")) if data != null else 0

func has_wall(cell: Vector2i) -> bool:
	return get_cell_source_id(cell) != -1

func destroy_cells(cells: Array[Vector2i]) -> void:
	for cell in cells:
		erase_cell(cell)
		if is_instance_valid(mirror):
			mirror.erase_cell(cell)
	update_internals()
	if is_instance_valid(mirror):
		mirror.update_internals()

func restore_all() -> void:
	tile_map_data = _original_data.duplicate()
	update_internals()
	if is_instance_valid(mirror):
		mirror.tile_map_data = _original_data.duplicate()
		mirror.update_internals()

func destroyed_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for cell in _original_cells:
		if not has_wall(cell):
			cells.append(cell)
	return cells
