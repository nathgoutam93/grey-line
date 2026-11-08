extends RefCounted
class_name DestructionMaterial

const SOFT := 0
const REINFORCED := 1
const HARD := 2
const KIND_BULLET := 0
const KIND_EXPLOSIVE := 1
const KIND_MELEE := 2

static func can_damage(material: int, kind: int) -> bool:
	if kind not in [KIND_BULLET, KIND_EXPLOSIVE, KIND_MELEE]:
		return false
	return material == SOFT or (material == REINFORCED and kind == KIND_EXPLOSIVE)

static func sound_factor(material: int) -> float:
	match material:
		SOFT: return 0.6
		REINFORCED: return 0.4
	return 0.35
