extends RigidBody2D
class_name WeaponPickup

@export var REST_THRESHOLD = 0.2

var weapon_data: Weapon
var ammo_in_mag := 0
var _weapon_data_dict: Dictionary = {}
var weapon_data_dict: Dictionary:
	get:
		return _weapon_data_dict
	set(value):
		_weapon_data_dict = value
		if weapon_data == null and not _weapon_data_dict.is_empty():
			weapon_data = Weapon.new_from_dict(_weapon_data_dict)

@export var interactable_component: Interactable

func _ready():
	await get_tree().create_timer(REST_THRESHOLD).timeout
	if weapon_data == null and not _weapon_data_dict.is_empty():
		weapon_data = Weapon.new_from_dict(_weapon_data_dict)
	interactable_component.player_entered.connect(_on_player_entered)
	interactable_component.player_exited.connect(_on_player_exited)
	freeze = true

@rpc("authority", "call_local")
func initialize_weapon(data: Dictionary, ammo: int):
	await get_tree().process_frame
	weapon_data_dict = data
	weapon_data = Weapon.new_from_dict(data)
	ammo_in_mag = ammo


func set_weapon_data(data: Weapon):
	weapon_data_dict = data.to_dict()
	weapon_data = data

func _on_player_entered(player):
	if not multiplayer.is_server():
		return
	if can_auto_pickup(player):
		pickup_weapon(player)
	else:
		show_message("press f to pickup")

func _on_player_exited(_player):
	pass

func can_auto_pickup(player):
	if weapon_data == null:
		return false
	var existing_weapon = player.weapon_manager.get_weapon_in_slot(weapon_data.weapon_type)
	return existing_weapon == null

func pickup_weapon(player):
	if not multiplayer.is_server():
		return

	var pickup_path: NodePath = get_path()
	var scene_root := get_tree().current_scene
	if scene_root:
		var map_node := scene_root.find_child("Map", true, false)
		if map_node and map_node.is_ancestor_of(self):
			pickup_path = map_node.get_path_to(self)

	player._remote_pickup.rpc(pickup_path)

func show_message(text):
	print(text)

func on_interact(player):
	pickup_weapon(player)
