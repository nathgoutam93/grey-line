extends Node

@export var player_scene: PackedScene
@export var kd_stats_container: VBoxContainer
@export var map: Node2D

@onready var spawn_points := map.get_node("SpawnPoints").get_children()

var player_stats := {} # Format: { peer_id: { "kills": 0, "deaths": 0 } }

func _ready():
	if not multiplayer.is_server():
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.server_disconnected.connect(_on_disconnected)
		multiplayer.connection_failed.connect(_on_connection_failed)
		
		return

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if not OS.has_feature("dedicated_server"):
		spawn_player(1)


func _on_connected():
	print("Connected to server.")

func _on_disconnected():
	print("Disconnected from server.")

func _on_connection_failed():
	print("Failed to connect to server.")


func _on_peer_connected(id: int):
	print("Peer connected: %d" % id)
	spawn_player(id)

func _on_peer_disconnected(id: int):
	print("Peer disconnected: %d" % id)
	player_stats.erase(id)


func register_death(victim_id: int, killer_id: int):
	if not multiplayer.is_server():
		return

	if player_stats.has(victim_id):
		player_stats[victim_id]["deaths"] += 1
	if player_stats.has(killer_id) and killer_id != victim_id:
		player_stats[killer_id]["kills"] += 1

	print("K/D updated:")
	print("Player %d -> Kills: %d, Deaths: %d" % [
		killer_id,
		player_stats.get(killer_id, {}).get("kills", 0),
		player_stats.get(killer_id, {}).get("deaths", 0)
	])

	_update_stats.rpc(player_stats)


@rpc("call_local", "reliable")
func _update_stats(stats: Dictionary):
	kd_stats_container.get_children().map(func(c): c.queue_free())

	for peer_id in stats.keys():
		var player_stat = stats[peer_id]
		var kills = player_stat.get("kills", 0)
		var deaths = player_stat.get("deaths", 0)

		var label = Label.new()
		label.text = "Player %d | Kills: %d | Deaths: %d" % [peer_id, kills, deaths]
		kd_stats_container.add_child(label)


@rpc("reliable")
func get_stats(peer_id: int) -> Dictionary:
	if multiplayer.is_server() and player_stats.has(peer_id):
		return player_stats[peer_id]
	return {}


@rpc("call_local", "reliable")
func _setup_player(peer_id, player_path: NodePath):
	var player = get_node(player_path) as PlayerController
	
	player.owner_peer_id = peer_id

	if player:
		player.player_input.set_authority(peer_id)

		if multiplayer.is_server():
			if not player_stats.has(peer_id):
				player_stats[peer_id] = {"kills": 0, "deaths": 0}
			player.health_component.die.connect(func(killer_id: int): register_death(peer_id, killer_id))
			player.tree_exited.connect(func(): await spawn_player(peer_id))

		if peer_id == multiplayer.get_unique_id():
			player.setup_locals()
			MaskViewProvider.viewport.player_camera = player.camera

# Spawn a player on server, will autospawn on client by MultiplayerSpawner Node
func spawn_player(peer_id: int):
	var spawn_point = spawn_points.pick_random()

	var player_instance = player_scene.instantiate()
	player_instance.name = str(peer_id)
	player_instance.position = spawn_point.global_position

	map.add_child.call_deferred(player_instance, true)
	
	print("Spawned player for peer %d at %s" % [peer_id, spawn_point.global_position])

	await get_tree().create_timer(1).timeout
	rpc("_setup_player", peer_id, player_instance.get_path())
	

func _exit_tree() -> void:
	if not multiplayer.is_server():
		return

	multiplayer.peer_connected.disconnect(_on_peer_connected)
	multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
