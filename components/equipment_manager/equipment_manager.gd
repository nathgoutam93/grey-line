extends Node
class_name EquipmentManager

enum EquipmentSlot {
	PRIMARY = 0,
	SECONDARY = 1,
	MELEE = 2,
	UTILITY_1 = 3,
	UTILITY_2 = 4,
	UTILITY_3 = 5,
}

@export_group("Inventory")
@export var default_equipment: Array[EquipmentData] = []

@export_group("Components")
@export var player: PlayerController
@export var skeletal_character: PlayerMesh
@export var camera_shake: CameraShake

var equipped_items := {
	EquipmentSlot.PRIMARY: null,
	EquipmentSlot.SECONDARY: null,
	EquipmentSlot.MELEE: null,
	EquipmentSlot.UTILITY_1: null,
	EquipmentSlot.UTILITY_2: null,
	EquipmentSlot.UTILITY_3: null,
}

@export var current_slot := EquipmentSlot.MELEE

var current_item: EquipmentInstance = null
const WEAPON_SLOTS := [EquipmentSlot.PRIMARY, EquipmentSlot.SECONDARY, EquipmentSlot.MELEE]
const EXTRA_SLOTS := [EquipmentSlot.UTILITY_1, EquipmentSlot.UTILITY_2, EquipmentSlot.UTILITY_3]
var _equip_request_id := 0

func _ready():
	await get_tree().process_frame
	setup_default_equipment()

func setup_default_equipment():
	print(multiplayer.get_unique_id())

	for equipment_data in default_equipment:
		# instantiate and configure
		if equipment_data == null or equipment_data.instance_scene == null:
			push_warning("Invalid equipment data in default_equipment")
			continue
		# ensure slot is correct for weapon data
		if equipment_data is Weapon:
			(equipment_data as Weapon).ensure_slot_synced()
		var slot = equipment_data.slot
		if not _can_store_in_slot(equipment_data, slot):
			push_warning("Invalid equipment slot %d for '%s'" % [slot, equipment_data.name])
			continue
		var item = equipment_data.instance_scene.instantiate()
		# weapons/utilities need specialized setup where applicable
		if item is WeaponInstance:
			(item as WeaponInstance).set_weapon_data(equipment_data as Weapon)
		elif item is ThrowableInstance:
			(item as ThrowableInstance).set_throwable_data(equipment_data as ThrowableData)
		else:
			item.set_equipment_data(equipment_data)
		item.player = player
		skeletal_character.hand_socket.add_child(item)
		item.unequip()

		print("default equipment: %s slot=%d" % [equipment_data.name, slot])
		if equipped_items.has(slot) and equipped_items[slot] != null:
			push_warning("Default equipment slot %d already occupied, overwriting" % slot)
		equipped_items[slot] = item

	equip_slot(current_slot)

	# debug: how many were stored?
	var count := 0
	for k in equipped_items.keys():
		if equipped_items[k] != null:
			count += 1
	print("equipment_manager: %d default items stored" % count)


func get_current_item() -> EquipmentInstance:
	return current_item


func get_item_in_slot(slot: int) -> EquipmentInstance:
	return equipped_items.get(slot)


func equip_slot(slot: int) -> void:
	var new_item = equipped_items.get(slot)
	if not new_item:
		return

	_equip_request_id += 1
	var request_id := _equip_request_id

	# disconnect any previously bound signals from the old item
	var previous_item := current_item
	var unequip_delay := 0.0
	if previous_item:
		previous_item.disconnect("equip_action", _on_item_equip_action)
		previous_item.disconnect("use_action", _on_item_use_action)
		if previous_item.has_signal("shoot_action"):
			previous_item.disconnect("shoot_action", _on_item_shoot_action)
		if previous_item.has_signal("reload_action"):
			previous_item.disconnect("reload_action", _on_item_reload_action)
		if previous_item.equipment_data != null:
			unequip_delay = maxf(previous_item.equipment_data.unequip_time, 0.0)
		previous_item.force_interrupt()
		previous_item.unequip()

	if unequip_delay > 0.0:
		await get_tree().create_timer(unequip_delay).timeout
		if request_id != _equip_request_id:
			return

	current_slot = slot as EquipmentSlot
	current_item = new_item

	# connect the generic equipment signals
	current_item.connect("equip_action", _on_item_equip_action)
	current_item.connect("use_action", _on_item_use_action)
	# if the instance also emits weapon-specific actions, listen to them as well
	if current_item.has_signal("shoot_action"):
		current_item.connect("shoot_action", _on_item_shoot_action)
	if current_item.has_signal("reload_action"):
		current_item.connect("reload_action", _on_item_reload_action)
	apply_local_view()
	current_item.equip()


func apply_local_view() -> void:
	if not player or not player.is_local_player or not current_item:
		return

	var item_sprite := current_item.get_node_or_null("Sprite2D") as CanvasItem
	if item_sprite:
		item_sprite.material = null


func switch_to_next_item() -> void:
	var slots = WEAPON_SLOTS
	var start_index = slots.find(current_slot)
	for i in range(1, slots.size()):
		var next_slot = slots[(start_index + i) % slots.size()]
		if equipped_items[next_slot]:
			equip_slot(next_slot)
			return


func switch_to_previous_item() -> void:
	var slots = WEAPON_SLOTS
	var start_index = slots.find(current_slot)
	for i in range(1, slots.size()):
		var prev_slot = slots[(start_index - i + slots.size()) % slots.size()]
		if equipped_items[prev_slot]:
			equip_slot(prev_slot)
			return


func switch_to_slot(slot: int) -> void:
	if slot == current_slot:
		return
	equip_slot(slot)


func _can_store_in_slot(equipment_data: EquipmentData, slot: int) -> bool:
	if equipment_data is Weapon:
		return WEAPON_SLOTS.has(slot)
	return EXTRA_SLOTS.has(slot)

# provide a pickup interface so the player controller can call this directly
func pickup_weapon(pickup: WeaponPickup) -> bool:
	if pickup == null or pickup.weapon_data == null:
		return false
	var wdata = pickup.weapon_data
	wdata.ensure_slot_synced()
	if not WEAPON_SLOTS.has(wdata.slot):
		return false
	# instantiate the appropriate instance
	var item = wdata.instance_scene.instantiate() as EquipmentInstance
	if item is WeaponInstance:
		# weapon-specific initialization
		var wi = item as WeaponInstance
		wi.set_weapon_data(wdata)
		# retain ammo values from the pickup (bug fix)
		wi.ammo_in_mag = pickup.ammo_in_mag
		wi.ammo_reserve = pickup.ammo_reserve
	else:
		item.set_equipment_data(wdata)
	item.player = player
	skeletal_character.hand_socket.add_child(item)
	item.unequip()

	var slot = wdata.slot
	# drop any existing item in that slot so the new one can occupy it
	if equipped_items.has(slot) and equipped_items[slot] != null:
		equipped_items[slot].drop()
		equipped_items[slot] = null

	equipped_items[slot] = item
	if current_slot == EquipmentSlot.MELEE:
		equip_slot(slot)

	return true

func drop_current_item() -> void:
	if current_item:
		if EXTRA_SLOTS.has(current_slot):
			return
		# respect data flag
		if current_item.equipment_data and not current_item.equipment_data.can_drop:
			return
		# match the lifecycle WeaponManager implements so drops behave consistently
		# disconnect any signals just in case
		if current_item.has_signal("equip_action"):
			current_item.disconnect("equip_action", _on_item_equip_action)
		if current_item.has_signal("use_action"):
			current_item.disconnect("use_action", _on_item_use_action)
		if current_item.has_signal("shoot_action"):
			current_item.disconnect("shoot_action", _on_item_shoot_action)
		if current_item.has_signal("reload_action"):
			current_item.disconnect("reload_action", _on_item_reload_action)
		current_item.force_interrupt()
		# let the instance handle its own drop (spawn pickup, free, etc.)
		current_item.drop()
		current_item = null
		equipped_items[current_slot] = null
		switch_to_next_item()


func _play_skeletal_animation(animation_name: String) -> void:
	if animation_name == "" or animation_name == null:
		return
	if not skeletal_character.anim_player.has_animation(animation_name):
		push_warning("Equipment manager tried to play missing animation '%s'" % animation_name)
		return
	skeletal_character.anim_player.play(animation_name)

func _on_item_use_action(animation_name: String, _sound_stream: AudioStream) -> void:
	_play_skeletal_animation(animation_name)
	if current_item is WeaponInstance:
		camera_shake.apply(current_item.data.camera_shake_strength)

func _on_item_shoot_action(animation_name: String, _sound_stream: AudioStream) -> void:
	_play_skeletal_animation(animation_name)
	if current_item is WeaponInstance:
		camera_shake.apply(current_item.data.camera_shake_strength)

func _on_item_reload_action(animation_name: String, _sound_stream: AudioStream) -> void:
	_play_skeletal_animation(animation_name)


func _on_item_equip_action(animation_name: String, _sound_stream: AudioStream) -> void:
	skeletal_character.anim_player.play(animation_name)
