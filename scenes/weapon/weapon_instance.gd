extends EquipmentInstance
class_name WeaponInstance

var ammo_in_mag := 0
var ammo_reserve := 0
var is_auto_reload := false
var is_reloading := false
var is_firing := false
var _reload_ticks_remaining := 0
var _burst_shots_remaining := 0
var _cooldown_ticks_remaining := 0

@export var sound_pool: SoundPool = null
@export var utility_sfx_player: AudioStreamPlayer2D = null

var BulletTrailScene = preload("res://scenes/bullet_trail/bullet_trail.tscn")

signal shoot_action(animation_name: String, sound_stream: AudioStream)
signal reload_action(animation_name: String, sound_stream: AudioStream)

## Convenience property to access equipment_data as WeaponData
var data: Weapon:
	get: return equipment_data as Weapon

var mode: WeaponAttackMode:
	get: return data.mode if data else null
const ENVIRONMENT_MASK := 1 << 0 # Physics layer 0
const BODY_HURTBOX_MASK := 1 << 4 # Physics layer 5
const HEAD_HURTBOX_MASK := 1 << 3 # Physics layer 4


func _ready() -> void:
	super._ready()

func set_weapon_data(w: Weapon) -> void:
	set_equipment_data(w)
	# make sure animations are defined; missing names lead to no playback
	for anim_key in ["attack", "reload", "equip", "idle", "move"]:
		if not data.animations.has(anim_key) or data.animations.get(anim_key, "") == "":
			push_warning("Weapon '%s' has no animation defined for '%s'" % [data.name, anim_key])

	if data.uses_ammo:
		var total_ammo: int = data.mag_size * max(data.mag_count, 1)
		ammo_in_mag = min(data.mag_size, total_ammo)
		ammo_reserve = max(total_ammo - ammo_in_mag, 0)
	else:
		ammo_in_mag = 0
		ammo_reserve = 0

func _shoot_raycast() -> void:
	var saved_transforms := {}
	if multiplayer.is_server():
		var shot_tick := NetworkTick.tick
		if player != null:
			shot_tick = player.net_sync.get_lag_compensation_tick()
		saved_transforms = LagCompensationService.rewind_players_to_tick(get_tree(), shot_tick, player)

	var origin = global_position
	var direction = player.global_transform.x.normalized()
	var end_point = origin + direction * data.d_range
	
	var space_state = get_world_2d().direct_space_state
	var shot_intent := player.current_shot_intent
	var query_exclude := _build_self_exclude_list()

	# World occlusion ray only.
	# Intentional: in HEAD mode, player body colliders do not block the shot because
	# the ray represents a head-height line (same gameplay rule as 3D perspective).
	var occlusion_query := PhysicsRayQueryParameters2D.create(origin, end_point)
	occlusion_query.collide_with_bodies = true
	occlusion_query.collide_with_areas = false
	occlusion_query.collision_mask = ENVIRONMENT_MASK
	occlusion_query.exclude = query_exclude
	var occlusion_result := space_state.intersect_ray(occlusion_query)

	var impact_result := occlusion_result
	var max_hit_distance := data.d_range
	if not occlusion_result.is_empty():
		max_hit_distance = origin.distance_to(occlusion_result.position)

	# Hurtbox ray: in HEAD mode only hit head layer, in BODY mode only hit body layer.
	var hurtbox_query := PhysicsRayQueryParameters2D.create(origin, end_point)
	hurtbox_query.collide_with_bodies = false
	hurtbox_query.collide_with_areas = true
	hurtbox_query.collision_mask = HEAD_HURTBOX_MASK if shot_intent == PlayerController.ShotIntent.HEAD else BODY_HURTBOX_MASK
	hurtbox_query.exclude = query_exclude
	var hurtbox_result := space_state.intersect_ray(hurtbox_query)
	var has_unoccluded_hurtbox_hit := false
	if not hurtbox_result.is_empty():
		var hurtbox_distance := origin.distance_to(hurtbox_result.position)
		if hurtbox_distance <= max_hit_distance + 0.001:
			impact_result = hurtbox_result
			has_unoccluded_hurtbox_hit = true

	var surface_type := _resolve_surface_type(impact_result)

	if data.uses_ammo:
		_create_bullet_trail(origin, impact_result.position if impact_result else end_point, impact_result.normal if impact_result else Vector2.ZERO, surface_type)

	# Damage must come from the mode-filtered hurtbox ray only.
	if has_unoccluded_hurtbox_hit:
		var hit_player := _resolve_hit_player(hurtbox_result.get("collider"))
		if hit_player != null and hit_player != player and not hit_player.is_dead:
			var is_head_hit := shot_intent == PlayerController.ShotIntent.HEAD
			if player.can_register_hit(is_head_hit) and Teams.can_damage(player.team, hit_player.team,
				player.owner_peer_id, hit_player.owner_peer_id, MatchGameMode.is_friendly_fire_enabled(get_tree())):
				hit_player.health_component.take_damage(data.damage, player.owner_peer_id, is_head_hit)

	if multiplayer.is_server():
		if not has_unoccluded_hurtbox_hit and not occlusion_result.is_empty():
			var kind := DestructionMaterial.KIND_BULLET if data.uses_ammo else DestructionMaterial.KIND_MELEE
			var walls := occlusion_result.get("collider") as DestructibleWalls
			var door := occlusion_result.get("collider") as Door
			var service := DestructionService.current(get_tree())
			if walls != null and service != null:
				var amount := data.wall_damage if data.uses_ammo else data.melee_wall_damage
				service.apply_cell_damage(walls, walls.cell_from_hit(occlusion_result), amount, kind)
			elif door != null:
				door.apply_damage(data.wall_damage if data.uses_ammo else 60, kind, player)
		LagCompensationService.restore_players(saved_transforms)

func _build_self_exclude_list() -> Array:
	var exclude: Array = []
	if player == null:
		return exclude
	exclude.append(player.get_rid())
	if is_instance_valid(player.headHurtBox):
		exclude.append(player.headHurtBox.get_rid())
	if is_instance_valid(player.bodyHurtBox):
		exclude.append(player.bodyHurtBox.get_rid())
	return exclude

func _resolve_hit_player(collider: Variant) -> PlayerController:
	if collider is PlayerController:
		return collider
	if collider is Node:
		var node := collider as Node
		var owner_node := node.get_parent()
		if owner_node is PlayerController:
			return owner_node
	return null

func _lock() -> void:
	super._lock()


func _unlock() -> void:
	super._unlock()
	# auto‑reload should run when the equip delay finishes, not only when equip_time was zero
	if data and data.uses_ammo and ammo_in_mag <= 0 and ammo_reserve > 0:
		reload()


func force_interrupt() -> void:
	if is_reloading:
		is_reloading = false
		_reload_ticks_remaining = 0
		if utility_sfx_player.playing:
			utility_sfx_player.stop()

	is_firing = false
	_burst_shots_remaining = 0
	super.force_interrupt()


func drop() -> void:
	# do not generate a world pickup if the data forbids dropping
	if data and not data.can_drop:
		force_interrupt()
		unequip()
		queue_free()
		return
	
	force_interrupt()
	unequip()
	_play_drop_sound()
	drop_weapon_pickup()
	queue_free()


func drop_weapon_pickup() -> void:
	if not multiplayer.is_server():
		return

	var pickup := data.pickup_scene.instantiate() as WeaponPickup
	pickup.global_position = global_position
	pickup.set_weapon_data(data)
	pickup.ammo_in_mag = ammo_in_mag
	pickup.ammo_reserve = ammo_reserve

	var map_node = get_tree().current_scene.find_child("Map", true, false)
	map_node.add_child.call_deferred(pickup, true)

	var drop_direction = global_transform.x.normalized()
	var drop_force = drop_direction * 250
	pickup.apply_impulse(drop_force, Vector2.ZERO)
	pickup.angular_velocity = randf_range(-5.0, 5.0)

	# Data is already set on the server; replication will sync it to clients.


func equip() -> void:
	super.equip()
	if _equip_ticks_remaining <= 0:
		if data.uses_ammo and ammo_in_mag <= 0 and ammo_reserve > 0:
			reload()


func start_use() -> void:
	if is_locked:
		return

	is_firing = true
	if not mode.is_auto and mode.burst_count > 0 and _burst_shots_remaining <= 0:
		_burst_shots_remaining = mode.burst_count


func start_fire() -> void:
	# Backward compatibility wrapper
	start_use()


func reload(auto: bool = false) -> void:
	if is_locked or not data.is_reloadable:
		return
	if data.uses_ammo:
		if ammo_in_mag >= data.mag_size:
			return
		if ammo_reserve <= 0:
			return
	
	_lock()
	is_auto_reload = auto
	is_reloading = true
	_reload_ticks_remaining = _seconds_to_ticks(data.reload_duration)
	
	emit_signal("reload_action", data.animations.get("reload", ""), data.sounds.reload_sound)

	_play_reload_sound()

	if has_node("AnimationPlayer"):
		get_node("AnimationPlayer").play("reload")

	if _reload_ticks_remaining <= 0:
		_complete_reload()

func stop_use() -> void:
	is_firing = false
	_burst_shots_remaining = 0


func stop_fire() -> void:
	# Backward compatibility wrapper
	stop_use()

func _single_shot() -> bool:
	if is_locked:
		return false

	# compute cooldown data and log everything for diagnosis
	var secs := data.mode.cooldown
	var ticks := _seconds_to_ticks(secs)

	if data.uses_ammo:
		if is_reloading:
			return false
		if ammo_in_mag <= 0:
			if ammo_reserve > 0:
				reload(true)
			return false

		ammo_in_mag -= 1

	emit_signal("shoot_action", data.animations.get("attack", ""), data.sounds.shoot_sound)

	_play_shoot_sound()

	_shoot_raycast()

	if has_node("MuzzleFlash"):
		var flash = get_node("MuzzleFlash")
		flash.show()
		flash.modulate = Color(1, 1, 1, 1)
		flash.hide()

	if has_node("AnimationPlayer"):
		get_node("AnimationPlayer").play("shoot")
	_cooldown_ticks_remaining = max(ticks, 1)

	if data.uses_ammo and ammo_in_mag <= 0 and ammo_reserve > 0:
		reload(true)
		return false

	return true

func _tick_update_override() -> void:
	if _reload_ticks_remaining > 0:
		_reload_ticks_remaining -= 1
		if _reload_ticks_remaining == 0:
			_complete_reload()

	if _cooldown_ticks_remaining > 0:
		_cooldown_ticks_remaining -= 1

	if not is_firing:
		return
	if is_locked or is_reloading:
		return
	if _cooldown_ticks_remaining > 0:
		return

	if mode.is_auto:
		if not _single_shot():
			is_firing = false
		return

	if mode.burst_count > 0:
		if _burst_shots_remaining <= 0:
			_burst_shots_remaining = mode.burst_count
		if _single_shot():
			_burst_shots_remaining -= 1
		if _burst_shots_remaining <= 0:
			is_firing = false
		return

	is_firing = false
	_single_shot()

func _seconds_to_ticks(seconds: float) -> int:
	return int(ceil(max(seconds, 0.0) * float(NetworkTick.tick_rate)))

func _complete_reload() -> void:
	if not is_reloading:
		return
	if data.uses_ammo:
		var ammo_needed: int = max(data.mag_size - ammo_in_mag, 0)
		var ammo_loaded: int = min(ammo_needed, ammo_reserve)
		ammo_in_mag += ammo_loaded
		ammo_reserve -= ammo_loaded
	else:
		ammo_in_mag = data.mag_size
	is_reloading = false
	_reload_ticks_remaining = 0
	_unlock()

func can_play_idle_animation() -> bool:
	if is_locked:
		return false
	if is_reloading:
		return false
	if is_firing:
		return false
	return _cooldown_ticks_remaining <= 0

func get_use_noise_radius() -> float:
	return sound_pool.max_distance if sound_pool else 0.0

func _play_shoot_sound():
	if sound_pool:
		sound_pool.play_stream(data.sounds.shoot_sound)
		_report_noise(sound_pool.max_distance, data.sounds.shoot_sound)

func _play_utility_sound(stream: AudioStream) -> void:
	if utility_sfx_player:
		utility_sfx_player.stream = stream
		utility_sfx_player.play()
		_report_noise(utility_sfx_player.max_distance, stream)

func _play_reload_sound():
	_play_utility_sound(data.sounds.reload_sound)

func _play_equip_sound():
	_play_utility_sound(data.sounds.equip_sound)

func _play_drop_sound():
	_play_utility_sound(data.sounds.drop_sound)

func _resolve_surface_type(result: Dictionary) -> String:
	if result.is_empty():
		return "default"

	var collider = result.get("collider")
	if collider == null:
		return "default"

	if collider is PlayerController:
		return "flesh"
	if collider is Node:
		var node := collider as Node
		if node.get_parent() is PlayerController:
			return "flesh"

	if collider.has_method("get_impact_surface_type"):
		var from_method = collider.call("get_impact_surface_type")
		if from_method is String and not from_method.is_empty():
			return from_method

	if collider.has_meta("surface_type"):
		var from_meta = collider.get_meta("surface_type")
		if from_meta is String and not from_meta.is_empty():
			return from_meta

	for group_name in collider.get_groups():
		var group_as_string := str(group_name)
		if group_as_string.begins_with("surface_"):
			return group_as_string.trim_prefix("surface_")

	return "default"

func _create_bullet_trail(start: Vector2, end: Vector2, normal, surface_type: String = "default") -> void:
	var trail = BulletTrailScene.instantiate()
	trail.start_point = start
	trail.end_point = end
	trail.normal = normal
	trail.surface_type = surface_type
	get_tree().current_scene.add_child(trail)
