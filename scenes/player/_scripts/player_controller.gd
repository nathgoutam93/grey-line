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

var interactables: Array[Interactable]
var is_dead := false

func has_authority(id):
	return id == get_multiplayer_authority() or id == owner_peer_id

func _is_valid_owner_request() -> bool:
	if not multiplayer.is_server():
		return false
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = multiplayer.get_unique_id()
	return sender_id == owner_peer_id

func _ready():
	if health_component and not health_component.is_connected("die", _on_die):
		health_component.connect("die", _on_die)

func setup_locals():
	camera.enabled = true
	camera.make_current()
	audio_listner.make_current()
	hud.visible = true
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

	if weapon_manager and weapon_manager.current_weapon and not weapon_manager.current_weapon.is_locked:
		if movement_component.is_moving:
			skeletal_character.anim_player.play(weapon_manager.current_weapon.data.animations.get("move", ""))
		else:
			skeletal_character.anim_player.play(weapon_manager.current_weapon.data.animations.get("idle", ""))
	
func _physics_process(_delta: float) -> void:
	pass


func add_interactable(item: Interactable):
	interactables.append(item)

func remove_interactable(item: Interactable):
	interactables.erase(item)

@rpc("any_peer", "call_local")
func pickup_weapon(pickup_path: NodePath):
	if not _is_valid_owner_request():
		return

	_remote_pickup.rpc(pickup_path)

@rpc("any_peer", "call_local")
func request_start_slow_walk():
	if not _is_valid_owner_request():
		return

	is_slow_walking = true

@rpc("any_peer", "call_local")
func request_stop_slow_walk():
	if not _is_valid_owner_request():
		return

	is_slow_walking = false

@rpc("any_peer", "call_local")
func request_start_fire():
	if not _is_valid_owner_request():
		return

	_remote_start_fire.rpc()
	
@rpc("any_peer", "call_local")
func request_stop_fire():
	if not _is_valid_owner_request():
		return

	_remote_stop_fire.rpc()

@rpc("any_peer", "call_local")
func request_reload():
	if not _is_valid_owner_request():
		return

	_remote_reload.rpc()

@rpc("any_peer", "call_local")
func request_switch_weapon_next():
	if not _is_valid_owner_request():
		return

	_remote_switch_weapon.rpc()

@rpc("any_peer", "call_local")
func request_drop_weapon():
	if not _is_valid_owner_request():
		return

	_remote_drop_weapon.rpc()

@rpc("any_peer", "call_local")
func request_interact():
	if not _is_valid_owner_request():
		return

	var target_path: NodePath = NodePath("")
	if interactables.size() > 0 and interactables[0]:
		target_path = interactables[0].get_path()
	remote_interact.rpc(target_path)


@rpc("authority", "call_local")
func remote_interact(target_path: NodePath):
	if target_path == NodePath(""):
		return
	var interactable = get_node_or_null(target_path)
	if interactable and interactable.owner_ref and interactable.owner_ref.has_method("on_interact"):
		interactable.owner_ref.on_interact(self)

@rpc("authority", "call_local", "reliable")
func _remote_start_fire():
	if weapon_manager.current_weapon:
		weapon_manager.current_weapon.start_fire()

@rpc("authority", "call_local", "reliable")
func _remote_stop_fire():
	if weapon_manager.current_weapon:
		weapon_manager.current_weapon.stop_fire()

@rpc("authority", "call_local", "reliable")
func _remote_reload():
	if weapon_manager.current_weapon:
		weapon_manager.current_weapon.reload()

@rpc("authority", "call_local", "reliable")
func _remote_switch_weapon():
	weapon_manager.switch_to_next_weapon()

@rpc("authority", "call_local", "reliable")
func _remote_drop_weapon():
	weapon_manager.drop_weapon()

@rpc("authority", "call_local", "reliable")
func _remote_pickup(pickup_path: NodePath):
	var weapon_pickup = get_node(pickup_path)
	if (weapon_manager.pickup_weapon(weapon_pickup)):
		weapon_pickup.queue_free()

@rpc("authority", "call_local", "reliable")
func _remote_die(global_pos: Vector2):
	is_dead = true
	hitbox.disabled = true
	player_input.set_process(false)
	set_process(false)
	set_physics_process(false)
	if movement_component:
		movement_component.set_process(false)
		movement_component.set_physics_process(false)
		movement_component.is_moving = false
	velocity = Vector2.ZERO
	if footstep_player.playing:
		footstep_player.stop()
	if weapon_manager and weapon_manager.current_weapon:
		if weapon_manager.current_weapon.has_method("force_interrupt"):
			weapon_manager.current_weapon.force_interrupt()
		weapon_manager.current_weapon.stop_fire()
	hide()

	var dead_scene = preload("res://scenes/player/player_dead.tscn").instantiate()
	dead_scene.global_position = global_pos
	get_tree().current_scene.add_child(dead_scene)

	await get_tree().create_timer(5).timeout
	queue_free()
