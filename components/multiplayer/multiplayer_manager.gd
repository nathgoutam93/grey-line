extends Node

@export var port: int = 3000
@export var max_players: int = 8
@export var address: String = "127.0.0.1"

@onready var level: Node2D = get_node("../Level")
@onready var ui_layer: CanvasLayer = get_node("../UI")
@onready var hostname_input: LineEdit = get_node_or_null("../UI/Control/hostname")
@onready var player_name_input: LineEdit = get_node_or_null("../UI/Control/player_name")

var local_player_name := ""
var player_names := {}

func _ready():
	add_to_group("multiplayer_manager")

	local_player_name = _resolve_local_player_name()
	if player_name_input and player_name_input.text.strip_edges() == "":
		player_name_input.text = local_player_name

	multiplayer.connected_to_server.connect(_on_connected_to_server)

	if OS.has_feature("dedicated_server"):
		local_player_name = "DedicatedServer"
		host_game()


func host_game():
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port, max_players)
	if error != OK:
		push_error("Failed to start server: %s" % error)
		return

	multiplayer.multiplayer_peer = peer
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	local_player_name = _resolve_local_player_name()
	_set_player_name_for_peer(multiplayer.get_unique_id(), local_player_name)
	print("Hosting game on port %d..." % port)
	
	_start_game()

func join_game():
	local_player_name = _resolve_local_player_name()
	var target_address := _get_target_address()
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(target_address, port)
	if error != OK:
		push_error("Failed to connect to server: %s" % error)
		return

	multiplayer.multiplayer_peer = peer
	print("Connecting to server at %s:%d..." % [target_address, port])

	_start_game()

func _get_target_address() -> String:
	if hostname_input:
		var input_address := hostname_input.text.strip_edges()
		if input_address != "":
			return input_address

	return address

func _on_connected_to_server() -> void:
	rpc_id(1, "_register_player_name", local_player_name)

func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		player_names.erase(id)

@rpc("any_peer", "reliable")
func _register_player_name(raw_name: String) -> void:
	if not multiplayer.is_server():
		return

	var peer_id := multiplayer.get_remote_sender_id()
	var resolved_name := _sanitize_player_name(raw_name, peer_id)
	_set_player_name_for_peer(peer_id, resolved_name)

func get_player_name(peer_id: int) -> String:
	return String(player_names.get(peer_id, "Player %d" % peer_id))

func _set_player_name_for_peer(peer_id: int, raw_name: String) -> void:
	player_names[peer_id] = _sanitize_player_name(raw_name, peer_id)

func _resolve_local_player_name() -> String:
	var raw_name := ""
	if player_name_input:
		raw_name = player_name_input.text
	elif OS.has_feature("dedicated_server"):
		raw_name = "DedicatedServer"
	else:
		raw_name = OS.get_environment("USER")
	if raw_name.strip_edges() == "":
		raw_name = "Player"
	return _sanitize_player_name(raw_name, multiplayer.get_unique_id())

func _sanitize_player_name(raw_name: String, peer_id: int) -> String:
	var cleaned := raw_name.strip_edges()
	if cleaned == "":
		cleaned = "Player %d" % peer_id
	return cleaned.substr(0, 24)

func _start_game():
	if ui_layer:
		ui_layer.hide()

	if multiplayer.is_server():
		_change_level.call_deferred(load("res://scenes/maps/counter_strike/counter_strike.tscn"))

func _change_level(scene: PackedScene):
	for c in level.get_children():
		level.remove_child(c)
		c.queue_free()

	level.add_child(scene.instantiate())
