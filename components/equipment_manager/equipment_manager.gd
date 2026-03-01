extends Node
class_name EquipmentManager

enum EquipmentSlot {
	PRIMARY = 0,
	SECONDARY = 1,
	MELEE = 2,
	UTILITY = 3,
	THROWABLE = 4,
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
	EquipmentSlot.UTILITY: null,
	EquipmentSlot.THROWABLE: null,
}

@export var current_slot := EquipmentSlot.MELEE

var current_item: EquipmentInstance = null

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
		var item = equipment_data.instance_scene.instantiate()
		# weapons need their own initializer so ammo counts are filled
		if item is WeaponInstance:
			(item as WeaponInstance).set_weapon_data(equipment_data as Weapon)
		else:
			item.set_equipment_data(equipment_data)
		item.player = player
		skeletal_character.hand_socket.add_child(item)
		item.unequip()

		var slot = equipment_data.slot
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
	
	# disconnect any previously bound signals from the old item
	if current_item:
		current_item.disconnect("equip_action", _on_item_equip_action)
		current_item.disconnect("use_action", _on_item_use_action)
		if current_item.has_signal("shoot_action"):
			current_item.disconnect("shoot_action", _on_item_shoot_action)
		if current_item.has_signal("reload_action"):
			current_item.disconnect("reload_action", _on_item_reload_action)
		current_item.unequip()
		current_item.force_interrupt()

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
	var slots = [EquipmentSlot.PRIMARY, EquipmentSlot.SECONDARY, EquipmentSlot.MELEE]
	var start_index = slots.find(current_slot)
	for i in range(1, slots.size()):
		var next_slot = slots[(start_index + i) % slots.size()]
		if equipped_items[next_slot]:
			equip_slot(next_slot)
			return


func switch_to_previous_item() -> void:
	var slots = [EquipmentSlot.PRIMARY, EquipmentSlot.SECONDARY, EquipmentSlot.MELEE]
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

func drop_current_item() -> void:
	if current_item:
		current_item.force_interrupt()
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
