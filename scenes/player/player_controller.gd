extends CharacterBody2D
class_name PlayerController

@export_group("Stats")
@export_range(100, 300) var speed: float = 200
@export_range(0.1, 1) var slow_walk_multiplier := 0.5

@export_group("Inventory")
@export var default_weapons: Array[Weapon] = []

@export_group("Components")
@export var skeletal_character: PlayerMesh
@export var movement_component: MovementCompoent
@export var health_component: HealthComponent
@export var sound_pool: SoundPool
@export var footstep_player: AudioStreamPlayer2D
@export var camera_shake: CameraShake

@export var is_remote: bool = false

var weapon_inventory: Array[WeaponInstance] = []
var current_weapon: WeaponInstance
var current_weapon_index := 0

var slow_walking := false

func _ready():
	_setup_weapons()

	if not is_remote:
		get_node("Camera2D").enabled = true

		skeletal_character.material = null

	if is_remote:
		movement_component.set_process(false)
		movement_component.set_physics_process(false)

	health_component.connect("die", _on_die)


func get_speed():
	var speed_multiplier = 1

	if slow_walking:
		speed_multiplier *= slow_walk_multiplier
	
	if current_weapon:
		speed_multiplier *= current_weapon.data.speed_multiplier

	return speed * speed_multiplier


func _on_die():
	queue_free()

func _setup_weapons():
	for w in default_weapons:
		var weapon_instance = WeaponInstance.new(w)
		add_child(weapon_instance)
		weapon_inventory.append(weapon_instance)
	if weapon_inventory.size() > 0:
		_equip_weapon(weapon_inventory[0])

func _equip_weapon(new_weapon: WeaponInstance):
	if current_weapon:
		current_weapon.disconnect("equip_action", _on_weapon_equip_action)
		current_weapon.disconnect("shoot_action", _on_weapon_shoot_action)
		current_weapon.disconnect("reload_action", _on_weapon_reload_action)
		current_weapon.unequip()

	current_weapon = new_weapon

	current_weapon.connect("equip_action", _on_weapon_equip_action)
	current_weapon.connect("shoot_action", _on_weapon_shoot_action)
	current_weapon.connect("reload_action", _on_weapon_reload_action)
	current_weapon.equip(skeletal_character.hand_socket)


func switch_to_next_weapon():
	if weapon_inventory.size() == 0:
		return
	
	current_weapon.force_interrupt()

	current_weapon_index = (current_weapon_index + 1) % weapon_inventory.size()
	_equip_weapon(weapon_inventory[current_weapon_index])

func switch_to_previous_weapon():
	if weapon_inventory.size() == 0:
		return
	
	current_weapon.force_interrupt()
	
	current_weapon_index = (current_weapon_index - 1 + weapon_inventory.size()) % weapon_inventory.size()
	_equip_weapon(weapon_inventory[current_weapon_index])


func _on_weapon_shoot_action(animation_name: String, _sound_stream: AudioStream):
	skeletal_character.anim_player.play(animation_name)
	camera_shake.apply(current_weapon.data.camera_shake_strength)

func _on_weapon_reload_action(animation_name: String, _sound_stream: AudioStream):
	skeletal_character.anim_player.play(animation_name)

func _on_weapon_equip_action(animation_name: String, _sound_stream: AudioStream):
	skeletal_character.anim_player.play(animation_name)


func _process(_delta: float) -> void:
	if slow_walking:
		footstep_player.volume_db = -40.0
	else:
		footstep_player.volume_db = -10.0

	if not current_weapon.is_locked:
		if movement_component.is_moving:
			skeletal_character.anim_player.play(current_weapon.data.animations.get("move", ""))
		else:
			skeletal_character.anim_player.play(current_weapon.data.animations.get("idle", ""))
	
	if movement_component.is_moving:
		if not footstep_player.playing:
			footstep_player.play();
	else:
		if footstep_player.playing:
			footstep_player.stop();

func _physics_process(_delta: float) -> void:
	if is_remote:
		return
	
	slow_walking = Input.is_action_pressed("slow_walk")

	if current_weapon:
		if Input.is_action_just_pressed("shoot") or Input.is_action_pressed("shoot"):
			current_weapon.start_fire()
		
		if Input.is_action_just_released("shoot"):
			current_weapon.stop_fire()

		if Input.is_action_just_pressed("reload"):
			current_weapon.reload()

		if Input.is_action_just_pressed("drop_smoke"):
			switch_to_next_weapon()
