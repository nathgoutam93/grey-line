extends Resource
class_name Weapon

enum WeaponType {PRIMARY, SECONDARY, MELEE}

@export var name: String

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
