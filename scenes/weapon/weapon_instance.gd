extends Node2D
class_name WeaponInstance

var data: Weapon
var mode: WeaponAttackMode

var ammo_in_mag := 0

var is_auto_reload := false
var is_reloading := false
var is_firing := false
var is_locked := true

var visual_node: Node2D = null
var sound_pool: SoundPool = null
var reload_sfx_player: AudioStreamPlayer2D = null

var BulletTrailScene = preload("res://scenes/bullet_trail/bullet_trail.tscn")

signal equip_action(animation_name: String, sound_stream: AudioStream)
signal shoot_action(animation_name: String, sound_stream: AudioStream)
signal reload_action(animation_name: String, sound_stream: AudioStream)

func _init(w: Weapon):
	data = w
	mode = w.mode
	ammo_in_mag = w.mag_size


func _create_bullet_trail(start: Vector2, end: Vector2, normal) -> void:
	# Visual trail effect
	var trail = BulletTrailScene.instantiate()
	trail.start_point = start
	trail.end_point = end
	trail.normal = normal
	get_tree().current_scene.add_child(trail)

func _shoot_raycast() -> void:
	if not visual_node:
		return
	
	var origin = visual_node.global_position
	var target = get_global_mouse_position()
	var direction = (target - origin).normalized()
	var distance = 1000
	var end_point = origin + direction * distance
	
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(origin, end_point)
	var result = space_state.intersect_ray(query)

	if data.uses_ammo:
		_create_bullet_trail(origin, result.position if result else end_point, result.normal if result else Vector2.ZERO)

	if result:
		var collider = result.collider

		if collider is PlayerController:
			collider.health_component.take_damage(data.damage)


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
	if visual_node and visual_node.is_inside_tree():
		visual_node.queue_free()
		visual_node = null
	
	if sound_pool and sound_pool.is_inside_tree():
		sound_pool.queue_free()
		sound_pool = null
	
	if reload_sfx_player and reload_sfx_player.is_inside_tree():
		reload_sfx_player.queue_free()
		reload_sfx_player = null

func unequip():
	if visual_node:
		visual_node.hide()

func equip(socket: Node2D):
	_lock()

	# Cleanup any existing visuals and sounds
	unequip()

	# Create and attach the visual and sounds
	if not visual_node:
		visual_node = data.weapon_scene.instantiate()
		socket.add_child(visual_node)
		visual_node.position = Vector2.ZERO # You can adjust offset per-weapon
		visual_node.rotation = 0.0 # Adjust if needed
	else:
		visual_node.show()

	if not sound_pool:
		var fire_rate = data.mode.cooldown
		var recommended_pool_size = clamp(ceil(1.0 / fire_rate) * 2, 4, 8)
		sound_pool = SoundPool.new(recommended_pool_size)
		visual_node.add_child(sound_pool)

	if not reload_sfx_player:
		reload_sfx_player = AudioStreamPlayer2D.new()
		visual_node.add_child(reload_sfx_player)
	
	emit_signal("equip_action", data.animations.get("equip", ""), data.sounds.equip_sound)

	# if weapon has animations
	if visual_node and visual_node.has_node("AnimationPlayer"):
		visual_node.get_node("AnimationPlayer").play("equip")
	
	sound_pool.play_stream(data.sounds.equip_sound)

	await get_tree().create_timer(data.equip_duration).timeout
	_unlock()

	if ammo_in_mag <= 0:
		await reload()


func reload(auto: bool = false) -> void:
	if is_locked or not data.is_reloadable:
		return
	
	_lock()
	is_auto_reload = auto
	is_reloading = true
	emit_signal("reload_action", data.animations.get("reload", ""), data.sounds.reload_sound)
	
	reload_sfx_player.stream = data.sounds.reload_sound
	reload_sfx_player.play()

	if visual_node and visual_node.has_node("AnimationPlayer"):
		visual_node.get_node("AnimationPlayer").play("reload")

	await get_tree().create_timer(data.reload_duration).timeout

	if is_reloading:
		ammo_in_mag = data.mag_size
		is_reloading = false
		_unlock()


func start_fire():
	_interrupt_reload()

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
			_unlock()
			await reload(true) # ⬅️ Auto reload when empty
			return false

		ammo_in_mag -= 1

	emit_signal("shoot_action", data.animations.get("attack", ""), data.sounds.shoot_sound)

	sound_pool.play_stream(data.sounds.shoot_sound)

	_shoot_raycast()

	if visual_node and visual_node.has_node("MuzzleFlash"):
			var flash = visual_node.get_node("MuzzleFlash")
			flash.show()
			flash.modulate = Color(1, 1, 1, 1)

			await get_tree().create_timer(0.05).timeout
			if flash:
				flash.hide()

	if visual_node and visual_node.has_node("AnimationPlayer"):
		visual_node.get_node("AnimationPlayer").play("shoot")


	await get_tree().create_timer(data.mode.cooldown).timeout

	return true
