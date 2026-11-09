extends RefCounted

const Builder := preload("res://tools/map_builder.gd")

## Called after physics has synchronized a single isolated round map.
static func validate(world: Node2D) -> Array[String]:
	var errors: Array[String] = []
	for path in ["Map", "FowMaskView/Level", "FowMaskView/LOS", "FowMaskView/Camera2D", "CanvasLayer/FogOfWar", "RoundGameMode", "DestructionService", "PlayerSpawner", "PickupSpawner", "ProjectileSpawner", "Map/SpawnPoints/AttackerSpawns", "Map/SpawnPoints/DefenderSpawns"]:
		if not world.has_node(path):
			errors.append("Missing " + path)
	if not errors.is_empty():
		return errors
	var mode := world.get_node("RoundGameMode") as RoundGameMode
	if mode == null or mode.map != world.get_node("Map") or mode.spawn_point_container != world.get_node("Map/SpawnPoints"):
		errors.append("Round mode references are not wired to this map")
	var nodes: Array[Node] = []
	_collect(world, nodes)
	var objectives: Array[ObjectiveZone] = []
	var walls: Array[DestructibleWalls] = []
	for node in nodes:
		if node is ObjectiveZone:
			objectives.append(node)
		if node is DestructibleWalls:
			walls.append(node)
	if objectives.size() != 1:
		errors.append("Expected exactly one ObjectiveZone, got %d" % objectives.size())
		return errors
	var circle := CircleShape2D.new()
	circle.radius = 24.0
	for role in ["AttackerSpawns", "DefenderSpawns"]:
		var container := world.get_node("Map/SpawnPoints/" + role)
		if container.get_child_count() < 5:
			errors.append(role + " needs at least five points")
		for point in container.get_children():
			if not point is Node2D:
				errors.append(role + " contains a non-spawn node")
				continue
			var query := PhysicsShapeQueryParameters2D.new()
			query.shape = circle
			query.transform = Transform2D(0.0, point.global_position)
			query.collision_mask = 1
			if not world.get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty():
				errors.append("Blocked spawn: " + String(point.get_path()))
			if role == "AttackerSpawns" and point.global_position.distance_to(objectives[0].global_position) < 1400.0:
				errors.append("Attacker spawn is less than 1400 px from objective: " + point.name)
	for layer in walls:
		for cell in layer.get_used_cells():
			if layer.cell_material(cell) not in [DestructionMaterial.SOFT, DestructionMaterial.REINFORCED, DestructionMaterial.HARD]:
				errors.append("Unknown wall material at %s" % cell)
	var layout_path := String(world.get_meta("layout_path", ""))
	if layout_path.is_empty():
		return errors # map_1_rounds is the hand-authored legacy dev map.
	for path in ["Map/Floor", "Map/DestructibleWalls", "Map/Doors", "Map/Props"]:
		if not world.has_node(path):
			errors.append("Generated map missing " + path)
	if world.find_child("GeneratedOccluders", true, false) != null:
		errors.append("Generated map contains hand-maintained fog copies")
	for node in nodes:
		if node is StaticBody2D and not world.get_node("Map/Doors").is_ancestor_of(node) and not world.get_node("Map/Props").is_ancestor_of(node):
			errors.append("Generated structure uses a StaticBody2D instead of wall tiles")
	var data := Builder.parse(FileAccess.get_file_as_string(layout_path))
	if not String(data.error).is_empty():
		errors.append("Invalid source layout: " + data.error)
		return errors
	if not data.warnings.is_empty():
		errors.append("Layout cover overlaps walls: %s" % [data.warnings])
	var regenerated := Builder.build(data, layout_path)
	var expected := regenerated.get_node("Map/DestructibleWalls") as DestructibleWalls
	if walls.size() != 1 or _cells(walls[0]) != _cells(expected):
		errors.append("Saved wall cells are stale; regenerate the scene")
	var current_zone := objectives[0].get_node("CollisionShape2D") as CollisionShape2D
	var expected_zone := regenerated.get_node("Map/ObjectiveZone/CollisionShape2D") as CollisionShape2D
	if current_zone.shape.size != expected_zone.shape.size or objectives[0].position != (regenerated.get_node("Map/ObjectiveZone") as Node2D).position:
		errors.append("Saved objective is stale; regenerate the scene")
	for path in ["Map/Doors", "Map/Props", "Map/SpawnPoints/AttackerSpawns", "Map/SpawnPoints/DefenderSpawns"]:
		var actual := world.get_node(path)
		var reference := regenerated.get_node(path)
		if actual.get_child_count() != reference.get_child_count():
			errors.append("Saved instances are stale: " + path)
			continue
		for i in range(actual.get_child_count()):
			if (actual.get_child(i) as Node2D).transform != (reference.get_child(i) as Node2D).transform:
				errors.append("Saved transform is stale: " + path)
	regenerated.free()
	return errors

static func _collect(node: Node, output: Array[Node]) -> void:
	for child in node.get_children():
		output.append(child)
		_collect(child, output)

static func _cells(walls: DestructibleWalls) -> Dictionary:
	var cells := {}
	for cell in walls.get_used_cells():
		cells[cell] = [walls.get_cell_source_id(cell), walls.get_cell_atlas_coords(cell), walls.get_cell_alternative_tile(cell)]
	return cells
