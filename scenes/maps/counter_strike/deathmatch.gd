extends Node

@export var player_scene: PackedScene
@onready var spawn_points = get_node("../SpawnPoints").get_children()

func _ready():
	# spawn_all_players()w
	pass

func spawn_all_players():
	# For example, spawning 4 players
	for i in range(4):
		spawn_player(i)

func spawn_player(player_id: int):
	if spawn_points.is_empty():
		push_error("No spawn points defined!")
		return

	var spawn_point = spawn_points[randi() % spawn_points.size()]
	var player = player_scene.instantiate()
	player.position = spawn_point.global_position
	player.name = "Player_%d" % player_id
	player.player_id = player_id # optional, if you want to track it
	add_child(player)

	player.died.connect(_on_player_died.bind(player_id))

func _on_player_died(player_id: int):
	await get_tree().create_timer(2.0).timeout # Wait before respawn
	spawn_player(player_id)
