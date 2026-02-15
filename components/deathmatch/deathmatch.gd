extends Node

@export var player_scene: PackedScene
@export var leaderboard: DeathmatchLeaderboard
@export var map: Node2D

@onready var spawn_points := map.get_node("SpawnPoints").get_children()

var player_stats := {} # Format: { peer_id: { "kills": 0, "deaths": 0 } }
var stats_refresh_elapsed := 0.0
const STATS_REFRESH_INTERVAL := 0.35

func _ready():
	if is_instance_valid(leaderboard):
		leaderboard.visible = false

	if not multiplayer.is_server():
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.server_disconnected.connect(_on_disconnected)
		multiplayer.connection_failed.connect(_on_connection_failed)
		
		return

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if not OS.has_feature("dedicated_server"):
		spawn_player(1)


func _process(delta: float) -> void:
	if is_instance_valid(leaderboard):
		leaderboard.visible = Input.is_action_pressed("stats")

	if not multiplayer.is_server():
		return

	stats_refresh_elapsed += delta
	if stats_refresh_elapsed < STATS_REFRESH_INTERVAL:
		return

	stats_refresh_elapsed = 0.0
	if _refresh_all_player_combat_data():
		_update_stats.rpc(player_stats)


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
	_update_stats.rpc(player_stats)


func register_death(victim_id: int, killer_id: int):
	if not multiplayer.is_server():
		return

	if player_stats.has(victim_id):
		player_stats[victim_id]["deaths"] += 1
	if player_stats.has(killer_id) and killer_id != victim_id:
		player_stats[killer_id]["kills"] += 1
	_refresh_player_combat_data(victim_id)
	_refresh_player_combat_data(killer_id)

	print("K/D updated:")
	print("Player %d -> Kills: %d, Deaths: %d" % [
		killer_id,
		player_stats.get(killer_id, {}).get("kills", 0),
		player_stats.get(killer_id, {}).get("deaths", 0)
	])

	_update_stats.rpc(player_stats)


@rpc("call_local", "reliable")
func _update_stats(stats: Dictionary):
	if not is_instance_valid(leaderboard):
		return

	leaderboard.populate_leaderboard(stats)


@rpc("reliable")
func get_stats(peer_id: int) -> Dictionary:
	if multiplayer.is_server() and player_stats.has(peer_id):
		_refresh_player_combat_data(peer_id)
		return player_stats[peer_id]
	return {}


@rpc("call_local", "reliable")
func _setup_player(peer_id, player_path: NodePath):
	await get_tree().process_frame
	var player = get_node(player_path) as PlayerController

	if player:
		player.owner_peer_id = peer_id
		player.player_input.set_authority(peer_id)

		if multiplayer.is_server():
			if not player_stats.has(peer_id):
				player_stats[peer_id] = _new_player_stats(peer_id)
			_refresh_player_combat_data(peer_id, player)
			_update_stats.rpc(player_stats)
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
	player_instance.ready.connect(func(): rpc("_setup_player", peer_id, player_instance.get_path()))

func _exit_tree() -> void:
	if not multiplayer.is_server():
		return

	multiplayer.peer_connected.disconnect(_on_peer_connected)
	multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)


func _new_player_stats(peer_id: int) -> Dictionary:
	return {
		"player_identifier": _player_identifier(peer_id),
		"kills": 0,
		"deaths": 0,
		"loadout": {},
		"current_weapon": {}
	}

func _slot_name(slot: int) -> String:
	match slot:
		WeaponManager.WeaponSlot.PRIMARY:
			return "primary"
		WeaponManager.WeaponSlot.SECONDARY:
			return "secondary"
		WeaponManager.WeaponSlot.MELEE:
			return "melee"
		_:
			return "unknown"

func _weapon_payload(weapon: WeaponInstance) -> Dictionary:
	if weapon == null or weapon.data == null:
		return {}
	return {
		"name": weapon.data.name,
		"slot": _slot_name(weapon.data.weapon_type),
		"ammo_in_mag": weapon.ammo_in_mag,
		"ammo_reserve": weapon.ammo_reserve,
		"mag_size": weapon.data.mag_size,
		"uses_ammo": weapon.data.uses_ammo
	}

func _refresh_player_combat_data(peer_id: int, player: PlayerController = null) -> bool:
	if not multiplayer.is_server():
		return false

	if not player_stats.has(peer_id):
		player_stats[peer_id] = _new_player_stats(peer_id)

	if player == null:
		player = map.get_node_or_null(str(peer_id)) as PlayerController

	var loadout_payload := {}
	var current_weapon_payload := {}

	if player and player.weapon_manager:
		var weapon_manager := player.weapon_manager
		current_weapon_payload = _weapon_payload(weapon_manager.current_weapon)
		if not current_weapon_payload.is_empty():
			current_weapon_payload["slot"] = _slot_name(weapon_manager.current_slot)
			loadout_payload = current_weapon_payload.duplicate(true)

	var stats: Dictionary = player_stats[peer_id]
	var has_changed := false
	var identifier := _player_identifier(peer_id)

	if stats.get("player_identifier", "") != identifier:
		stats["player_identifier"] = identifier
		has_changed = true
	if stats.get("loadout", {}) != loadout_payload:
		stats["loadout"] = loadout_payload
		has_changed = true
	if stats.get("current_weapon", {}) != current_weapon_payload:
		stats["current_weapon"] = current_weapon_payload
		has_changed = true

	player_stats[peer_id] = stats
	return has_changed

func _refresh_all_player_combat_data() -> bool:
	var has_any_change := false
	for peer_id in player_stats.keys():
		if _refresh_player_combat_data(int(peer_id)):
			has_any_change = true
	return has_any_change

func _player_identifier(peer_id: int) -> String:
	var multiplayer_manager := _get_multiplayer_manager()
	if multiplayer_manager and multiplayer_manager.has_method("get_player_name"):
		var player_name := String(multiplayer_manager.get_player_name(peer_id)).strip_edges()
		if player_name != "":
			return player_name
	return str(peer_id)

func _get_multiplayer_manager() -> Node:
	var nodes := get_tree().get_nodes_in_group("multiplayer_manager")
	if nodes.is_empty():
		return null
	return nodes[0]
