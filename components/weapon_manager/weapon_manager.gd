extends Node
class_name WeaponManager

signal weapon_equipped(new_weapon)

enum WeaponSlot {PRIMARY, SECONDARY, MELEE}

@export_group("Inventory")
@export var default_weapons: Array[Weapon] = []

@export_group("Components")
@export var player: PlayerController
@export var skeletal_character: PlayerMesh
@export var camera_shake: CameraShake

var weapon_slots := {
	WeaponSlot.PRIMARY: null,
	WeaponSlot.SECONDARY: null,
	WeaponSlot.MELEE: null
}

var current_slot := WeaponSlot.PRIMARY
var current_weapon: WeaponInstance = null

func _ready():
	setup_default_weapons()


func get_current_weapon_name() -> String:
	return current_weapon.data.name if current_weapon else ""

func get_ammo_in_mag() -> int:
	return current_weapon.ammo_in_mag if current_weapon else 0

func get_mag_size() -> int:
	return current_weapon.data.mag_size if current_weapon else 0

func get_weapon_in_slot(slot: int):
	return weapon_slots.get(slot)


func setup_default_weapons():
	for w in default_weapons:
		var wi = w.weapon_scene.instantiate()
		wi.set_weapon_data(w)
		wi.player = player
		skeletal_character.hand_socket.add_child(wi)
		wi.unequip()

		match w.weapon_type:
			WeaponSlot.PRIMARY: weapon_slots[WeaponSlot.PRIMARY] = wi
			WeaponSlot.SECONDARY: weapon_slots[WeaponSlot.SECONDARY] = wi
			WeaponSlot.MELEE: weapon_slots[WeaponSlot.MELEE] = wi

	equip_slot(current_slot)

func equip_slot(slot: int):
	var new_weapon = weapon_slots.get(slot)
	if not new_weapon:
		return
	
	if current_weapon:
		current_weapon.disconnect("equip_action", _on_weapon_equip_action)
		current_weapon.disconnect("shoot_action", _on_weapon_shoot_action)
		current_weapon.disconnect("reload_action", _on_weapon_reload_action)
		current_weapon.unequip()
		current_weapon.force_interrupt()

	current_slot = slot as WeaponSlot
	current_weapon = new_weapon

	current_weapon.connect("equip_action", _on_weapon_equip_action)
	current_weapon.connect("shoot_action", _on_weapon_shoot_action)
	current_weapon.connect("reload_action", _on_weapon_reload_action)
	current_weapon.equip()

	emit_signal("weapon_equipped", slot)

func switch_to_next_weapon():
	var slots = [WeaponSlot.PRIMARY, WeaponSlot.SECONDARY, WeaponSlot.MELEE]
	var start_index = slots.find(current_slot)
	for i in range(1, slots.size()):
		var next_slot = slots[(start_index + i) % slots.size()]
		if weapon_slots[next_slot]:
			equip_slot(next_slot)
			return

func switch_to_previous_weapon():
	var slots = [WeaponSlot.PRIMARY, WeaponSlot.SECONDARY, WeaponSlot.MELEE]
	var start_index = slots.find(current_slot)
	for i in range(1, slots.size()):
		var prev_slot = slots[(start_index - i + slots.size()) % slots.size()]
		if weapon_slots[prev_slot]:
			equip_slot(prev_slot)
			return

func pickup_weapon(pickup: WeaponPickup):
	var wi = pickup.weapon_data.weapon_scene.instantiate()
	wi.set_weapon_data(pickup.weapon_data)
	wi.ammo_in_mag = pickup.ammo_in_mag
	wi.player = player
	skeletal_character.hand_socket.add_child(wi)
	wi.unequip()

	match pickup.weapon_data.weapon_type:
		WeaponSlot.PRIMARY: drop_slot(WeaponSlot.PRIMARY)
		WeaponSlot.SECONDARY: drop_slot(WeaponSlot.SECONDARY)
		WeaponSlot.MELEE: drop_slot(WeaponSlot.MELEE)
	
	weapon_slots[pickup.weapon_data.weapon_type] = wi
	
	if current_slot == WeaponSlot.MELEE:
		equip_slot(pickup.weapon_data.weapon_type)

	return true

func drop_weapon():
	if (drop_slot(current_slot)):
		switch_to_next_weapon()

func drop_slot(slot: int):
	if slot == WeaponSlot.MELEE:
		return false
		
	var weapon = weapon_slots[slot]
	if not weapon:
		return false

	weapon.disconnect("equip_action", _on_weapon_equip_action)
	weapon.disconnect("shoot_action", _on_weapon_shoot_action)
	weapon.disconnect("reload_action", _on_weapon_reload_action)
	weapon.unequip()
	weapon.drop()

	weapon_slots[slot] = null
	if current_slot == slot:
		current_weapon = null

	return true


func _on_weapon_shoot_action(animation_name: String, _sound_stream: AudioStream):
	if multiplayer.is_server():
		_play_shoot_animation_for_all.rpc(animation_name)

func _on_weapon_reload_action(animation_name: String, _sound_stream: AudioStream):
	if multiplayer.is_server():
		_play_reload_animation_for_all.rpc(animation_name)

func _on_weapon_equip_action(animation_name: String, _sound_stream: AudioStream):
	if multiplayer.is_server():
		_play_equip_animation_for_all.rpc(animation_name)


@rpc("authority", "call_local", "reliable")
func _play_reload_animation_for_all(animation_name: String):
	skeletal_character.anim_player.play(animation_name)

@rpc("authority", "call_local", "reliable")
func _play_shoot_animation_for_all(animation_name: String):
	skeletal_character.anim_player.play(animation_name)
	camera_shake.apply(current_weapon.data.camera_shake_strength)

@rpc("authority", "call_local", "reliable")
func _play_equip_animation_for_all(animation_name: String):
	skeletal_character.anim_player.play(animation_name)
