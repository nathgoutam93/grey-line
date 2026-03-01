extends EquipmentData
class_name Weapon

enum WeaponType {PRIMARY, SECONDARY, MELEE}

@export var weapon_type: WeaponType = WeaponType.SECONDARY

@export var damage := 0
@export var d_range := 1000.0

@export var mag_size := 0
@export var mag_count := 4
@export var uses_ammo := true

@export var is_reloadable := true
@export var reload_duration := 0.5

@export var speed_multiplier := 1.0
@export var camera_shake_strength := 30.0

@export var mode: WeaponAttackMode = preload("res://resources/weapon_modes/single.tres")

@export var pickup_scene: PackedScene


## Convenience property for backward compatibility
var weapon_scene: PackedScene:
	get: return instance_scene
	set(value): instance_scene = value


func _init() -> void:
	_sync_weapon_type_to_slot()


func _sync_weapon_type_to_slot() -> void:
	match weapon_type:
		WeaponType.PRIMARY:
			slot = EquipmentData.EquipmentSlot.PRIMARY
		WeaponType.SECONDARY:
			slot = EquipmentData.EquipmentSlot.SECONDARY
		WeaponType.MELEE:
			slot = EquipmentData.EquipmentSlot.MELEE


# public helper called at runtime when data is used
func ensure_slot_synced() -> void:
	# only update when not already correct, to avoid unnecessary changes
	var correct_slot := slot
	_sync_weapon_type_to_slot()
	# if sync changed slot, the resource will update in memory but not file


func to_dict() -> Dictionary:
	return {
		"name": name,
		"weapon_type": weapon_type,
		"damage": damage,
		"d_range": d_range,
		"mag_size": mag_size,
		"mag_count": mag_count,
		"uses_ammo": uses_ammo,
		"is_reloadable": is_reloadable,
		"reload_duration": reload_duration,
		"equip_time": equip_time,
		"speed_multiplier": speed_multiplier,
		"camera_shake_strength": camera_shake_strength,
		"animations": animations.duplicate(),
		"mode": mode.resource_path,
		"sounds": sounds.resource_path,
		"instance_scene": instance_scene.resource_path,
		"pickup_scene": pickup_scene.resource_path,
		"slot": slot,
	}

static func new_from_dict(dict: Dictionary) -> Weapon:
	var w = Weapon.new()
	w.name = dict["name"]
	w.weapon_type = dict["weapon_type"]
	w.damage = dict["damage"]
	w.d_range = dict["d_range"]
	w.mag_size = dict["mag_size"]
	w.mag_count = dict.get("mag_count", 4)
	w.uses_ammo = dict["uses_ammo"]
	w.is_reloadable = dict["is_reloadable"]
	w.reload_duration = dict["reload_duration"]
	w.equip_time = dict.get("equip_time", dict.get("equip_duration", 0.25))
	w.speed_multiplier = dict["speed_multiplier"]
	w.camera_shake_strength = dict["camera_shake_strength"]
	w.animations = dict["animations"]
	w.mode = load(dict["mode"])
	w.sounds = load(dict["sounds"])
	w.instance_scene = load(dict.get("instance_scene", dict.get("weapon_scene")))
	w.pickup_scene = load(dict["pickup_scene"])
	w.slot = dict.get("slot", w.slot)
	return w
