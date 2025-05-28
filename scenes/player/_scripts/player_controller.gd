extends CharacterBody2D
class_name PlayerController

@export_group("Stats")
@export_range(100, 300) var speed: float = 200
@export_range(0.1, 1) var slow_walk_multiplier := 0.5

@export_group("Components")
@export var hitbox: CollisionShape2D
@export var skeletal_character: PlayerMesh
@export var movement_component: MovementCompoent
@export var health_component: HealthComponent
@export var weapon_manager: WeaponManager
@export var sound_pool: SoundPool
@export var footstep_player: AudioStreamPlayer2D
@export var camera_shake: CameraShake
@export var player_input: PlayerInput

@export var hud: CanvasLayer
@export var camera: Camera2D
@export var audio_listner: AudioListener2D

@export var is_slow_walking := false

var owner_peer_id: int = 1
var is_local: bool = false

func _ready():
	health_component.connect("die", _on_die)
	weapon_manager.connect("weapon_equipped", _on_weapon_equiped)

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
	
	if weapon_manager.current_weapon:
		speed_multiplier *= weapon_manager.current_weapon.data.speed_multiplier

	return speed * speed_multiplier

func _on_die(_killer_id: int):
	if multiplayer.is_server():
		_remote_die.rpc(global_position)


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

	if weapon_manager.current_weapon and not weapon_manager.current_weapon.is_locked:
		if movement_component.is_moving:
			skeletal_character.anim_player.play(weapon_manager.current_weapon.data.animations.get("move", ""))
		else:
			skeletal_character.anim_player.play(weapon_manager.current_weapon.data.animations.get("idle", ""))
	
func _physics_process(_delta: float) -> void:
	pass


func request_start_slow_walk():
	is_slow_walking = true

func request_stop_slow_walk():
	is_slow_walking = false

func request_start_fire():
	if weapon_manager.current_weapon:
		weapon_manager.current_weapon.start_fire()
	
func request_stop_fire():
	if weapon_manager.current_weapon:
		weapon_manager.current_weapon.stop_fire()

func request_reload():
	if weapon_manager.current_weapon:
		weapon_manager.current_weapon.reload()

func request_switch_weapon_next():
	weapon_manager.switch_to_next_weapon()

func request_drop_weapon():
	weapon_manager.drop_weapon()


func _on_weapon_equiped(slot):
	_remote_equip_weapon.rpc(slot)

func pickup_weapon(weapon_pickup: WeaponPickup):
	return weapon_manager.pickup_weapon(weapon_pickup)

@rpc("authority", "reliable")
func _remote_equip_weapon(slot: int):
	weapon_manager.equip_slot(slot)

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
