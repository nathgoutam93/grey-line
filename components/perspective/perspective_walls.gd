extends MeshInstance2D
class_name PerspectiveWalls

## Draws the sibling DestructibleWalls as fake-3D blocks (see Perspective):
## one static mesh of side faces and roofs, built once at map load (walls are
## indestructible). Neighbouring cells are merged into runs per material.
## Purely visual: collision, line of sight and the fog mirror still use the
## flat cells, and the flat layer stops drawing while this is active.

## Roof colours per DestructionMaterial (SOFT, REINFORCED, HARD).
const ROOF_COLORS: Array[Color] = [Color("#c4c2b8"), Color("#66707a"), Color("#30373e")]
## [outward neighbour, run direction, cell edge start, cell edge end] per side;
## the edge runs along the run direction.
const SIDES := [
	[Vector2i(1, 0), Vector2i(0, 1), Vector2(1, 0), Vector2(1, 1)],
	[Vector2i(-1, 0), Vector2i(0, 1), Vector2(0, 0), Vector2(0, 1)],
	[Vector2i(0, 1), Vector2i(1, 0), Vector2(0, 1), Vector2(1, 1)],
	[Vector2i(0, -1), Vector2i(1, 0), Vector2(0, 0), Vector2(1, 0)],
]

@export var walls_path: NodePath = ^"../DestructibleWalls"
@export var wall_height := Perspective.WALL_HEIGHT
@export var hide_flat_walls := true

func _ready() -> void:
	z_index = Perspective.z_for_height(wall_height)
	if not Perspective.is_enabled():
		return
	var walls := get_node_or_null(walls_path) as DestructibleWalls
	if walls == null:
		push_warning("PerspectiveWalls: no DestructibleWalls at %s" % walls_path)
		return
	material = Perspective.material()
	mesh = build_mesh(walls)
	if hide_flat_walls:
		walls.self_modulate = Color(1, 1, 1, 0)

func _process(_delta: float) -> void:
	Perspective.sync_camera(self)

func build_mesh(walls: DestructibleWalls) -> ArrayMesh:
	var cells := {}
	for cell in walls.get_used_cells():
		cells[cell] = clampi(walls.cell_material(cell), 0, ROOF_COLORS.size() - 1)
	var size := Vector2(walls.tile_set.tile_size)
	var to_here := func(cell_corner: Vector2) -> Vector2:
		return to_local(walls.to_global(cell_corner * size))
	var builder := HeightMeshBuilder.new()
	# An edge is exposed where the neighbour across it has no wall.
	for side in SIDES:
		var outward: Vector2i = side[0]
		var along: Vector2i = side[1]
		var edge_a: Vector2 = side[2]
		var edge_b: Vector2 = side[3]
		for run in runs(cells, along, func(cell: Vector2i) -> bool: return not cells.has(cell + outward)):
			var first: Vector2i = run[0]
			var last: Vector2i = run[1]
			var a: Vector2 = to_here.call(Vector2(first) + edge_a)
			var b: Vector2 = to_here.call(Vector2(last) + edge_b)
			builder.add_side(a, b, wall_height, Vector2(outward), ROOF_COLORS[int(run[2])])
	for run in runs(cells, Vector2i(1, 0), func(_cell: Vector2i) -> bool: return true):
		var first: Vector2i = run[0]
		var last: Vector2i = run[1]
		var roof := PackedVector2Array([to_here.call(Vector2(first)), to_here.call(Vector2(last) + Vector2(1, 0)), to_here.call(Vector2(last) + Vector2(1, 1)), to_here.call(Vector2(first) + Vector2(0, 1))])
		builder.add_cap(roof, wall_height, ROOF_COLORS[int(run[2])])
	return builder.build()

## Straight runs of cells (along `along`) that pass `keep` and share a
## material: [first, last, material].
static func runs(cells: Dictionary, along: Vector2i, keep: Callable) -> Array:
	var result := []
	var sorted: Array = cells.keys()
	if along.x != 0:
		sorted.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	else:
		sorted.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x or (a.x == b.x and a.y < b.y))
	var current := []
	for cell: Vector2i in sorted:
		if not keep.call(cell):
			continue
		if not current.is_empty() and current[1] + along == cell and int(current[2]) == int(cells[cell]):
			current[1] = cell
			continue
		if not current.is_empty():
			result.append(current)
		current = [cell, cell, int(cells[cell])]
	if not current.is_empty():
		result.append(current)
	return result
