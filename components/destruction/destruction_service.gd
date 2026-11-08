extends Node
class_name DestructionService

const GROUP := &"destruction_service"
const RPC_CHANNEL_DESTRUCTION := 3

signal cells_destroyed(cells: Array[Vector2i])

var _cell_hp: Dictionary = {}
var _pending: Dictionary = {}

func _ready() -> void:
	add_to_group(GROUP)
	request_initial_state.call_deferred()

static func current(tree: SceneTree) -> DestructionService:
	return tree.get_first_node_in_group(GROUP) as DestructionService

func apply_cell_damage(walls: DestructibleWalls, cell: Vector2i, amount: int, kind: int) -> void:
	if not multiplayer.is_server() or amount <= 0 or not is_instance_valid(walls):
		return
	if not get_parent().is_ancestor_of(walls) or not walls.has_wall(cell):
		return
	if not DestructionMaterial.can_damage(walls.cell_material(cell), kind):
		return
	var path := get_parent().get_path_to(walls)
	var key := "%s|%d,%d" % [path, cell.x, cell.y]
	var hp := int(_cell_hp.get(key, walls.cell_max_hp(cell))) - amount
	if hp > 0:
		_cell_hp[key] = hp
		return
	_cell_hp.erase(key)
	var cells: Array[Vector2i] = [cell]
	walls.destroy_cells(cells)
	var pending: PackedVector2Array = _pending.get(path, PackedVector2Array())
	pending.append(Vector2(cell))
	_pending[path] = pending
	cells_destroyed.emit(cells)

func apply_explosion(center: Vector2, radius: float, max_damage: int) -> void:
	if not multiplayer.is_server() or radius <= 0.0 or max_damage <= 0:
		return
	var space := get_viewport().world_2d.direct_space_state
	var damage_events: Array[Dictionary] = []
	for walls in _walls_nodes():
		var low := walls.cell_at_world(center)
		var high := low
		for offset in [Vector2(-radius, -radius), Vector2(radius, -radius), Vector2(radius, radius), Vector2(-radius, radius)]:
			var cell := walls.cell_at_world(center + offset)
			low = low.min(cell)
			high = high.max(cell)
		for x in range(low.x, high.x + 1):
			for y in range(low.y, high.y + 1):
				var cell := Vector2i(x, y)
				if not DestructionMaterial.can_damage(walls.cell_material(cell), DestructionMaterial.KIND_EXPLOSIVE):
					continue
				var target := walls.to_global(walls.map_to_local(cell))
				var amount := roundi(max_damage * maxf(1.0 - center.distance_to(target) / radius, 0.0))
				if amount > 0 and blast_line_clear(space, center, target, walls, cell):
					damage_events.append({"walls": walls, "cell": cell, "amount": amount})
	# Resolve against the intact geometry first, so iteration order cannot send a blast through extra layers.
	for event in damage_events:
		apply_cell_damage(event.walls, event.cell, event.amount, DestructionMaterial.KIND_EXPLOSIVE)

static func blast_line_clear(space: PhysicsDirectSpaceState2D, from: Vector2, to: Vector2, walls: DestructibleWalls = null, cell: Vector2i = Vector2i.ZERO, target_body: CollisionObject2D = null) -> bool:
	var query := PhysicsRayQueryParameters2D.create(from, to, 1)
	query.hit_from_inside = true
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return true
	if walls != null and hit.get("collider") == walls:
		return walls.cell_from_hit(hit) == cell
	return target_body != null and hit.get("collider") == target_body

func _physics_process(_delta: float) -> void:
	if not multiplayer.is_server() or _pending.is_empty():
		return
	if not multiplayer.get_peers().is_empty():
		for path: NodePath in _pending:
			_cells_destroyed_event.rpc(path, _pending[path])
	_pending.clear()

func request_initial_state() -> void:
	if NetUtil.has_active_peer(multiplayer) and not multiplayer.is_server():
		if multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			request_state.rpc_id(1)

@rpc("authority", "call_remote", "reliable", RPC_CHANNEL_DESTRUCTION)
func _cells_destroyed_event(walls_path: NodePath, cells: PackedVector2Array) -> void:
	var walls := get_parent().get_node_or_null(walls_path) as DestructibleWalls
	if walls != null:
		walls.destroy_cells(_unpack_cells(cells))

@rpc("any_peer", "call_remote", "reliable", RPC_CHANNEL_DESTRUCTION)
func request_state() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not multiplayer.get_peers().has(sender):
		return
	var walls_state: Dictionary = {}
	for walls in _walls_nodes():
		var cells := PackedVector2Array()
		for cell in walls.destroyed_cells():
			cells.append(Vector2(cell))
		walls_state[get_parent().get_path_to(walls)] = cells
	_full_state.rpc_id(sender, walls_state, {})

@rpc("authority", "call_remote", "reliable", RPC_CHANNEL_DESTRUCTION)
func _full_state(walls_state: Dictionary, _door_states: Dictionary) -> void:
	for path: NodePath in walls_state:
		var walls := get_parent().get_node_or_null(path) as DestructibleWalls
		if walls != null:
			walls.restore_all()
			walls.destroy_cells(_unpack_cells(walls_state[path]))

func reset_all() -> void:
	if not multiplayer.is_server():
		return
	_reset_event()
	if not multiplayer.get_peers().is_empty():
		_reset_event.rpc()

@rpc("authority", "call_remote", "reliable", RPC_CHANNEL_DESTRUCTION)
func _reset_event() -> void:
	_cell_hp.clear()
	_pending.clear()
	for walls in _walls_nodes():
		walls.restore_all()

func _walls_nodes() -> Array[DestructibleWalls]:
	var walls_nodes: Array[DestructibleWalls] = []
	for node in get_tree().get_nodes_in_group(DestructibleWalls.GROUP):
		var walls := node as DestructibleWalls
		if walls != null and get_parent().is_ancestor_of(walls):
			walls_nodes.append(walls)
	return walls_nodes

static func _unpack_cells(packed: PackedVector2Array) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for cell in packed:
		cells.append(Vector2i(cell))
	return cells
