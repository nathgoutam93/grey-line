extends Node2D
class_name EquipmentInstance

## Base equipment instance for all equipment types

var equipment_data: EquipmentData

var player: PlayerController

var is_equipped := false
var is_locked := true

var _equip_ticks_remaining := 0

signal equip_action(animation_name: String, sound_stream: AudioStream)
signal use_action(animation_name: String, sound_stream: AudioStream)

#var _equipment_stack_trace: String = ""

func _ready() -> void:
	if not NetworkTick.tick_started.is_connected(_on_network_tick):
		NetworkTick.tick_started.connect(_on_network_tick)


func _on_network_tick(_tick: int) -> void:
	_tick_update()


func set_equipment_data(data: EquipmentData) -> void:
	equipment_data = data


func _lock() -> void:
	is_locked = true
	#_equipment_stack_trace = get_stack()[1]


func _unlock() -> void:
	is_locked = false


func force_interrupt() -> void:
	is_locked = false
	_equip_ticks_remaining = 0
	stop_use()


func unequip() -> void:
	hide()
	is_equipped = false


func equip() -> void:
	_lock()
	_equip_ticks_remaining = _seconds_to_ticks(equipment_data.equip_time)
	
	unequip()
	show()
	
	emit_signal("equip_action", equipment_data.animations.get("equip", ""), equipment_data.sounds.equip_sound if equipment_data.sounds else null)
	
	if has_node("AnimationPlayer"):
		get_node("AnimationPlayer").play("equip")
	
	_play_equip_sound()
	
	if _equip_ticks_remaining <= 0:
		_unlock()


func start_use() -> void:
	# Override in subclass
	pass


func stop_use() -> void:
	# Override in subclass
	pass


func _tick_update() -> void:
	if _equip_ticks_remaining > 0:
		_equip_ticks_remaining -= 1
		if _equip_ticks_remaining == 0:
			_unlock()
	
	# Subclass hook
	_tick_update_override()


func _tick_update_override() -> void:
	# Override in subclass for custom tick logic
	pass


func _seconds_to_ticks(seconds: float) -> int:
	return int(ceil(max(seconds, 0.0) * float(NetworkTick.tick_rate)))


func _play_equip_sound() -> void:
	# Override in subclass if needed
	pass


## Server only: tells the owning player it is making a sound audible up to
## `max_distance`, so hidden players in range still get its position and hear
## it (see PlayerController.report_noise / WorldSnapshotService).
func _report_noise(max_distance: float, stream: AudioStream) -> void:
	if player == null or not is_instance_valid(player):
		return
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	var seconds := 0.5
	if stream != null:
		seconds = stream.get_length()
	player.report_noise(max_distance, clampf(seconds, 0.25, 3.0))


## How far this item's "use" sound (gunshot, throw) carries. Lets the server
## make the player audible before the first shot is broadcast.
func get_use_noise_radius() -> float:
	return 0.0


func drop() -> void:
	force_interrupt()
	unequip()
	queue_free()
