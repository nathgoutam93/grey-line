extends RefCounted
class_name DestructionMaterial

const SOFT := 0
const REINFORCED := 1
const HARD := 2
const KIND_BULLET := 0
const KIND_EXPLOSIVE := 1
const KIND_MELEE := 2

static func is_valid_kind(kind: int) -> bool:
	return kind in [KIND_BULLET, KIND_EXPLOSIVE, KIND_MELEE]

## Walls never take damage. Materials still decide how much sound passes
## through (sound_factor); doors and breakable props are the destructibles.
static func can_damage(_material: int, _kind: int) -> bool:
	return false

static func sound_factor(material: int) -> float:
	match material:
		SOFT: return 0.6
		REINFORCED: return 0.4
	return 0.35
