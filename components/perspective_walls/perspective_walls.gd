extends MeshInstance2D
class_name PerspectiveWalls

## Draws the sibling DestructibleWalls as fake-3D blocks: one static mesh of
## roofs and side faces, built once at map load (walls are indestructible).
## perspective_walls.gdshader leans the roofs away from the camera centre each
## frame, so walls show the sides facing the player as the camera moves.
## Purely visual: collision, line of sight and the fog mirror still use the
## flat cells, and the flat layer stops drawing while this is active.

const SHADER := preload("res://shaders/perspective_walls.gdshader")
## Roof colours per DestructionMaterial (SOFT, REINFORCED, HARD).
const ROOF_COLORS: Array[Color] = [Color("#c4c2b8"), Color("#66707a"), Color("#30373e")]

enum Face { ROOF, EAST, WEST, SOUTH, NORTH }
## Light comes from the top-left: west/north faces lit, east/south in shade.
const FACE_SHADE := {Face.EAST: 0.62, Face.WEST: 0.86, Face.SOUTH: 0.5, Face.NORTH: 0.8}
## Darkening of a side face where it meets the floor (fake ambient occlusion).
const FLOOR_SHADE := 0.55

@export var walls_path: NodePath = ^"../DestructibleWalls"
## World px. The lean is wall_height / (eye_height - wall_height) of a point's
## distance from the screen centre.
@export var wall_height := 40.0
@export var eye_height := 700.0
@export var hide_flat_walls := true

var _material := ShaderMaterial.new()

func _ready() -> void:
	z_index = 20 # above players: a wall's face can hide someone behind it
	if DisplayServer.get_name() == "headless":
		return
	var walls := get_node_or_null(walls_path) as DestructibleWalls
	if walls == null:
		push_warning("PerspectiveWalls: no DestructibleWalls at %s" % walls_path)
		return
	_material.shader = SHADER
	_material.set_shader_parameter("height_factor", wall_height / maxf(eye_height - wall_height, 1.0))
	material = _material
	mesh = build_mesh(walls)
	if hide_flat_walls:
		walls.self_modulate = Color(1, 1, 1, 0)

func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_2d()
	if camera != null and mesh != null:
		_material.set_shader_parameter("camera_center", to_local(camera.get_screen_center_position()))

## Roofs merged into horizontal runs and exposed side faces merged into
## straight runs, per material. Sides come first so roofs draw over them.
func build_mesh(walls: DestructibleWalls) -> ArrayMesh:
	var cells := {}
	for cell in walls.get_used_cells():
		cells[cell] = maxi(walls.cell_material(cell), 0)
	var size := Vector2(walls.tile_set.tile_size)
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var to_here := func(cell_corner: Vector2) -> Vector2:
		return to_local(walls.to_global(cell_corner * size))

	# Sides: an edge is exposed where the neighbour across it has no wall.
	var sides := [
		[Face.EAST, Vector2i(1, 0), Vector2i(0, 1), Vector2(1, 0), Vector2(1, 1)],
		[Face.WEST, Vector2i(-1, 0), Vector2i(0, 1), Vector2(0, 0), Vector2(0, 1)],
		[Face.SOUTH, Vector2i(0, 1), Vector2i(1, 0), Vector2(0, 1), Vector2(1, 1)],
		[Face.NORTH, Vector2i(0, -1), Vector2i(1, 0), Vector2(0, 0), Vector2(1, 0)],
	]
	for side in sides:
		var face: int = side[0]
		var outward: Vector2i = side[1]
		var along: Vector2i = side[2]
		var edge_a: Vector2 = side[3]
		var edge_b: Vector2 = side[4]
		for run in _runs(cells, along, func(cell: Vector2i) -> bool: return not cells.has(cell + outward)):
			var first: Vector2i = run[0]
			var last: Vector2i = run[1]
			var tint: Color = ROOF_COLORS[int(run[2])] * float(FACE_SHADE[face])
			tint.a = 1.0
			var floor_tint: Color = tint * FLOOR_SHADE
			floor_tint.a = 1.0
			var a: Vector2 = to_here.call(Vector2(first) + edge_a)
			var b: Vector2 = to_here.call(Vector2(last) + edge_b)
			_quad(vertices, colors, uvs, [a, b, b, a], [floor_tint, floor_tint, tint, tint], [0.0, 0.0, 1.0, 1.0], face)

	for run in _runs(cells, Vector2i(1, 0), func(_cell: Vector2i) -> bool: return true):
		var first: Vector2i = run[0]
		var last: Vector2i = run[1]
		var roof := ROOF_COLORS[int(run[2])]
		var corners: Array[Vector2] = [to_here.call(Vector2(first)), to_here.call(Vector2(last) + Vector2(1, 0)), to_here.call(Vector2(last) + Vector2(1, 1)), to_here.call(Vector2(first) + Vector2(0, 1))]
		_quad(vertices, colors, uvs, corners, [roof, roof, roof, roof], [1.0, 1.0, 1.0, 1.0], Face.ROOF)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var result := ArrayMesh.new()
	if not vertices.is_empty():
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result

## Straight runs of cells (along `along`) that pass `keep` and share a
## material: [first, last, material].
func _runs(cells: Dictionary, along: Vector2i, keep: Callable) -> Array:
	var runs := []
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
			runs.append(current)
		current = [cell, cell, int(cells[cell])]
	if not current.is_empty():
		runs.append(current)
	return runs

func _quad(vertices: PackedVector2Array, colors: PackedColorArray, uvs: PackedVector2Array, corners: Array, tints: Array, heights: Array, face: int) -> void:
	for i in [0, 1, 2, 0, 2, 3]:
		vertices.append(corners[i])
		colors.append(tints[i])
		uvs.append(Vector2(face, heights[i]))
