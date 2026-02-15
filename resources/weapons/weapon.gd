extends Resource
class_name Weapon

enum WeaponType {PRIMARY, SECONDARY, MELEE}

@export var name: String
@export var icon: Texture2D

@export var weapon_type: WeaponType = WeaponType.SECONDARY

@export var damage := 0
@export var d_range := 1000.0

@export var mag_size := 0
@export var uses_ammo := true

@export var is_reloadable := true
@export var reload_duration := 0.5

@export var equip_duration := 0.25

@export var speed_multiplier := 1.0
@export var camera_shake_strength := 30.0

@export var mode: WeaponAttackMode = preload("res://resources/weapon_modes/single.tres")

@export var animations := {
	"equip": "",
	"idle": "",
	"move": "",
	"attack": "",
	"reload": "",
}

@export var sounds: WeaponSoundData

@export var weapon_scene: PackedScene
@export var pickup_scene: PackedScene

func to_dict() -> Dictionary:
	return {
		"name": name,
		"weapon_type": weapon_type,
		"damage": damage,
		"d_range": d_range,
		"mag_size": mag_size,
		"uses_ammo": uses_ammo,
		"is_reloadable": is_reloadable,
		"reload_duration": reload_duration,
		"equip_duration": equip_duration,
		"speed_multiplier": speed_multiplier,
		"camera_shake_strength": camera_shake_strength,
		"animations": animations.duplicate(),
		"mode": mode.resource_path, # send as path
		"sounds": sounds.resource_path, # send as path
		"weapon_scene": weapon_scene.resource_path,
		"pickup_scene": pickup_scene.resource_path,
	}

static func new_from_dict(dict: Dictionary) -> Weapon:
	var w = Weapon.new()
	w.name = dict["name"]
	w.weapon_type = dict["weapon_type"]
	w.damage = dict["damage"]
	w.d_range = dict["d_range"]
	w.mag_size = dict["mag_size"]
	w.uses_ammo = dict["uses_ammo"]
	w.is_reloadable = dict["is_reloadable"]
	w.reload_duration = dict["reload_duration"]
	w.equip_duration = dict["equip_duration"]
	w.speed_multiplier = dict["speed_multiplier"]
	w.camera_shake_strength = dict["camera_shake_strength"]
	w.animations = dict["animations"]
	w.mode = load(dict["mode"])
	w.sounds = load(dict["sounds"])
	w.weapon_scene = load(dict["weapon_scene"])
	w.pickup_scene = load(dict["pickup_scene"])
	return w
