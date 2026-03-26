extends Resource
class_name PlayerData

@export var version: int = 1
@export var username: String = ""
@export var avatar_id: String = ""
@export var onboarding_completed: bool = false
@export var keybinds: Dictionary = {}
@export var touch_layout: Dictionary = {}

func to_dict() -> Dictionary:
	return {
		"version": version,
		"username": username,
		"avatar_id": avatar_id,
		"onboarding_completed": onboarding_completed,
		"keybinds": keybinds.duplicate(true),
		"touch_layout": touch_layout.duplicate(true),
	}

static func from_dict(raw: Dictionary) -> PlayerData:
	var data := PlayerData.new()
	data.version = int(raw.get("version", 1))
	data.username = String(raw.get("username", ""))
	data.avatar_id = String(raw.get("avatar_id", ""))
	data.onboarding_completed = bool(raw.get("onboarding_completed", false))

	var keybinds_value: Variant = raw.get("keybinds", {})
	if keybinds_value is Dictionary:
		data.keybinds = (keybinds_value as Dictionary).duplicate(true)

	var touch_layout_value: Variant = raw.get("touch_layout", {})
	if touch_layout_value is Dictionary:
		data.touch_layout = (touch_layout_value as Dictionary).duplicate(true)

	return data
