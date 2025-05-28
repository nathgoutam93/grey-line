extends RigidBody2D
class_name WeaponPickup

@export var REST_THRESHOLD = 0.2


var player_in_range = false
var player_ref = null

var weapon_data: Weapon
var ammo_in_mag := 0

func _ready():
	await get_tree().create_timer(REST_THRESHOLD).timeout
	$Area2D.body_entered.connect(_on_body_entered)
	$Area2D.body_exited.connect(_on_body_exited)
	
	freeze = true

func set_weapon_data(data: Weapon):
	weapon_data = data

func _on_body_entered(body):
	if body.is_in_group("Player"):
		player_ref = body
		player_in_range = true

		if can_auto_pickup():
			pickup_weapon()
		else:
			show_message("press f to pickup")
		

func _on_body_exited(body):
	if body == player_ref:
		player_ref = null
		player_in_range = false

func _process(_delta):
	if player_in_range and Input.is_action_just_pressed("pickup"):
		pickup_weapon()

func can_auto_pickup():
	var existing_weapon = player_ref.weapon_manager.get_weapon_in_slot(weapon_data.weapon_type)
	return existing_weapon == null # Allow auto pickup only if slot free

func pickup_weapon():
	player_ref.pickup_weapon(self)
	queue_free()

func show_message(text):
	print(text)
	pass
