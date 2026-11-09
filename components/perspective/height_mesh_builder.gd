extends RefCounted
class_name HeightMeshBuilder

## Builds meshes for shaders/perspective.gdshader. Points are given at floor
## level in the mesh's local space plus a height; the shader leans them away
## from the camera. Add sides first, then roofs and layers from low to high:
## 2D meshes draw in order, so later triangles cover earlier ones.

var _vertices := PackedVector2Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _custom := PackedFloat32Array()

func is_empty() -> bool:
	return _vertices.is_empty()

## A vertical face along floor edge a -> b, from the floor to `height`. It is
## hidden while the camera is behind it (relative to `outward`).
func add_side(a: Vector2, b: Vector2, height: float, outward: Vector2, color: Color) -> void:
	var top := color * Perspective.face_shade(outward)
	top.a = color.a
	var bottom := top * Perspective.FLOOR_SHADE
	bottom.a = color.a
	var n := outward.normalized()
	_add_quad([a, b, b, a], [bottom, bottom, top, top], [0.0, 0.0, height, height], n, [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO], false)

## Side faces for every edge of a floor polygon (either winding).
func add_prism_sides(polygon: PackedVector2Array, height: float, color: Color) -> void:
	var clockwise := Geometry2D.is_polygon_clockwise(polygon)
	for i in polygon.size():
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		var edge := b - a
		if edge.is_zero_approx():
			continue
		# is_polygon_clockwise() uses y-up orientation; on screen (y down) the
		# outside of such a polygon is on the right of each edge.
		var outward := Vector2(-edge.y, edge.x) if clockwise else Vector2(edge.y, -edge.x)
		add_side(a, b, height, outward, color)

## A flat polygon at `height`, untextured or mapping local points into `uv_rect`
## (the texture covers `local_rect`).
func add_cap(polygon: PackedVector2Array, height: float, color: Color, local_rect := Rect2(), uv_rect := Rect2()) -> void:
	var textured := local_rect.has_area()
	var indices := Geometry2D.triangulate_polygon(polygon)
	for index in indices:
		var p := polygon[index]
		var uv := Vector2.ZERO
		if textured:
			uv = uv_rect.position + (p - local_rect.position) / local_rect.size * uv_rect.size
		_append(p, color, uv, height, Vector2.ZERO, textured)

## A textured rectangle at `height` (a roof or one slice of a stack).
func add_layer(rect: Rect2, height: float, tint: Color, uv_rect := Rect2(0, 0, 1, 1)) -> void:
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	var uvs := [uv_rect.position, Vector2(uv_rect.end.x, uv_rect.position.y), uv_rect.end, Vector2(uv_rect.position.x, uv_rect.end.y)]
	_add_quad(corners, [tint, tint, tint, tint], [height, height, height, height], Vector2.ZERO, uvs, true)

func build() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if _vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_CUSTOM0] = _custom
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return mesh

func _add_quad(corners: Array, colors: Array, heights: Array, normal: Vector2, uvs: Array, textured: bool) -> void:
	for i in [0, 1, 2, 0, 2, 3]:
		_append(corners[i], colors[i], uvs[i], heights[i], normal, textured)

func _append(point: Vector2, color: Color, uv: Vector2, height: float, normal: Vector2, textured: bool) -> void:
	_vertices.append(point)
	_colors.append(color)
	_uvs.append(uv)
	_custom.append_array([height, normal.x, normal.y, 1.0 if textured else 0.0])
