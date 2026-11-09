extends RefCounted
class_name RoundMapBuilder

## Shared by the CLI and map validation; the text grid is the source of truth.
const CELL := 16
const TEMPLATE := "res://scenes/maps/_template/round_map_template.tscn"
const MATERIALS := {"S": DestructionMaterial.SOFT, "R": DestructionMaterial.REINFORCED, "#": DestructionMaterial.HARD}
const PROP_SCENES := {"c": "res://scenes/props/crates/crate.tscn", "v": "res://scenes/props/car/car.tscn", "t": "res://scenes/props/truck/truck.tscn"}
const PROP_SIZES := {"c": Vector2(96, 96), "v": Vector2(224, 112), "t": Vector2(64, 432)}
const PROP_SCALES := {"c": 0.19, "v": 0.45, "t": 1.0}
const FOG_SCRIPT := preload("res://components/fog_of_war_mask_view/prop_fog_occluder.gd")

static func parse(text: String) -> Dictionary:
	var normalized := text.replace("\r\n", "\n")
	while normalized.ends_with("\n"):
		normalized = normalized.trim_suffix("\n")
	var rows := normalized.split("\n")
	if rows.is_empty() or rows[0].is_empty():
		return {"error": "Layout is empty"}
	var width := rows[0].length()
	var height := rows.size()
	var walls: Dictionary = {}
	var attacks: Array[Vector2i] = []
	var defends: Array[Vector2i] = []
	var objective: Dictionary = {}
	var props: Array[Dictionary] = []
	for y in range(height):
		if rows[y].length() != width:
			return {"error": "Ragged row %d: expected %d cells" % [y + 1, width]}
		for x in range(width):
			var ch := rows[y][x]
			var cell := Vector2i(x, y)
			if not ch in ".#RS-|adOcvt":
				return {"error": "Unknown character '%s' at %s" % [ch, cell]}
			if MATERIALS.has(ch):
				walls[cell] = MATERIALS[ch]
			match ch:
				"a": attacks.append(cell)
				"d": defends.append(cell)
				"O": objective[cell] = true
			if PROP_SCENES.has(ch):
				props.append({"kind": ch, "cell": cell})
	if attacks.size() < 5 or defends.size() < 5:
		return {"error": "Need at least 5 spawns per role (attacker=%d defender=%d)" % [attacks.size(), defends.size()]}
	if objective.is_empty():
		return {"error": "Need exactly one objective region; found 0"}
	var reached: Dictionary = {}
	var pending: Array[Vector2i] = [objective.keys()[0]]
	while not pending.is_empty():
		var cell := pending.pop_back() as Vector2i
		if reached.has(cell):
			continue
		reached[cell] = true
		for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = cell + direction
			if objective.has(next) and not reached.has(next):
				pending.append(next)
	if reached.size() != objective.size():
		return {"error": "Need exactly one objective region; found disconnected regions"}
	var bounds := Rect2i(objective.keys()[0], Vector2i.ONE)
	for cell in objective:
		bounds = bounds.merge(Rect2i(cell, Vector2i.ONE))
	var doors: Array[Dictionary] = []
	var door_cells: Dictionary = {}
	for y in range(height):
		for x in range(width):
			var ch := rows[y][x]
			var cell := Vector2i(x, y)
			if ch not in ["-", "|"] or door_cells.has(cell):
				continue
			var direction := Vector2i.RIGHT if ch == "-" else Vector2i.DOWN
			var run: Array[Vector2i] = []
			var next := cell
			while next.x < width and next.y < height and rows[next.y][next.x] == ch:
				run.append(next)
				next += direction
			if run.size() != 4:
				return {"error": "Door run at %s must be exactly 4 cells, got %d" % [cell, run.size()]}
			for part in run:
				if part.x == 0 or part.y == 0 or part.x == width - 1 or part.y == height - 1:
					return {"error": "Door at %s is on the map edge" % part}
				var side := Vector2i.DOWN if ch == "-" else Vector2i.RIGHT
				for neighbor in [part - side, part + side]:
					if walls.has(neighbor) or rows[neighbor.y][neighbor.x] in ["-", "|"]:
						return {"error": "Door at %s overlaps a wall or another doorway" % part}
				door_cells[part] = true
			doors.append({"start": cell, "vertical": ch == "|"})
	var warnings: Array[String] = []
	for prop in props:
		var footprint := prop_bounds(prop)
		for cell in walls:
			if footprint.intersects(Rect2(Vector2(cell) * CELL, Vector2.ONE * CELL)):
				warnings.append("Prop '%s' at %s overlaps wall %s" % [prop.kind, prop.cell, cell])
				break
	for cell in walls:
		if bounds.has_point(cell):
			return {"error": "Objective bounding box overlaps wall %s" % cell}
	return {"error": "", "rows": rows, "size": Vector2i(width, height), "walls": walls, "attacks": attacks, "defends": defends, "objective": bounds, "doors": doors, "props": props, "warnings": warnings}

static func cell_center(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * CELL

static func prop_bounds(prop: Dictionary) -> Rect2:
	var size: Vector2 = PROP_SIZES[prop.kind]
	var origin := Vector2(prop.cell) * CELL if prop.kind == "t" else cell_center(prop.cell) - size * 0.5
	return Rect2(origin, size)

static func build(data: Dictionary, layout_path: String = "") -> Node2D:
	var root := (load(TEMPLATE) as PackedScene).instantiate() as Node2D
	root.set_meta("layout_path", layout_path)
	root.set_meta("layout_size", data.size)
	var walls := root.get_node("Map/DestructibleWalls") as DestructibleWalls
	for cell in data.walls:
		walls.set_cell(cell, 0, Vector2i(int(data.walls[cell]), 0))
	var floor := root.get_node("Map/Floor") as ColorRect
	floor.size = Vector2(data.size) * CELL
	var fog_background := root.get_node("FowMaskView/Level/Sprite2D") as Sprite2D
	fog_background.position = floor.size * 0.5
	fog_background.scale = (floor.size + Vector2(4096, 4096)) / Vector2(fog_background.texture.get_size())
	for role in ["attacks", "defends"]:
		var container := root.get_node("Map/SpawnPoints/" + ("AttackerSpawns" if role == "attacks" else "DefenderSpawns"))
		for i in range(data[role].size()):
			var point := Node2D.new()
			point.position = cell_center(data[role][i])
			_add(root, container, point, "Spawn%d" % (i + 1))
	for i in range(data.doors.size()):
		var entry: Dictionary = data.doors[i]
		var door := (load("res://scenes/props/door/door.tscn") as PackedScene).instantiate() as Door
		var direction := Vector2.DOWN if entry.vertical else Vector2.RIGHT
		door.position = cell_center(entry.start) + direction * 1.5 * CELL
		door.rotation = PI * 0.5 if entry.vertical else 0.0
		_add(root, root.get_node("Map/Doors"), door, "Door%d" % (i + 1))
	for i in range(data.props.size()):
		var entry: Dictionary = data.props[i]
		var prop := (load(PROP_SCENES[entry.kind]) as PackedScene).instantiate() as Node2D
		prop.position = prop_bounds(entry).get_center()
		prop.scale = Vector2.ONE * float(PROP_SCALES[entry.kind])
		_add(root, root.get_node("Map/Props"), prop, "Prop%d" % (i + 1))
		var fog := Node.new()
		fog.set_script(FOG_SCRIPT)
		_add(root, prop, fog, "FogOccluder")
	var zone := (load("res://components/round_mode/objective_zone.tscn") as PackedScene).instantiate() as ObjectiveZone
	var bounds: Rect2i = data.objective
	var half := Vector2(bounds.size) * CELL * 0.5
	zone.position = Vector2(bounds.position) * CELL + half
	var shape := RectangleShape2D.new()
	shape.resource_scene_unique_id = "GeneratedObjectiveShape"
	shape.size = half * 2.0
	(zone.get_node("CollisionShape2D") as CollisionShape2D).shape = shape
	var corners := PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)])
	(zone.get_node("Fill") as Polygon2D).polygon = corners
	corners.append(corners[0])
	(zone.get_node("Outline") as Line2D).points = corners
	_add(root, root.get_node("Map"), zone, "ObjectiveZone")
	for child in zone.get_children():
		child.owner = root # Persist generated size and visual overrides on the instance.
	return root

static func _add(root: Node, parent: Node, child: Node, node_name: String) -> void:
	child.name = node_name
	parent.add_child(child)
	child.owner = root

## ResourceSaver generates scene IDs. Normalize them inside the generator so
## equal layouts produce byte-identical files, including on a fresh checkout.
static func save(root: Node, path: String) -> Error:
	var scene := PackedScene.new()
	var error := scene.pack(root)
	if error != OK:
		return error
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	error = ResourceSaver.save(scene, path)
	if error != OK:
		return error
	var text := FileAccess.get_file_as_string(path)
	var header := RegEx.create_from_string('^(\\[gd_scene[^\\n]*?) uid="[^"]+"')
	text = header.sub(text, "$1")
	for kind in ["ext_resource", "sub_resource"]:
		var regex := RegEx.create_from_string('(?m)^\\[' + kind + '[^\\n]*\\bid="([^"]+)"')
		var matches := regex.search_all(text)
		var replacements: Dictionary = {}
		for i in range(matches.size()):
			replacements[matches[i].get_string(1)] = "%s_%03d" % [kind, i + 1]
		for old in replacements:
			var reference := "ExtResource" if kind == "ext_resource" else "SubResource"
			text = text.replace('id="' + old + '"', 'id="' + replacements[old] + '"')
			text = text.replace(reference + '("' + old + '")', reference + '("' + replacements[old] + '")')
	var node_id := RegEx.create_from_string("unique_id=[0-9]+")
	var matches := node_id.search_all(text)
	for i in range(matches.size() - 1, -1, -1):
		var match_id := matches[i]
		text = text.substr(0, match_id.get_start()) + "unique_id=%d" % (1800000000 + i) + text.substr(match_id.get_end())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(text)
	return OK
