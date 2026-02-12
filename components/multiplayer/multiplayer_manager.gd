extends Node

@export var port: int = 3000
@export var max_players: int = 8
@export var address: String = "127.0.0.1"

@onready var level: Node2D = get_node("../Level")
@onready var ui_layer: CanvasLayer = get_node("../UI")
@onready var hostname_input: LineEdit = get_node_or_null("../UI/Control/hostname")

func _ready():
	if OS.has_feature("dedicated_server"):
		host_game()


func host_game():
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port, max_players)
	if error != OK:
		push_error("Failed to start server: %s" % error)
		return

	multiplayer.multiplayer_peer = peer
	print("Hosting game on port %d..." % port)
	
	_start_game()

func join_game():
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
