extends RigidBody2D
class_name SmokeProjectile
const RPC_CHANNEL_UI := 2

@export var detonate_after_seconds: float = 1.6
@export var smoke_duration: float = 5.0
@export var speed: float = 760.0
@export var max_travel_distance: float = 900.0
@export var detonate_sound: AudioStream = null
@export var detonate_effect_scene: PackedScene = null
@export var smoke_scene: PackedScene = preload("res://scenes/utilities/smoke/smoke_cloud.tscn")
@export var mask_smoke_scene: PackedScene = preload("res://scenes/utilities/smoke/smoke_cloud_mask.tscn")

@export var detonate_sfx_max_distance := 1500.0
@export var detonate_sfx_attenuation := 2.0

var traveled_distance := 0.0
var _detonated := false
var _is_server_simulating := false
var _fuse_ticks_remaining := 0
var _has_impacted := false
var _last_position := Vector2.ZERO


func _ready() -> void:
	if not multiplayer.is_server():
		freeze = true
		set_physics_process(false)
		return

	_is_server_simulating = true
	freeze = false
	gravity_scale = 0.0
	_last_position = global_position
	var ticks := int(ceil(maxf(detonate_after_seconds, 0.01) * float(NetworkTick.tick_rate)))
	_fuse_ticks_remaining = maxi(ticks, 1)
	if not NetworkTick.tick_started.is_connected(_on_network_tick):
		NetworkTick.tick_started.connect(_on_network_tick)


func initialize_throw(origin: Vector2, direction: Vector2, throw_speed: float, travel_limit: float, _peak_height: float) -> void:
	global_position = origin
	var move_direction := direction.normalized()
	if move_direction.length_squared() <= 0.0001:
		move_direction = Vector2.RIGHT
	speed = maxf(throw_speed, 0.0)
	max_travel_distance = maxf(travel_limit, 1.0)
	traveled_distance = 0.0
	_has_impacted = false
	_last_position = origin
	linear_velocity = move_direction * speed


func _on_network_tick(_tick: int) -> void:
	if not _is_server_simulating or _detonated:
		return

	_fuse_ticks_remaining -= 1
	if _fuse_ticks_remaining <= 0:
		_detonate()


func _physics_process(_delta: float) -> void:
	if not _is_server_simulating or _detonated:
		return
	if _has_impacted:
		_last_position = global_position
		return

	traveled_distance += global_position.distance_to(_last_position)
	_last_position = global_position
	var current_speed := linear_velocity.length()
	if current_speed < 80.0 or traveled_distance >= max_travel_distance:
		_stop_motion_on_impact(global_position)


func _stop_motion_on_impact(impact_pos: Vector2) -> void:
	if _has_impacted:
		return
	_has_impacted = true
	global_position = impact_pos
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	freeze = true


func _detonate() -> void:
	if _detonated:
		return
	_detonated = true
	_is_server_simulating = false
	if NetworkTick.tick_started.is_connected(_on_network_tick):
		NetworkTick.tick_started.disconnect(_on_network_tick)

	var detonate_sound_path := ""
	if detonate_sound != null:
		detonate_sound_path = detonate_sound.resource_path
	var detonate_effect_path := ""
	if detonate_effect_scene != null:
		detonate_effect_path = detonate_effect_scene.resource_path
	var smoke_scene_path := ""
	if smoke_scene != null:
		smoke_scene_path = smoke_scene.resource_path
	var mask_smoke_scene_path := ""
	if mask_smoke_scene != null:
		mask_smoke_scene_path = mask_smoke_scene.resource_path

	_remote_play_detonate_sound.rpc(global_position, detonate_sound_path)
	_remote_spawn_detonate_effect.rpc(global_position, detonate_effect_path)
	_remote_spawn_smoke.rpc(global_position, smoke_duration, smoke_scene_path, mask_smoke_scene_path)
	queue_free()


@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_play_detonate_sound(sound_position: Vector2, sound_path: String) -> void:
	_play_detonate_sound(sound_position, sound_path)


func _play_detonate_sound(sound_position: Vector2, sound_path: String = "") -> void:
	var stream := detonate_sound
	if stream == null and not sound_path.is_empty():
		stream = load(sound_path) as AudioStream
	if stream == null:
		return
	var audio_player := AudioStreamPlayer2D.new()
	audio_player.stream = stream
	audio_player.global_position = sound_position
	audio_player.max_distance = detonate_sfx_max_distance
	audio_player.attenuation = detonate_sfx_attenuation
	get_tree().current_scene.add_child(audio_player)
	audio_player.finished.connect(audio_player.queue_free)
	audio_player.play()


@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_spawn_detonate_effect(effect_position: Vector2, effect_scene_path: String) -> void:
	var effect_scene := detonate_effect_scene
	if effect_scene == null and not effect_scene_path.is_empty():
		effect_scene = load(effect_scene_path) as PackedScene
	if effect_scene == null:
		return
	var detonate_effect := effect_scene.instantiate()
	if detonate_effect == null:
		return
	if detonate_effect is Node2D:
		(detonate_effect as Node2D).global_position = effect_position
	get_tree().current_scene.add_child(detonate_effect)


@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_spawn_smoke(smoke_position: Vector2, duration: float, smoke_scene_path: String, mask_scene_path: String) -> void:
	var duration_value := maxf(duration, 0.1)
	var motion_seed := float(
		(int(round(smoke_position.x * 10.0)) * 92821)
		+ (int(round(smoke_position.y * 10.0)) * 68917)
	)

	var world_smoke_scene := smoke_scene
	if world_smoke_scene == null and not smoke_scene_path.is_empty():
		world_smoke_scene = load(smoke_scene_path) as PackedScene
	if world_smoke_scene != null:
		var smoke := world_smoke_scene.instantiate() as SmokeCloud
		if smoke != null:
			smoke.global_position = smoke_position
			smoke.duration = duration_value
			smoke.motion_seed = motion_seed
		get_tree().current_scene.add_child(smoke)

	var viewport := MaskViewProvider.viewport
	if not is_instance_valid(viewport):
		return
	var level := viewport.get_node_or_null("Level")
	if level == null:
		return

	var view_smoke_scene := mask_smoke_scene
	if view_smoke_scene == null and not mask_scene_path.is_empty():
		view_smoke_scene = load(mask_scene_path) as PackedScene
	if view_smoke_scene == null:
		return
	var mask_smoke := view_smoke_scene.instantiate() as SmokeCloud
	if mask_smoke == null:
		return
	mask_smoke.global_position = smoke_position
	mask_smoke.duration = duration_value
	mask_smoke.motion_seed = motion_seed
	level.add_child(mask_smoke)
