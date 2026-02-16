extends Node2D
class_name WeaponInstance

var data: Weapon
var mode: WeaponAttackMode

var ammo_in_mag := 0
var ammo_reserve := 0
var is_auto_reload := false
var is_reloading := false
var is_firing := false

@export var is_locked := true

@export var sound_pool: SoundPool = null
@export var reload_sfx_player: AudioStreamPlayer2D = null

var BulletTrailScene = preload("res://scenes/bullet_trail/bullet_trail.tscn")

signal equip_action(animation_name: String, sound_stream: AudioStream)
signal shoot_action(animation_name: String, sound_stream: AudioStream)
signal reload_action(animation_name: String, sound_stream: AudioStream)

var player: PlayerController

func set_weapon_data(w: Weapon):
	data = w
	mode = data.mode
	if data.uses_ammo:
		var total_ammo : int =  data.mag_size * max(data.mag_count, 1)
		ammo_in_mag = min(data.mag_size, total_ammo)
		ammo_reserve = max(total_ammo - ammo_in_mag, 0)
	else:
		ammo_in_mag = 0
		ammo_reserve = 0

func _shoot_raycast() -> void:
	var origin = global_position
	var direction = player.global_transform.x.normalized()
	var end_point = origin + direction * data.d_range
	
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(origin, end_point)
	var result = space_state.intersect_ray(query)
	var surface_type := _resolve_surface_type(result)

	if data.uses_ammo:
		_create_bullet_trail(origin, result.position if result else end_point, result.normal if result else Vector2.ZERO, surface_type)


	# draw_debug_line(origin, result.position if result else end_point)

	if result:
		var collider = result.collider

		if collider is PlayerController:
			collider.health_component.take_damage(data.damage, player.owner_peer_id)

func _lock():
	is_locked = true

func _unlock():
	is_locked = false

func _interrupt_reload():
	if is_reloading and not is_auto_reload:
		is_reloading = false
		if reload_sfx_player.playing:
			reload_sfx_player.stop()
		_unlock()

func force_interrupt():
	if is_reloading:
		is_reloading = false
		if reload_sfx_player.playing:
			reload_sfx_player.stop()

	is_firing = false
	_unlock()


func drop():
	force_interrupt()
	unequip()
	drop_weapon_pickup()
	queue_free()

func drop_weapon_pickup():
	if not multiplayer.is_server():
		return

	var pickup = data.pickup_scene.instantiate() as RigidBody2D
	pickup.global_position = global_position
	if pickup.has_method("set_weapon_data"):
		pickup.set_weapon_data(data)
	if "ammo_in_mag" in pickup:
		pickup.ammo_in_mag = ammo_in_mag
	if "ammo_reserve" in pickup:
		pickup.ammo_reserve = ammo_reserve

	var map_node = get_tree().current_scene.find_child("Map", true, false)
	map_node.add_child.call_deferred(pickup, true)

	var drop_direction = global_transform.x.normalized()
	var drop_force = drop_direction * 250
	pickup.apply_impulse(drop_force, Vector2.ZERO)
	pickup.angular_velocity = randf_range(-5.0, 5.0)

	# Data is already set on the server; replication will sync it to clients.


func unequip():
	hide()

func equip():
	_lock()

	unequip()

	show()
	
	emit_signal("equip_action", data.animations.get("equip", ""), data.sounds.equip_sound)

	# if weapon has animations
	if has_node("AnimationPlayer"):
		get_node("AnimationPlayer").play("equip")
	
	_play_equip_sound()

	await get_tree().create_timer(data.equip_duration).timeout
	_unlock()

	if data.uses_ammo and ammo_in_mag <= 0 and ammo_reserve > 0:
		await reload()


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
	
	emit_signal("reload_action", data.animations.get("reload", ""), data.sounds.reload_sound)

	_play_reload_sound()

	if has_node("AnimationPlayer"):
		get_node("AnimationPlayer").play("reload")

	await get_tree().create_timer(data.reload_duration).timeout

	if is_reloading:
		if data.uses_ammo:
			var ammo_needed : int = max(data.mag_size - ammo_in_mag, 0)
			var ammo_loaded : int = min(ammo_needed, ammo_reserve)
			ammo_in_mag += ammo_loaded
			ammo_reserve -= ammo_loaded
		else:
			ammo_in_mag = data.mag_size
		is_reloading = false
		_unlock()

func start_fire():
	if is_firing or is_locked:
		return

	is_firing = true
	if mode.is_auto:
		auto_shoot_loop()
	elif mode.burst_count > 0:
		burst_shoot_loop(mode.burst_count)
	else:
		_lock()
		await single_shoot()
		_unlock()

func stop_fire():
	is_firing = false


func auto_shoot_loop():
	_lock()
	while is_firing:
		if (not await single_shoot()):
			break
	_unlock()

func burst_shoot_loop(burst_count: int):
	_lock()
	for i in range(burst_count):
		if (not await single_shoot()):
			break
	_unlock()

func single_shoot() -> bool:
	if data.uses_ammo:
		if is_reloading:
			return false
		if ammo_in_mag <= 0:
			if ammo_reserve > 0:
				_unlock()
				await reload(true) # Auto reload when empty
			return false

		ammo_in_mag -= 1

	emit_signal("shoot_action", data.animations.get("attack", ""), data.sounds.shoot_sound)

	_play_shoot_sound()

	_shoot_raycast()

	if has_node("MuzzleFlash"):
		var flash = get_node("MuzzleFlash")
		flash.show()
		flash.modulate = Color(1, 1, 1, 1)

		await get_tree().create_timer(0.05).timeout
		if flash:
			flash.hide()

	if has_node("AnimationPlayer"):
		get_node("AnimationPlayer").play("shoot")


	await get_tree().create_timer(data.mode.cooldown).timeout

	if data.uses_ammo and ammo_in_mag <= 0 and ammo_reserve > 0:
		_unlock()
		await reload(true) # Auto reload when empty
		return false

	return true

func _play_shoot_sound():
	if sound_pool:
		sound_pool.play_stream(data.sounds.shoot_sound)

func _play_reload_sound():
	if reload_sfx_player:
		reload_sfx_player.stream = data.sounds.reload_sound
		reload_sfx_player.play()

func _play_equip_sound():
	if sound_pool:
		sound_pool.play_stream(data.sounds.equip_sound)

func _resolve_surface_type(result: Dictionary) -> String:
	if result.is_empty():
		return "default"

	var collider = result.get("collider")
	if collider == null:
		return "default"

	if collider is PlayerController:
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

		
func draw_debug_line(origin: Vector2, end_point: Vector2, color := Color.RED, duration := 0.2):
	var debug_line = Line2D.new()
	debug_line.position = Vector2.ZERO # Important: don't inherit position
	debug_line.points = PackedVector2Array([origin, end_point]) # world-space points
	debug_line.default_color = color
	debug_line.width = 2.0
	get_tree().current_scene.add_child(debug_line) # Add to scene root

	var timer = Timer.new()
	timer.wait_time = duration
	timer.one_shot = true
	debug_line.add_child(timer)
	timer.start()
	timer.timeout.connect(func(): debug_line.queue_free())
