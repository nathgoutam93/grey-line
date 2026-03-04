extends Node2D
class_name StunGrenadeProjectile

@export var detonate_after_seconds: float = 1.6
@export var flash_duration: float = 2.0
@export var flash_radius: float = 900.0
@export_range(0.0, 180.0, 1.0) var flash_angle_deg: float = 70.0
@export_range(0.0, 1.0, 0.05) var flash_max_alpha: float = 0.95
@export var speed: float = 760.0
@export var max_travel_distance: float = 900.0
@export var arc_peak_height: float = 18.0

@onready var sprite: Sprite2D = get_node_or_null("Sprite2D")
@onready var shadow_sprite: Sprite2D = get_node_or_null("ShadowSprite")
@onready var hit_area: Area2D = get_node_or_null("Area2D")

var move_direction := Vector2.RIGHT
var traveled_distance := 0.0
var _detonated := false
var _is_server_simulating := false
var _fuse_ticks_remaining := 0
var _trajectory_progress := 0.0
var _has_impacted := false

func _ready() -> void:
	if hit_area and not hit_area.area_entered.is_connected(_on_hit_area_entered):
		hit_area.area_entered.connect(_on_hit_area_entered)
	if not multiplayer.is_server():
		set_process(false)
		set_physics_process(false)
		return

	_is_server_simulating = true
	var ticks := int(ceil(maxf(detonate_after_seconds, 0.01) * float(NetworkTick.tick_rate)))
	_fuse_ticks_remaining = maxi(ticks, 1)
	if not NetworkTick.tick_started.is_connected(_on_network_tick):
		NetworkTick.tick_started.connect(_on_network_tick)


func initialize_throw(origin: Vector2, direction: Vector2, throw_speed: float, travel_limit: float, peak_height: float) -> void:
	global_position = origin
	move_direction = direction.normalized()
	if move_direction.length_squared() <= 0.0001:
		move_direction = Vector2.RIGHT
	speed = maxf(throw_speed, 0.0)
	max_travel_distance = maxf(travel_limit, 1.0)
	arc_peak_height = maxf(peak_height, 0.0)
	traveled_distance = 0.0
	_trajectory_progress = 0.0


func _on_network_tick(_tick: int) -> void:
	if not _is_server_simulating or _detonated:
		return

	if not _has_impacted and speed > 0.0:
		var dt := NetworkTick.get_tick_delta()
		var previous_pos := global_position
		var step := move_direction * speed * dt
		var next_pos := previous_pos + step
		var collision := _raycast_environment(previous_pos, next_pos)
		if not collision.is_empty():
			_stop_motion_on_impact(collision.position)
		else:
			global_position = next_pos
			traveled_distance += step.length()
			_trajectory_progress = clampf(traveled_distance / maxf(max_travel_distance, 1.0), 0.0, 1.0)
			if traveled_distance >= max_travel_distance:
				_stop_motion_on_impact(global_position)

	_fuse_ticks_remaining -= 1
	if _fuse_ticks_remaining <= 0:
		_detonate()


func _process(_delta: float) -> void:
	_update_visual_arc()


func _update_visual_arc() -> void:
	var p := clampf(_trajectory_progress, 0.0, 1.0)
	var height := 4.0 * arc_peak_height * p * (1.0 - p)
	if sprite:
		sprite.position = Vector2(0.0, -height)
	if shadow_sprite:
		var t := 0.0
		if arc_peak_height > 0.0:
			t = clampf(height / arc_peak_height, 0.0, 1.0)
		var shadow_scale := lerpf(1.0, 0.72, t)
		shadow_sprite.scale = Vector2.ONE * shadow_scale
		shadow_sprite.modulate.a = lerpf(0.38, 0.2, t)


func _raycast_environment(from: Vector2, to: Vector2) -> Dictionary:
	var space_state := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(from, to)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.collision_mask = 1 << 0 # Environment
	return space_state.intersect_ray(query)


func _on_hit_area_entered(_area: Area2D) -> void:
	if not multiplayer.is_server():
		return
	_stop_motion_on_impact(global_position)


func _stop_motion_on_impact(impact_pos: Vector2) -> void:
	if _has_impacted:
		return
	_has_impacted = true
	global_position = impact_pos
	speed = 0.0


func _detonate() -> void:
	if _detonated:
		return
	_detonated = true
	_is_server_simulating = false
	if NetworkTick.tick_started.is_connected(_on_network_tick):
		NetworkTick.tick_started.disconnect(_on_network_tick)

	for node in get_tree().get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player == null or player.is_dead:
			continue
		player._remote_apply_screen_flash.rpc(
			global_position,
			flash_duration,
			flash_radius,
			flash_angle_deg,
			flash_max_alpha
		)

	queue_free()
