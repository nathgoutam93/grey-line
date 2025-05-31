extends RigidBody2D
class_name WeaponPickup

@export var REST_THRESHOLD = 0.2

var weapon_data: Weapon
var ammo_in_mag := 0

@export var interactable_component: Interactable

func _ready():
	await get_tree().create_timer(REST_THRESHOLD).timeout
	interactable_component.player_entered.connect(_on_player_entered)
	interactable_component.player_exited.connect(_on_player_exited)
	freeze = true

@rpc("authority", "call_local")
func initialize_weapon(data: Dictionary, ammo: int):
	await get_tree().process_frame
	weapon_data = Weapon.new_from_dict(data)
	ammo_in_mag = ammo


func set_weapon_data(data: Weapon):
	weapon_data = data

func _on_player_entered(player):
	if can_auto_pickup(player):
		pickup_weapon(player)
	else:
		show_message("press f to pickup")

func _on_player_exited(_player):
	pass

func can_auto_pickup(player):
	var existing_weapon = player.weapon_manager.get_weapon_in_slot(weapon_data.weapon_type)
	return existing_weapon == null

func pickup_weapon(player):
	player.pickup_weapon.rpc_id(1, get_path())

func show_message(text):
	print(text)

func on_interact(player):
	pickup_weapon(player)
