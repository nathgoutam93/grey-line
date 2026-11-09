extends CharacterBody2D
class_name PlayerController

enum ShotIntent {
	BODY,
	HEAD
}

@export_group("Stats")
@export_range(100, 300) var speed: float = 300
@export_range(0.1, 1) var slow_walk_multiplier := 0.5
@export var mouse_turn_sensitivity: float = 0.01
@export var camera_boom_distance: float = 350.0
@export var camera_rotates_with_player: bool = true

@export_group("Components")
@export var crosshair: Crosshair
@export var headHurtBox: Area2D
@export var bodyHurtBox: Area2D
@export var skeletal_character: PlayerMesh
@export var player_input: PlayerInputCollector
@export var movement_component: MovementCompoent
@export var health_component: HealthComponent
@export var equipment_manager: EquipmentManager
@export var sound_pool: SoundPool
@export var footstep_player: AudioStreamPlayer2D
@export var camera_shake: CameraShake

@export var net_sync: PlayerNetSync

@export var hud: PlayerHud
@export var camera: Camera2D
@export var audio_listner: AudioListener2D

@export var is_slow_walking := false

var owner_peer_id: int = 1
var team: int = Teams.NONE
var current_shot_intent: int = ShotIntent.BODY

var interactables: Array[Interactable]
var is_dead := false
var is_local_player := false
var actions_locked := false:
	set(value):
		if actions_locked == value:
			return
		actions_locked = value
		if value:
			velocity = Vector2.ZERO
			if movement_component != null:
				movement_component.external_velocity = Vector2.ZERO
				movement_component.is_moving = false
			if equipment_manager != null:
				for item in equipment_manager.equipped_items.values():
					var equipment := item as EquipmentInstance
					if equipment != null:
						equipment.force_interrupt()
			if net_sync != null:
				net_sync.cancel_locked_actions()

var _death_sequence_id := 0
var _fog_material: Material
const DEATH_DESPAWN_DELAY_SECONDS := 5.0
const RPC_CHANNEL_UI := 2

var _last_footstep_position := Vector2.ZERO
# Decided once per network tick: positions only change on ticks, so measuring
# per rendered frame (faster than 60 Hz) saw zero movement most frames and
# kept stopping/restarting remote players' footsteps.
var _footstep_moving := false
const FOOTSTEP_SPEED_THRESHOLD := 40.0

func _ready():
	if skeletal_character != null:
		_fog_material = skeletal_character.material
	if health_component and not health_component.is_connected("die", _on_die):
		health_component.connect("die", _on_die)

	if camera:
		camera.ignore_rotation = not camera_rotates_with_player
		camera.offset = Vector2.ZERO
		camera.position = Vector2(camera_boom_distance, 0.0)

	# NetSync (a child) connected first, so this runs after the tick's
	# movement has been applied.
	if not NetworkTick.tick_started.is_connected(_on_network_tick):
		NetworkTick.tick_started.connect(_on_network_tick)
	_last_footstep_position = global_position
func setup_locals():
	is_local_player = true
	Input.emulate_mouse_from_touch = false
	camera.enabled = true
	camera.make_current()
	audio_listner.make_current()
	hud.visible = true
	skeletal_character.material = null
	if player_input:
		player_input.on_local_player_spawned()
	if equipment_manager:
		equipment_manager.apply_local_view()


func get_current_equipment() -> EquipmentInstance:
	if equipment_manager == null:
		return null
	return equipment_manager.get_current_item()

func apply_team_visuals(local_team: int) -> void:
	if skeletal_character == null:
		return
	var local := owner_peer_id == multiplayer.get_unique_id()
	var teammate := not local and team != Teams.NONE and team == local_team
	skeletal_character.material = null if local or teammate else _fog_material
	var tint: Color = Teams.COLORS.get(team, Color.WHITE)
	skeletal_character.modulate = tint.lerp(Color.WHITE, 0.6) if teammate else Color.WHITE


func get_speed() -> float:
	var speed_multiplier := 1.0

	if is_slow_walking:
		speed_multiplier *= slow_walk_multiplier
	
	var weapon := get_current_equipment() as WeaponInstance
	if weapon:
		speed_multiplier *= weapon.data.speed_multiplier

	return speed * speed_multiplier

func _on_die(_killer_id: int):
	if multiplayer.is_server():
		_remote_die.rpc(global_position)


func _process(_delta: float) -> void:
	if crosshair:
		var spread_velocity := velocity
		if is_local_player and is_instance_valid(player_input):
			spread_velocity = player_input.input_vector * get_speed()
		crosshair.player_velocity = spread_velocity
	if camera and audio_listner:
		audio_listner.rotation = -camera.rotation
	_update_footstep_audio(_delta)

	var is_moving_now := false
	if movement_component != null:
		is_moving_now = movement_component.is_moving
	else:
		is_moving_now = velocity.length_squared() > 0.01
	_update_item_animation(is_moving_now)

func _update_item_animation(is_moving_now: bool) -> void:
	if skeletal_character == null or skeletal_character.anim_player == null:
		return
	skeletal_character.update_leg_animation(is_moving_now)
	var current_item = get_current_equipment()
	if current_item and current_item is WeaponInstance:
		var weapon = current_item as WeaponInstance
		if weapon.can_play_idle_animation():
			var anim_key := "move" if is_moving_now else "idle"
			var anim_name := String(weapon.data.animations.get(anim_key, ""))
			_play_equipment_animation(anim_name)
	elif current_item and current_item.equipment_data != null and not current_item.is_locked:
		var anim_key := "move" if is_moving_now else "idle"
		var anim_name := String(current_item.equipment_data.animations.get(anim_key, ""))
		_play_equipment_animation(anim_name)

func _play_equipment_animation(anim_name: String) -> void:
	if anim_name == "":
		return
	if not skeletal_character.anim_player.has_animation(anim_name):
		return
	if skeletal_character.anim_player.current_animation == anim_name:
		return
	skeletal_character.anim_player.play(anim_name)

func _update_footstep_audio(delta: float) -> void:
	if footstep_player == null:
		return
	if delta <= 0.0:
		return

	var is_moving_now := false
	if net_sync != null and net_sync.is_proxy():
		is_moving_now = _footstep_moving and net_sync.net_footsteps
	else:
		is_moving_now = (_footstep_moving or (movement_component != null and movement_component.is_moving)) and not is_slow_walking
	if is_dead:
		is_moving_now = false

	if is_moving_now:
		if not footstep_player.playing:
			footstep_player.play()
		return
	if footstep_player.playing:
		footstep_player.stop()

func _on_network_tick(_tick: int) -> void:
	if is_dead:
		return
	_update_footstep_motion()

func _update_footstep_motion() -> void:
	var moved_speed := global_position.distance_to(_last_footstep_position) * float(NetworkTick.tick_rate)
	_last_footstep_position = global_position
	_footstep_moving = moved_speed > FOOTSTEP_SPEED_THRESHOLD

## Call after teleporting the player so the jump is not heard as footsteps.
func reset_footstep_tracking() -> void:
	_last_footstep_position = global_position

func can_register_hit(is_head_hit: bool) -> bool:
	if current_shot_intent == ShotIntent.HEAD:
		return is_head_hit
	return not is_head_hit

func add_interactable(item: Interactable):
	interactables.append(item)

func remove_interactable(item: Interactable):
	interactables.erase(item)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_die(global_pos: Vector2):
	_death_sequence_id += 1
	var death_sequence := _death_sequence_id
	is_dead = true
	_disable_hurtbox(headHurtBox)
	_disable_hurtbox(bodyHurtBox)
	if player_input:
		player_input.set_process(false)
		player_input.set_process_input(false)
	set_process(false)
	set_physics_process(false)
	if movement_component:
		movement_component.set_process(false)
		movement_component.set_physics_process(false)
		movement_component.is_moving = false
		movement_component.external_velocity = Vector2.ZERO
	velocity = Vector2.ZERO
	if footstep_player.playing:
		footstep_player.stop()
	var current_item := get_current_equipment()
	if current_item:
		current_item.force_interrupt()
		current_item.stop_use()
	hide()

	var dead_scene = preload("res://scenes/player/player_dead.tscn").instantiate()
	dead_scene.global_position = global_pos
	get_tree().current_scene.add_child(dead_scene)

	var despawn_ticks := maxi(1, int(round(DEATH_DESPAWN_DELAY_SECONDS * float(NetworkTick.tick_rate))))
	await _wait_network_ticks(despawn_ticks)
	if death_sequence != _death_sequence_id:
		return
	if not is_dead:
		return
	queue_free()

func _disable_hurtbox(hurtbox: Area2D) -> void:
	if not is_instance_valid(hurtbox):
		return
	hurtbox.monitoring = false
	hurtbox.monitorable = false

func reset_for_respawn() -> void:
	_death_sequence_id += 1
	is_dead = false
	actions_locked = false
	is_slow_walking = false
	if net_sync:
		net_sync.reset_state()
	velocity = Vector2.ZERO
	show()
	_enable_hurtbox(headHurtBox)
	_enable_hurtbox(bodyHurtBox)
	set_process(true)
	set_physics_process(true)
	if movement_component:
		movement_component.set_process(true)
		movement_component.set_physics_process(true)
		movement_component.is_moving = false
		movement_component.external_velocity = Vector2.ZERO
	_last_footstep_position = global_position
	_footstep_moving = false
	if footstep_player and footstep_player.playing:
		footstep_player.stop()
	if health_component:
		health_component.is_dead = false
		health_component.current_health = health_component.max_health
	if player_input:
		player_input.set_authority(owner_peer_id)

func _enable_hurtbox(hurtbox: Area2D) -> void:
	if not is_instance_valid(hurtbox):
		return
	hurtbox.monitoring = true
	hurtbox.monitorable = true


func apply_explosion_force(explosion_origin: Vector2, force_amount: float) -> void:
	if is_dead:
		return
	if movement_component == null:
		return
	if force_amount <= 0.0:
		return
	var push_dir := global_position - explosion_origin
	if push_dir.length_squared() <= 0.0001:
		push_dir = Vector2.RIGHT.rotated(randf() * TAU)
	movement_component.add_external_velocity(push_dir.normalized() * force_amount)


@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_apply_screen_flash(detonation_pos: Vector2, duration_seconds: float, effect_radius: float, max_angle_deg: float, max_alpha: float = 0.95) -> void:
	if not is_local_player:
		return
	if not is_instance_valid(hud):
		return

	var to_blast := detonation_pos - global_position
	var distance := to_blast.length()
	if effect_radius > 0.0 and distance > effect_radius:
		return
	if not _has_flash_line_of_sight(detonation_pos):
		return

	if distance > 0.001:
		var facing := Vector2.RIGHT.rotated(rotation).normalized()
		var blast_direction := to_blast.normalized()
		var cos_threshold := cos(deg_to_rad(clampf(max_angle_deg, 0.0, 180.0)))
		if facing.dot(blast_direction) < cos_threshold:
			return

	var distance_factor := 1.0
	if effect_radius > 0.0:
		distance_factor = clampf(1.0 - (distance / effect_radius), 0.0, 1.0)
	var final_alpha := clampf(max_alpha * distance_factor, 0.0, 1.0)
	if final_alpha <= 0.01:
		return

	hud.show_stun_flash(maxf(duration_seconds, 0.05), final_alpha)


func _has_flash_line_of_sight(detonation_pos: Vector2) -> bool:
	var space_state := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(detonation_pos, global_position)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.collision_mask = 1 << 0 # Environment layer
	var exclude: Array = [get_rid()]
	if is_instance_valid(headHurtBox):
		exclude.append(headHurtBox.get_rid())
	if is_instance_valid(bodyHurtBox):
		exclude.append(bodyHurtBox.get_rid())
	query.exclude = exclude

	var hit := space_state.intersect_ray(query)
	return hit.is_empty()

func _wait_network_ticks(tick_count: int) -> void:
	for _i in range(maxi(0, tick_count)):
		await NetworkTick.tick_started
