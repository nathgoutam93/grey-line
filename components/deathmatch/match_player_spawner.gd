extends Node
class_name MatchPlayerSpawner

## Spawns, sets up and respawns players for a match (child `Spawning` of the
## game mode). The server instantiates players under `map`; the map's
## MultiplayerSpawner replicates them and _setup_player finishes setup on
## every peer. Configured by the game mode through setup().

## Server only: a player finished setup (first spawn and every respawn).
signal player_setup(peer_id: int, player: PlayerController)

const RPC_CHANNEL_WORLD := 1

## Server only: cleared when the match ends so nobody (re)spawns.
var spawning_enabled := true

var _player_scene: PackedScene
var _map: Node2D
var _spawn_points: Array[Node2D] = []
var _role_spawn_points: Dictionary = {}

func setup(map: Node2D, spawn_point_container: Node, player_scene: PackedScene) -> void:
	_map = map
	_player_scene = player_scene
	_spawn_points.clear()
	_role_spawn_points.clear()
	if is_instance_valid(spawn_point_container):
		for child in spawn_point_container.get_children():
			if child.name in ["AttackerSpawns", "DefenderSpawns"]:
				var team := Teams.ALPHA if child.name == "AttackerSpawns" else Teams.BRAVO
				var points: Array[Node2D] = []
				for point in child.get_children():
					if point is Node2D:
						points.append(point)
				if not points.is_empty():
					_role_spawn_points[team] = points
				continue
			if child is Node2D:
				_spawn_points.append(child)

## Prefer an unoccupied point with the greatest distance to the nearest enemy.
func choose_spawn_point(team: int) -> Node2D:
	var points: Array[Node2D] = _role_spawn_points.get(team, _spawn_points)
	if points.is_empty():
		return null
	var best: Node2D = null
	var best_distance := -1.0
	for point in points:
		var free := true
		var nearest_enemy := INF
		for node in get_tree().get_nodes_in_group("Player"):
			var player := node as PlayerController
			if player == null or player.is_dead:
				continue
			var distance := point.global_position.distance_to(player.global_position)
			if distance < 96.0:
				free = false
			if team == Teams.NONE or player.team != team:
				nearest_enemy = minf(nearest_enemy, distance)
		if free and (best == null or nearest_enemy > best_distance):
			best = point
			best_distance = nearest_enemy
	return best if best != null else points.pick_random()

func spawn_initial_connected_players() -> void:
	if not is_inside_tree():
		return
	if not NetUtil.has_active_peer(multiplayer) or not multiplayer.is_server():
		return
	if not spawning_enabled:
		return
	if not OS.has_feature("dedicated_server"):
		spawn_player(1)
	for peer_id in multiplayer.get_peers():
		spawn_player(peer_id)
	spawn_bots()

func spawn_bots() -> void:
	for bot_id in MultiplayerSession.bot_ids:
		spawn_player_if_missing(bot_id)

func spawn_player_if_missing(peer_id: int) -> void:
	if not NetUtil.has_active_peer(multiplayer) or not multiplayer.is_server() or not is_instance_valid(_map):
		return
	if _map.get_node_or_null(str(peer_id)) == null and MultiplayerSession.is_peer_connected(peer_id):
		spawn_player(peer_id)

## Server only: spawn a player; the map's MultiplayerSpawner replicates it.
func spawn_player(peer_id: int) -> void:
	if not spawning_enabled or not is_instance_valid(_map):
		return
	var spawn_point := choose_spawn_point(MultiplayerSession.get_team(peer_id))
	if spawn_point == null:
		push_warning("No spawn points configured. Set Deathmatch.spawn_point_container in the editor.")
		return

	var player_instance := _player_scene.instantiate() as PlayerController
	var existing_named_player := _map.get_node_or_null(str(peer_id)) as PlayerController
	if existing_named_player != null:
		existing_named_player.queue_free()
	player_instance.name = str(peer_id)
	player_instance.position = _map.to_local(spawn_point.global_position)
	player_instance.owner_peer_id = peer_id
	player_instance.team = MultiplayerSession.get_team(peer_id)
	player_instance.set_multiplayer_authority(1)

	player_instance.ready.connect(func(): _setup_player.rpc(peer_id, player_instance.get_path(), spawn_point.global_position, NetworkTick.tick, player_instance.team))
	_map.add_child(player_instance, true)
	print("Spawned player for peer %d at %s" % [peer_id, spawn_point.global_position])

## Server only: tell a (late-joining) peer about every existing player.
func sync_existing_players_to_peer(peer_id: int) -> void:
	if not multiplayer.is_server() or not is_instance_valid(_map):
		return
	for child in _map.get_children():
		var player := child as PlayerController
		if player == null:
			continue
		_setup_player.rpc_id(peer_id, player.owner_peer_id, player.get_path(), player.global_position, NetworkTick.tick, player.team)

## Client only: ask the server to (re)send setup for every existing player.
func request_resync() -> void:
	if NetUtil.has_active_peer(multiplayer) and not multiplayer.is_server():
		request_players_resync.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable", RPC_CHANNEL_WORLD)
func request_players_resync() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	sync_existing_players_to_peer(peer_id)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_WORLD)
func _setup_player(peer_id: int, player_path: NodePath, spawn_position: Vector2, server_tick: int, team: int) -> void:
	for _i in range(30):
		if not is_inside_tree():
			return
		if get_node_or_null(player_path) as PlayerController != null:
			break
		await get_tree().process_frame
	if not spawning_enabled or not is_instance_valid(_map):
		return

	var player := get_node_or_null(player_path) as PlayerController
	if player == null:
		# Fallback for late join: if spawner has not materialized this player yet, create it locally on the client.
		if not multiplayer.is_server() and _player_scene != null:
			var existing := _map.get_node_or_null(str(peer_id)) as PlayerController
			if existing == null:
				var spawned := _player_scene.instantiate() as PlayerController
				spawned.name = str(peer_id)
				spawned.set_multiplayer_authority(1)
				_map.add_child(spawned, true)
				await get_tree().process_frame
		player = _map.get_node_or_null(str(peer_id)) as PlayerController
		if player == null:
			# Player can despawn before setup RPC executes (e.g. match end or disconnect).
			return

	player.reset_for_respawn()
	player.global_position = spawn_position
	player.set_multiplayer_authority(1)
	player.net_sync.sync_server_tick(server_tick)
	player.owner_peer_id = peer_id
	player.team = team
	player.player_input.set_authority(peer_id)

	if NetUtil.has_active_peer(multiplayer) and multiplayer.is_server():
		if MultiplayerSession.is_bot(peer_id):
			player.net_sync.bot_brain = BotBrain.new()
		player.tree_exited.connect(_on_player_tree_exited.bind(peer_id))
		player_setup.emit(peer_id, player)

	if NetUtil.has_active_peer(multiplayer) and peer_id == multiplayer.get_unique_id():
		player.setup_locals()
		MaskViewProvider.viewport.player_camera = player.camera
		MaskViewProvider.viewport.player = player
		var destruction := DestructionService.current(get_tree())
		if destruction != null:
			destruction.request_initial_state()
	for node in get_tree().get_nodes_in_group("Player"):
		var teammate := node as PlayerController
		if teammate != null:
			teammate.apply_team_visuals(MultiplayerSession.get_team(multiplayer.get_unique_id()))

func _on_player_tree_exited(peer_id: int) -> void:
	if not is_inside_tree():
		return
	if not NetUtil.has_active_peer(multiplayer) or not multiplayer.is_server() or not spawning_enabled:
		return
	if peer_id == multiplayer.get_unique_id() or MultiplayerSession.is_peer_connected(peer_id):
		spawn_player(peer_id)
