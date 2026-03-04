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

@export var hud: CanvasLayer
@export var camera: Camera2D
@export var audio_listner: AudioListener2D

@export var is_slow_walking := false

var owner_peer_id: int = 1
var current_shot_intent: int = ShotIntent.BODY

var interactables: Array[Interactable]
var is_dead := false
var is_local_player := false

const HISTORY_SECONDS := 1.0
const INTERP_DELAY_TICKS := 2
const TICK_OFFSET_SMOOTHING := 0.1

var _input_buffer: Dictionary = {}
var _input_queue: Dictionary = {}
var _last_input: PlayerInputFrame
var _last_processed_tick := 0
var _state_history := StateHistoryBuffer.new()
var _reconciler := ClientReconciler.new()
var _interpolator := RemoteInterpolator.new()
var _is_firing_net := false
var _tick_offset := 0.0
var _last_authoritative_input_tick := 0
var _death_sequence_id := 0
const DEATH_DESPAWN_DELAY_SECONDS := 5.0

func _is_server_role() -> bool:
	return multiplayer.is_server()

func _is_owner_role() -> bool:
	return owner_peer_id == multiplayer.get_unique_id()

func has_authority(id):
	return id == get_multiplayer_authority() or id == owner_peer_id

func _ready():
	if health_component and not health_component.is_connected("die", _on_die):
		health_component.connect("die", _on_die)

	if camera:
		camera.ignore_rotation = not camera_rotates_with_player
		camera.offset = Vector2.ZERO
		camera.position = Vector2(camera_boom_distance, 0.0)

	_state_history.configure(int(NetworkTick.get("tick_rate") * HISTORY_SECONDS))
	if not NetworkTick.tick_started.is_connected(_on_network_tick):
		NetworkTick.tick_started.connect(_on_network_tick)

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
	if equipment_manager and equipment_manager.has_method("apply_local_view"):
		equipment_manager.apply_local_view()


func _get_current_equipment() -> EquipmentInstance:
	if equipment_manager == null:
		return null
	return equipment_manager.get_current_item()


func get_speed():
	var speed_multiplier = 1

	if is_slow_walking:
		speed_multiplier *= slow_walk_multiplier
	
	var current_item = _get_current_equipment()
	if current_item is WeaponInstance:
		speed_multiplier *= (current_item as WeaponInstance).data.speed_multiplier

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
	
	if footstep_player and footstep_player.playing:
		footstep_player.stop()

	var current_item = _get_current_equipment()
	if current_item and current_item is WeaponInstance:
		var weapon = current_item as WeaponInstance
		if weapon.can_play_idle_animation():
			skeletal_character.anim_player.play(weapon.data.animations.get("idle", ""))

func _physics_process(_delta: float) -> void:
	pass

func _on_network_tick(tick: int) -> void:
	if is_dead:
		return
	if _is_server_role():
		_server_tick(tick)
	elif _is_owner_role():
		_owner_tick(_estimated_server_tick(tick))
	else:
		_proxy_tick(_estimated_server_tick(tick))

func _owner_tick(server_tick: int) -> void:
	if not is_instance_valid(player_input) or not is_instance_valid(movement_component):
		return
	var frame := player_input.build_input_frame(server_tick)
	_input_buffer[server_tick] = frame
	_apply_input_actions(frame)
	PlayerSimulation.simulate(self , movement_component, frame)
	rpc_id(1, "server_receive_input", frame.to_dict())

func _server_tick(tick: int) -> void:
	if not is_instance_valid(movement_component):
		return
	var frame: PlayerInputFrame = _input_queue.get(tick, null)
	if frame == null:
		var candidate_ticks := _input_queue.keys()
		candidate_ticks.sort()
		for key in candidate_ticks:
			var queued_tick := int(key)
			if queued_tick <= tick:
				frame = _input_queue[queued_tick] as PlayerInputFrame
				_input_queue.erase(queued_tick)
			else:
				break
	if frame == null and _is_owner_role() and is_instance_valid(player_input):
		frame = player_input.build_input_frame(tick)
	if frame == null:
		frame = _last_input
	if frame == null:
		return
	_last_input = frame
	_input_queue.erase(tick)
	_last_authoritative_input_tick = frame.tick
	_apply_input_actions(frame)
	PlayerSimulation.simulate(self , movement_component, frame)
	_last_processed_tick = tick
	_state_history.store(tick, global_transform)
	_send_snapshot(tick)

func _proxy_tick(server_tick: int) -> void:
	var render_tick := server_tick - INTERP_DELAY_TICKS
	if _interpolator.snapshot_buffer.size() < 2:
		_interpolator.apply_latest(self )
		return
	_interpolator.interpolate(self , render_tick)

func _apply_input_actions(frame: PlayerInputFrame) -> void:
	is_slow_walking = frame.slow_walk_held
	current_shot_intent = frame.shot_intent

	# Only the authoritative server executes combat/inventory actions.
	# It then broadcasts results through existing _remote_* RPCs.
	if not _is_server_role():
		return

	if frame.reload_pressed:
		_remote_reload.rpc()
	if frame.switch_prev_pressed:
		_remote_switch_weapon_previous.rpc()
	if frame.switch_next_pressed:
		_remote_switch_weapon.rpc()
	if frame.slot_select >= 0:
		_remote_switch_weapon_slot.rpc(frame.slot_select)
	if frame.drop_pressed:
		_remote_drop_weapon.rpc()
	if frame.interact_pressed:
		var target_path: NodePath = NodePath("")
		if interactables.size() > 0 and interactables[0]:
			target_path = interactables[0].get_path()
		_remote_interact.rpc(target_path)

	if frame.fire_held and not _is_firing_net:
		_is_firing_net = true
		_remote_start_fire.rpc(frame.shot_intent)
	elif not frame.fire_held and _is_firing_net:
		_is_firing_net = false
		_remote_stop_fire.rpc()

func _server_or_local_interact() -> void:
	var target_path: NodePath = NodePath("")
	if interactables.size() > 0 and interactables[0]:
		target_path = interactables[0].get_path()
	if target_path == NodePath(""):
		return
	var interactable := get_node_or_null(target_path)
	if interactable and interactable.owner_ref and interactable.owner_ref.has_method("on_interact"):
		interactable.owner_ref.on_interact(self )

func _send_snapshot(tick: int) -> void:
	var snapshot := {
		"tick": tick,
		"position": global_position,
		"velocity": velocity,
		"rotation": rotation,
		"ack_tick": _last_processed_tick
	}
	rpc("client_receive_snapshot", snapshot)

@rpc("any_peer", "unreliable")
func server_receive_input(frame_data: Dictionary) -> void:
	if not _is_server_role():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != owner_peer_id:
		return
	var frame := PlayerInputFrame.from_dict(frame_data)
	if frame.tick <= _last_processed_tick:
		# Late packet: apply as latest known intent for subsequent ticks.
		_last_input = frame
		return
	_input_queue[frame.tick] = frame

@rpc("any_peer", "unreliable")
func client_receive_snapshot(snapshot: Dictionary) -> void:
	var server_tick := int(snapshot.get("tick", 0))
	if server_tick > 0:
		_update_tick_offset(server_tick)
	if _is_owner_role():
		_reconciler.reconcile(
			self ,
			snapshot.get("position", global_position),
			snapshot.get("velocity", velocity),
			int(snapshot.get("ack_tick", 0)),
			_input_buffer,
			movement_component
		)
		return
	_interpolator.push_snapshot(snapshot)

func get_history_transform(tick: int) -> Variant:
	return _state_history.get_transform_for_tick(tick)

func get_lag_compensation_tick() -> int:
	if _last_authoritative_input_tick > 0:
		return _last_authoritative_input_tick
	return _last_processed_tick

func sync_server_tick(server_tick: int) -> void:
	if server_tick <= 0:
		return
	_tick_offset = float(server_tick - NetworkTick.tick)

func _estimated_server_tick(local_tick: int) -> int:
	return int(round(float(local_tick) + _tick_offset))

func _update_tick_offset(authoritative_server_tick: int) -> void:
	var target_offset := float(authoritative_server_tick - NetworkTick.tick)
	_tick_offset = lerpf(_tick_offset, target_offset, TICK_OFFSET_SMOOTHING)


func add_interactable(item: Interactable):
	interactables.append(item)

func remove_interactable(item: Interactable):
	interactables.erase(item)

@rpc("authority", "call_local")
func _remote_interact(target_path: NodePath):
	if target_path == NodePath(""):
		return
	var interactable = get_node_or_null(target_path)
	if interactable and interactable.owner_ref and interactable.owner_ref.has_method("on_interact"):
		interactable.owner_ref.on_interact(self )

@rpc("authority", "call_local", "reliable")
func _remote_start_fire(shot_intent: int = ShotIntent.BODY):
	if shot_intent != ShotIntent.BODY and shot_intent != ShotIntent.HEAD:
		shot_intent = ShotIntent.BODY
	current_shot_intent = shot_intent

	var current_item = _get_current_equipment()
	if current_item and current_item.has_method("start_fire"):
		current_item.start_fire()
	elif current_item and current_item.has_method("start_use"):
		current_item.start_use()

func can_register_hit(is_head_hit: bool) -> bool:
	if current_shot_intent == ShotIntent.HEAD:
		return is_head_hit
	return not is_head_hit

@rpc("authority", "call_local", "reliable")
func _remote_stop_fire():
	var current_item = _get_current_equipment()
	if current_item and current_item.has_method("stop_fire"):
		current_item.stop_fire()
	elif current_item and current_item.has_method("stop_use"):
		current_item.stop_use()

@rpc("authority", "call_local", "reliable")
func _remote_reload():
	var current_item = _get_current_equipment()
	if current_item and current_item.has_method("reload"):
		current_item.reload()

@rpc("authority", "call_local", "reliable")
func _remote_switch_weapon():
	if equipment_manager != null and equipment_manager.has_method("switch_to_next_item"):
		equipment_manager.switch_to_next_item()

@rpc("authority", "call_local", "reliable")
func _remote_switch_weapon_previous():
	if equipment_manager != null and equipment_manager.has_method("switch_to_previous_item"):
		equipment_manager.switch_to_previous_item()

@rpc("authority", "call_local", "reliable")
func _remote_switch_weapon_slot(slot: int):
	if equipment_manager != null and equipment_manager.has_method("switch_to_slot"):
		equipment_manager.switch_to_slot(slot)

@rpc("authority", "call_local", "reliable")
func _remote_drop_weapon():
	if equipment_manager != null and equipment_manager.has_method("drop_current_item"):
		equipment_manager.drop_current_item()

@rpc("authority", "call_local", "reliable")
func _remote_pickup(pickup_path: NodePath):
	var weapon_pickup := _resolve_pickup_node(pickup_path)
	if weapon_pickup == null:
		push_warning("Pickup node not found for path: %s" % [String(pickup_path)])
		return

	if equipment_manager != null and equipment_manager.has_method("pickup_weapon"):
		if equipment_manager.pickup_weapon(weapon_pickup):
			weapon_pickup.queue_free()

func _resolve_pickup_node(pickup_path: NodePath) -> WeaponPickup:
	var scene_root := get_tree().current_scene
	if scene_root:
		var map_node := scene_root.find_child("Map", true, false)
		if map_node:
			var from_map := map_node.get_node_or_null(pickup_path) as WeaponPickup
			if from_map:
				return from_map

	var from_root := get_tree().root.get_node_or_null(pickup_path) as WeaponPickup
	if from_root:
		return from_root

	var pickup_name := String(pickup_path).get_file()
	if pickup_name == "":
		return null

	if scene_root:
		return scene_root.find_child(pickup_name, true, false) as WeaponPickup

	return null

@rpc("authority", "call_local", "reliable")
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
	velocity = Vector2.ZERO
	if footstep_player.playing:
		footstep_player.stop()
	var current_item = _get_current_equipment()
	if current_item:
		if current_item.has_method("force_interrupt"):
			current_item.force_interrupt()
		if current_item.has_method("stop_fire"):
			current_item.stop_fire()
		elif current_item.has_method("stop_use"):
			current_item.stop_use()
	hide()

	var dead_scene = preload("res://scenes/player/player_dead.tscn").instantiate()
	dead_scene.global_position = global_pos
	get_tree().current_scene.add_child(dead_scene)

	var tick_rate := int(NetworkTick.get("tick_rate"))
	if tick_rate <= 0:
		tick_rate = 60
	var despawn_ticks := maxi(1, int(round(DEATH_DESPAWN_DELAY_SECONDS * float(tick_rate))))
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
	is_slow_walking = false
	_is_firing_net = false
	velocity = Vector2.ZERO
	show()
	_enable_hurtbox(headHurtBox)
	_enable_hurtbox(bodyHurtBox)
	_input_buffer.clear()
	_input_queue.clear()
	_last_input = null
	_last_processed_tick = 0
	_interpolator.snapshot_buffer.clear()
	set_process(true)
	set_physics_process(true)
	if movement_component:
		movement_component.set_process(true)
		movement_component.set_physics_process(true)
		movement_component.is_moving = false
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

func _wait_network_ticks(tick_count: int) -> void:
	for _i in range(maxi(0, tick_count)):
		await NetworkTick.tick_started
