extends CharacterBody2D
class_name PlayerController

@export_group("Stats")
@export_range(100, 300) var speed: float = 200
@export_range(0.1, 1) var slow_walk_multiplier := 0.5

@export_group("Inventory")
@export var default_weapons: Array[PackedScene] = []

@export_group("Components")
@export var hitbox: CollisionShape2D
@export var skeletal_character: PlayerMesh
@export var movement_component: MovementCompoent
@export var health_component: HealthComponent
@export var sound_pool: SoundPool
@export var footstep_player: AudioStreamPlayer2D
@export var camera_shake: CameraShake

@export var hud: CanvasLayer

@export var camera: Camera2D
@export var audio_listner: AudioListener2D

@export var player_input: PlayerInput

var weapon_inventory: Array[WeaponInstance]
var current_weapon: WeaponInstance
var current_weapon_index := 0

@export var is_slow_walking := false

var owner_peer_id: int = 1
var is_local: bool = false

func _ready():
	_setup_weapons()
	health_component.connect("die", _on_die)

func setup_locals():
	is_local = true

	camera.enabled = true
	camera.make_current()
	audio_listner.make_current()
	hud.visible = true
	# remove FOW shader from own body
	skeletal_character.material = null

func get_speed():
	var speed_multiplier = 1

	if is_slow_walking:
		speed_multiplier *= slow_walk_multiplier
	
	if current_weapon:
		speed_multiplier *= current_weapon.data.speed_multiplier

	return speed * speed_multiplier

func _on_die(_killer_id: int):
	if multiplayer.is_server():
		_remote_die.rpc(global_position)

func _setup_weapons():
	if default_weapons.size() > 0:
		for w in default_weapons:
			var wi = w.instantiate()
			wi.player = self
			skeletal_character.hand_socket.add_child(wi)
			weapon_inventory.append(wi)
			wi.unequip()

	if weapon_inventory.size() > 0:
		_equip_weapon(weapon_inventory[current_weapon_index])

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

	_remote_equip_weapon.rpc(current_weapon_index)

func switch_to_previous_weapon():
	if weapon_inventory.size() == 0:
		return
	
	current_weapon.force_interrupt()
	
	current_weapon_index = (current_weapon_index - 1 + weapon_inventory.size()) % weapon_inventory.size()
	_equip_weapon(weapon_inventory[current_weapon_index])

	_remote_equip_weapon.rpc(current_weapon_index)


func _on_weapon_shoot_action(animation_name: String, _sound_stream: AudioStream):
	if multiplayer.is_server():
		_play_shoot_animation_for_all.rpc(animation_name)

func _on_weapon_reload_action(animation_name: String, _sound_stream: AudioStream):
	if multiplayer.is_server():
		_play_reload_animation_for_all.rpc(animation_name)

func _on_weapon_equip_action(animation_name: String, _sound_stream: AudioStream):
	if multiplayer.is_server():
		_play_equip_animation_for_all.rpc(animation_name)


func _process(_delta: float) -> void:
	if is_slow_walking:
		footstep_player.volume_db = -40.0
	else:
		footstep_player.volume_db = -10.0

	if movement_component.is_moving:
		if not footstep_player.playing:
			footstep_player.play();
	else:
		if footstep_player.playing:
			footstep_player.stop();

	if not current_weapon.is_locked:
		if movement_component.is_moving:
			skeletal_character.anim_player.play(current_weapon.data.animations.get("move", ""))
		else:
			skeletal_character.anim_player.play(current_weapon.data.animations.get("idle", ""))
	
func _physics_process(_delta: float) -> void:
	pass


func request_start_slow_walk():
	is_slow_walking = true

func request_stop_slow_walk():
	is_slow_walking = false

func request_start_fire():
	if current_weapon:
		current_weapon.start_fire()
	
func request_stop_fire():
	if current_weapon:
		current_weapon.stop_fire()

func request_reload():
	if current_weapon:
		current_weapon.reload()

func request_switch_weapon_next():
	switch_to_next_weapon()


@rpc("authority", "call_local", "reliable")
func _play_reload_animation_for_all(animation_name: String):
	skeletal_character.anim_player.play(animation_name)

@rpc("authority", "call_local", "reliable")
func _play_shoot_animation_for_all(animation_name: String):
	skeletal_character.anim_player.play(animation_name)
	camera_shake.apply(current_weapon.data.camera_shake_strength)

@rpc("authority", "call_local", "reliable")
func _play_equip_animation_for_all(animation_name: String):
	skeletal_character.anim_player.play(animation_name)

@rpc("authority", "reliable")
func _remote_equip_weapon(index: int):
	current_weapon_index = index
	_equip_weapon(weapon_inventory[current_weapon_index])

@rpc("authority", "call_local", "reliable")
func _remote_die(global_pos: Vector2):
	hitbox.disabled = true
	player_input.set_process(false)
	hide()

	var dead_scene = preload("res://scenes/player/player_dead.tscn").instantiate()
	dead_scene.global_position = global_pos
	get_tree().current_scene.add_child(dead_scene)

	await get_tree().create_timer(5).timeout
	queue_free()
