extends Resource
class_name EquipmentData

enum EquipmentSlot {
	PRIMARY = 0,
	SECONDARY = 1,
	MELEE = 2,
	UTILITY = 3,
	THROWABLE = 4,
}

## Generic equipment properties

@export var name: String

@export var icon: Texture2D

@export var equip_time: float = 0.25
@export var unequip_time: float = 0.0

@export var slot: EquipmentSlot = EquipmentSlot.MELEE # MELEE by default

@export var animations := {
	"equip": "",
	"idle": "",
	"move": "",
	"use": "",
	# weapon-specific names, may be overridden by subclasses
	"attack": "",
	"reload": "",
}

@export var sounds: Resource = null

@export var instance_scene: PackedScene

# whether the item can be dropped/picked up in the world
@export var can_drop: bool = true
