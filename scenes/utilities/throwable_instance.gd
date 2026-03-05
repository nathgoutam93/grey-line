extends EquipmentInstance
class_name ThrowableInstance

var _charges_left := 0
var _cooldown_ticks_remaining := 0
var _throw_request_id := 0
var _pending_throw_direction := Vector2.RIGHT
var _pending_aim_origin := Vector2.ZERO

var data: ThrowableData:
	get: return equipment_data as ThrowableData


func set_throwable_data(throwable_data: ThrowableData) -> void:
	set_equipment_data(throwable_data)
	_charges_left = maxi(throwable_data.max_charges, 0)

func equip() -> void:
	super.equip()
	var fallback_delay := 0.0
	if data != null:
		fallback_delay = maxf(data.equip_time, 0.0)
	if fallback_delay > 0.0:
		_unlock_after_delay(fallback_delay)


func start_use() -> void:
	if is_locked:
		return
	if data == null or data.projectile_scene == null or player == null:
		return
	if _cooldown_ticks_remaining > 0:
		return
	if data.max_charges > 0 and _charges_left <= 0:
		return

	_lock()
	_pending_throw_direction = player.global_transform.x.normalized()
	if _pending_throw_direction.length_squared() <= 0.0001:
		_pending_throw_direction = Vector2.RIGHT
	_pending_aim_origin = player.global_position

	var use_sound: AudioStream = null
	if data.sounds is WeaponSoundData:
		use_sound = (data.sounds as WeaponSoundData).shoot_sound
	emit_signal("use_action", data.animations.get("attack", ""), use_sound)

	_throw_request_id += 1
	var request_id := _throw_request_id
	var release_delay := maxf(data.throw_release_time, 0.0)
	if release_delay > 0.0:
		await get_tree().create_timer(release_delay).timeout
		if not is_inside_tree() or request_id != _throw_request_id:
			if is_locked:
				_unlock()
			return

	if not multiplayer.is_server():
		if is_locked:
			_unlock()
		return

	var projectile = data.projectile_scene.instantiate() as Node2D
	if projectile == null:
		if is_locked:
			_unlock()
		return
	if multiplayer.is_server():
		projectile.set_multiplayer_authority(1)
	if projectile is FlashbangProjectile:
		var flash_projectile := projectile as FlashbangProjectile
		flash_projectile.detonate_after_seconds = data.fuse_time
		flash_projectile.flash_duration = data.flash_duration
		flash_projectile.flash_radius = data.flash_radius
		flash_projectile.flash_angle_deg = data.flash_angle_deg
		flash_projectile.flash_max_alpha = data.flash_max_alpha
	elif projectile is FragProjectile:
		var frag_projectile := projectile as FragProjectile
		frag_projectile.detonate_after_seconds = data.fuse_time
		frag_projectile.explosion_radius = data.explosion_radius
		frag_projectile.max_force = data.explosion_force
		frag_projectile.max_damage = data.explosion_max_damage
		frag_projectile.min_damage = data.explosion_min_damage
		frag_projectile.instigator_peer_id = player.owner_peer_id

	var throw_direction := _pending_throw_direction
	if data.aim_convergence_distance > 0.0:
		var aim_target := _pending_aim_origin + (_pending_throw_direction * data.aim_convergence_distance)
		var to_target : Vector2 = aim_target - global_position
		if to_target.length_squared() > 0.0001:
			throw_direction = to_target.normalized()
	var map_node := get_tree().current_scene.find_child("Map", true, false)
	if map_node:
		map_node.add_child(projectile, true)
	else:
		get_tree().current_scene.add_child(projectile, true)

	if projectile.has_method("initialize_throw"):
		projectile.call(
			"initialize_throw",
			global_position,
			throw_direction,
			data.throw_speed,
			data.max_travel_distance,
			data.arc_peak_height
		)
	projectile.rotation = throw_direction.angle() + randf_range(-data.throw_torque, data.throw_torque) * 0.02
	_cooldown_ticks_remaining = _seconds_to_ticks(data.use_cooldown)

	if data.max_charges > 0:
		_charges_left = maxi(_charges_left - 1, 0)
		if data.consume_on_use and _charges_left <= 0:
			_consume_self()
			return

	if is_locked:
		_unlock()


func stop_use() -> void:
	# Tap release should not cancel the throw windup.
	pass


func force_interrupt() -> void:
	_throw_request_id += 1
	_pending_throw_direction = Vector2.RIGHT
	_pending_aim_origin = Vector2.ZERO
	super.force_interrupt()


func _consume_self() -> void:
	if player == null or player.equipment_manager == null:
		return
	var manager := player.equipment_manager
	if manager.current_item == self:
		manager.current_item = null
	manager.equipped_items[manager.current_slot] = null
	queue_free()


func _tick_update_override() -> void:
	if _cooldown_ticks_remaining > 0:
		_cooldown_ticks_remaining -= 1


func _unlock_after_delay(delay_seconds: float) -> void:
	await get_tree().create_timer(delay_seconds).timeout
	if not is_inside_tree():
		return
	if is_locked:
		_unlock()
