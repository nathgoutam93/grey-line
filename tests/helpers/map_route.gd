extends RefCounted

## Deterministic test route, assuming doors have been opened. This drives a
## puppet during integration checks; it does not add gameplay AI.
const Builder := preload("res://tools/map_builder.gd")

static func grid_for(data: Dictionary, radius: float = 20.0) -> AStarGrid2D:
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(Vector2i.ZERO, data.size)
	grid.cell_size = Vector2.ONE * Builder.CELL
	grid.offset = Vector2.ONE * Builder.CELL * 0.5
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	grid.update()
	var props: Array[Rect2] = []
	for prop in data.props:
		props.append(Builder.prop_bounds(prop).grow(radius))
	for y in range(data.size.y):
		for x in range(data.size.x):
			var cell := Vector2i(x, y)
			var point := Builder.cell_center(cell)
			var blocked := false
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					var neighbor := cell + Vector2i(dx, dy)
					if not data.walls.has(neighbor):
						continue
					var rect := Rect2(Vector2(neighbor) * Builder.CELL, Vector2.ONE * Builder.CELL)
					var nearest := Vector2(clampf(point.x, rect.position.x, rect.end.x), clampf(point.y, rect.position.y, rect.end.y))
					if point.distance_to(nearest) < radius:
						blocked = true
			for footprint in props:
				blocked = blocked or footprint.has_point(point)
			grid.set_point_solid(cell, blocked)
	return grid

static func length(path: PackedVector2Array) -> float:
	var distance := 0.0
	for i in range(1, path.size()):
		distance += path[i - 1].distance_to(path[i])
	return distance

static func longest_sight_line(world: Node2D, data: Dictionary, grid: AStarGrid2D) -> Dictionary:
	var space := world.get_world_2d().direct_space_state
	var longest := {"length": 0.0, "from": Vector2.ZERO, "to": Vector2.ZERO}
	for y in range(3, data.size.y - 2, 2):
		for x in range(3, data.size.x - 2, 2):
			if grid.is_point_solid(Vector2i(x, y)):
				continue
			var start := Builder.cell_center(Vector2i(x, y))
			for angle in range(128):
				var direction := Vector2.from_angle(angle * PI / 128.0)
				var ends: Array[Vector2] = []
				for sign in [-1, 1]:
					var end: Vector2 = start + direction * 4096 * sign
					var hit := space.intersect_ray(PhysicsRayQueryParameters2D.create(start, end, 1))
					ends.append(hit.get("position", end))
				var distance := ends[0].distance_to(ends[1])
				if distance > float(longest.length):
					longest = {"length": distance, "from": ends[0], "to": ends[1]}
	return longest

static func simplify(path: PackedVector2Array) -> PackedVector2Array:
	if path.size() < 3:
		return path
	var result := PackedVector2Array([path[0]])
	var previous := (path[1] - path[0]).normalized()
	for i in range(2, path.size()):
		var direction := (path[i] - path[i - 1]).normalized()
		if not direction.is_equal_approx(previous):
			result.append(path[i - 1])
		previous = direction
	result.append(path[path.size() - 1])
	return result
