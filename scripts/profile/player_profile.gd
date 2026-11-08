extends Node
class_name PlayerProfileStore

const SAVE_PATH := "user://player_profile.json"
## Command-line user arg (after `--`) that keeps the profile in memory only:
## defaults are loaded and nothing is written. Used by tests/run_tests.sh so
## test runs never touch the real profile.
const EPHEMERAL_ARG := "--ephemeral-profile"
const PROFILE_VERSION := 1
const DEFAULT_PLAYER_NAME := "Player"
const DEFAULT_AVATAR_ID := "avatar_01"
var TRACKED_ACTIONS: Array[String] = [
	"move_left",
	"move_right",
	"move_up",
	"move_down",
	"shoot",
	"reload",
	"scroll_up",
	"scroll_down",
	"slow_walk",
	"drop",
	"pickup",
	"primary",
	"secondary",
	"malee",
	"stats",
	"slot_extra_q",
	"slot_extra_e",
	"slot_extra_x",
]
var TOUCH_CONTROL_IDS: Array[String] = [
	"MovementJoystick",
	"Shoot",
	"Headshot",
	"Reload",
	"Walk",
	"TouchAimZone",
]
const AVATAR_CATALOG := {
	"avatar_01": "res://assets/sprites/character/head.png",
	"avatar_02": "res://assets/sprites/character2/head.png",
	"avatar_03": "res://assets/sprites/icons/headshot-icon.png",
	"avatar_04": "res://assets/sprites/icons/kill_icon.png",
}
const DEFAULT_TOUCH_LAYOUT := {
	"MovementJoystick": {
		"kind": "control_rect",
		"anchor_left": 0.0,
		"anchor_top": 1.0,
		"anchor_right": 0.0,
		"anchor_bottom": 1.0,
		"offset_left_norm": 0.07890625,
		"offset_top_norm": -0.53194444,
		"offset_right_norm": 0.27421875,
		"offset_bottom_norm": -0.18472222,
	},
	"TouchAimZone": {
		"kind": "control_rect",
		"anchor_left": 0.5,
		"anchor_top": 0.5,
		"anchor_right": 1.0,
		"anchor_bottom": 1.0,
		"offset_left_norm": 0.0,
		"offset_top_norm": -0.49166667,
		"offset_right_norm": 0.0,
		"offset_bottom_norm": 0.0,
	},
	"Shoot": {
		"kind": "touch_button",
		"position_norm": [0.04453125, 0.05555556],
		"scale": [1.0, 1.0],
	},
	"Headshot": {
		"kind": "touch_button",
		"position_norm": [0.29609375, 0.39722222],
		"scale": [1.0, 1.0],
	},
	"Reload": {
		"kind": "touch_button",
		"position_norm": [0.1859375, 0.23888889],
		"scale": [0.7, 0.7],
	},
	"Walk": {
		"kind": "touch_button",
		"position_norm": [0.32, 0.74],
		"scale": [1.0, 1.0],
	},
}

var _profile: PlayerData = PlayerData.new()
var _default_keybinds: Dictionary = {}
## False when started with EPHEMERAL_ARG: load_profile/save_profile skip disk.
var persistence_enabled := true

func _ready() -> void:
	persistence_enabled = not OS.get_cmdline_user_args().has(EPHEMERAL_ARG)
	_default_keybinds = _capture_current_keybinds()
	load_profile()
	apply_keybinds_to_input_map()

func get_username() -> String:
	return _profile.username

func set_username(name: String) -> void:
	_profile.username = _sanitize_profile_username(name)
	save_profile()

func get_avatar_id() -> String:
	return _profile.avatar_id

func is_profile_completed() -> bool:
	return _profile.onboarding_completed

func complete_profile_setup() -> void:
	var has_username := _sanitize_profile_username(_profile.username).strip_edges() != ""
	var has_avatar := AVATAR_CATALOG.has(_profile.avatar_id)
	_profile.onboarding_completed = has_username and has_avatar
	save_profile()

func set_avatar_id(avatar_id: String) -> void:
	if AVATAR_CATALOG.has(avatar_id):
		_profile.avatar_id = avatar_id
	else:
		_profile.avatar_id = DEFAULT_AVATAR_ID
	save_profile()

func get_avatar_catalog() -> Dictionary:
	return AVATAR_CATALOG.duplicate(true)

func get_keybinds() -> Dictionary:
	return _profile.keybinds.duplicate(true)

func set_action_binding(action: String, events: Array) -> void:
	if not TRACKED_ACTIONS.has(action):
		return
	var encoded: Array[String] = []
	for event_variant in events:
		if event_variant is InputEvent:
			encoded.append(var_to_str(event_variant))
	_profile.keybinds[action] = encoded
	_apply_action_bindings(action)
	save_profile()

func apply_keybinds_to_input_map() -> void:
	for action in TRACKED_ACTIONS:
		_apply_action_bindings(action)

func reset_keybinds_to_default() -> void:
	_profile.keybinds = _default_keybinds.duplicate(true)
	apply_keybinds_to_input_map()
	save_profile()

func get_touch_layout() -> Dictionary:
	return _profile.touch_layout.duplicate(true)

func get_touch_control_position_norm(control_id: String) -> Vector2:
	var layout_variant: Variant = _profile.touch_layout.get(control_id, null)
	if not (layout_variant is Dictionary):
		return Vector2.ZERO
	var layout: Dictionary = layout_variant as Dictionary
	var kind := String(layout.get("kind", ""))
	if kind == "touch_button":
		var position_values: Variant = layout.get("position_norm", [])
		if position_values is Array and position_values.size() >= 2:
			return Vector2(float(position_values[0]), float(position_values[1]))
		return Vector2.ZERO

	if kind == "control_rect":
		var anchor_left := float(layout.get("anchor_left", 0.0))
		var anchor_right := float(layout.get("anchor_right", 0.0))
		var anchor_top := float(layout.get("anchor_top", 0.0))
		var anchor_bottom := float(layout.get("anchor_bottom", 0.0))
		var offset_left_norm := float(layout.get("offset_left_norm", 0.0))
		var offset_right_norm := float(layout.get("offset_right_norm", 0.0))
		var offset_top_norm := float(layout.get("offset_top_norm", 0.0))
		var offset_bottom_norm := float(layout.get("offset_bottom_norm", 0.0))
		return Vector2(
			((anchor_left + offset_left_norm) + (anchor_right + offset_right_norm)) * 0.5,
			((anchor_top + offset_top_norm) + (anchor_bottom + offset_bottom_norm)) * 0.5
		)

	return Vector2.ZERO

func set_touch_control_position_norm(control_id: String, position_norm: Vector2) -> void:
	if not TOUCH_CONTROL_IDS.has(control_id):
		return
	var clamped_position := Vector2(clampf(position_norm.x, 0.0, 1.0), clampf(position_norm.y, 0.0, 1.0))
	var layout_variant: Variant = _profile.touch_layout.get(control_id, null)
	if not (layout_variant is Dictionary):
		layout_variant = DEFAULT_TOUCH_LAYOUT.get(control_id, null)
	if not (layout_variant is Dictionary):
		return

	var layout: Dictionary = (layout_variant as Dictionary).duplicate(true)
	var kind := String(layout.get("kind", ""))
	if kind == "touch_button":
		layout["position_norm"] = [clamped_position.x, clamped_position.y]
		_profile.touch_layout[control_id] = layout
		save_profile()
		return

	if kind == "control_rect":
		var anchor_left := float(layout.get("anchor_left", 0.0))
		var anchor_right := float(layout.get("anchor_right", 0.0))
		var anchor_top := float(layout.get("anchor_top", 0.0))
		var anchor_bottom := float(layout.get("anchor_bottom", 0.0))
		var offset_left_norm := float(layout.get("offset_left_norm", 0.0))
		var offset_right_norm := float(layout.get("offset_right_norm", 0.0))
		var offset_top_norm := float(layout.get("offset_top_norm", 0.0))
		var offset_bottom_norm := float(layout.get("offset_bottom_norm", 0.0))
		var absolute_left := anchor_left + offset_left_norm
		var absolute_right := anchor_right + offset_right_norm
		var absolute_top := anchor_top + offset_top_norm
		var absolute_bottom := anchor_bottom + offset_bottom_norm
		var half_width := (absolute_right - absolute_left) * 0.5
		var half_height := (absolute_bottom - absolute_top) * 0.5
		absolute_left = clamped_position.x - half_width
		absolute_right = clamped_position.x + half_width
		absolute_top = clamped_position.y - half_height
		absolute_bottom = clamped_position.y + half_height
		layout["offset_left_norm"] = absolute_left - anchor_left
		layout["offset_right_norm"] = absolute_right - anchor_right
		layout["offset_top_norm"] = absolute_top - anchor_top
		layout["offset_bottom_norm"] = absolute_bottom - anchor_bottom
		_profile.touch_layout[control_id] = layout
		save_profile()

func set_touch_control_layout(control_id: String, layout: Dictionary) -> void:
	if not TOUCH_CONTROL_IDS.has(control_id):
		return
	_profile.touch_layout[control_id] = layout.duplicate(true)
	save_profile()

func capture_touch_layout_from_controls(controls_root: Control) -> void:
	if controls_root == null:
		return
	var changed := false
	for control_id in TOUCH_CONTROL_IDS:
		var control := controls_root.get_node_or_null(control_id)
		if control == null:
			continue
		var serialized := _serialize_touch_control(control)
		if serialized.is_empty():
			continue
		_profile.touch_layout[control_id] = serialized
		changed = true
	if changed:
		save_profile()

func ensure_touch_layout_defaults_from_controls(controls_root: Control) -> void:
	if controls_root == null:
		return
	var changed := false
	for control_id in TOUCH_CONTROL_IDS:
		if _profile.touch_layout.has(control_id):
			continue
		var control := controls_root.get_node_or_null(control_id)
		if control == null:
			continue
		var serialized := _serialize_touch_control(control)
		if serialized.is_empty():
			continue
		_profile.touch_layout[control_id] = serialized
		changed = true
	if changed:
		save_profile()

func apply_touch_layout_to_controls(controls_root: Control) -> void:
	if controls_root == null:
		return
	for control_id in TOUCH_CONTROL_IDS:
		var layout_variant: Variant = _profile.touch_layout.get(control_id, null)
		if not (layout_variant is Dictionary):
			continue
		var control := controls_root.get_node_or_null(control_id)
		if control == null:
			continue
		_apply_touch_layout(control, layout_variant as Dictionary)

func reset_touch_layout_to_default() -> void:
	_profile.touch_layout = DEFAULT_TOUCH_LAYOUT.duplicate(true)
	save_profile()

func reset_to_defaults() -> void:
	_profile = _default_profile()
	apply_keybinds_to_input_map()
	save_profile()

func load_profile() -> void:
	if not persistence_enabled:
		_profile = _default_profile()
		return
	if not FileAccess.file_exists(SAVE_PATH):
		_profile = _default_profile()
		save_profile()
		return

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		_profile = _default_profile()
		save_profile()
		return

	var raw_json := file.get_as_text().strip_edges()
	if raw_json == "":
		_profile = _default_profile()
		save_profile()
		return
	var parser := JSON.new()
	var parse_error := parser.parse(raw_json)
	if parse_error != OK:
		_profile = _default_profile()
		save_profile()
		return
	var parsed: Variant = parser.data
	if not (parsed is Dictionary):
		_profile = _default_profile()
		save_profile()
		return

	_profile = PlayerData.from_dict(parsed as Dictionary)
	_sanitize_profile_in_place()
	save_profile()

func save_profile() -> void:
	_sanitize_profile_in_place()
	if not persistence_enabled:
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Failed to open profile save file: %s" % SAVE_PATH)
		return
	file.store_string(JSON.stringify(_profile.to_dict(), "\t"))

func _default_profile() -> PlayerData:
	var data := PlayerData.new()
	data.version = PROFILE_VERSION
	data.username = ""
	data.avatar_id = DEFAULT_AVATAR_ID
	data.onboarding_completed = false
	data.keybinds = _default_keybinds.duplicate(true)
	data.touch_layout = DEFAULT_TOUCH_LAYOUT.duplicate(true)
	return data

func _sanitize_profile_in_place() -> void:
	_profile.version = PROFILE_VERSION
	_profile.username = _sanitize_profile_username(_profile.username)
	if not AVATAR_CATALOG.has(_profile.avatar_id):
		_profile.avatar_id = DEFAULT_AVATAR_ID
	var has_username := _profile.username.strip_edges() != ""
	var has_avatar := AVATAR_CATALOG.has(_profile.avatar_id)
	_profile.onboarding_completed = bool(_profile.onboarding_completed) and has_username and has_avatar
	if not _profile.onboarding_completed and has_username and has_avatar:
		# Backfill completion for profiles created before onboarding flag existed.
		_profile.onboarding_completed = true

	if not (_profile.keybinds is Dictionary):
		_profile.keybinds = {}
	for action in TRACKED_ACTIONS:
		if not _profile.keybinds.has(action):
			_profile.keybinds[action] = _default_keybinds.get(action, []).duplicate(true)
			continue
		var encoded_variant: Variant = _profile.keybinds.get(action)
		if not (encoded_variant is Array):
			_profile.keybinds[action] = _default_keybinds.get(action, []).duplicate(true)
			continue
		var sanitized_events: Array[String] = []
		for event_variant in encoded_variant:
			var event := _deserialize_input_event(event_variant)
			if event != null:
				sanitized_events.append(var_to_str(event))
		if sanitized_events.is_empty():
			sanitized_events = _default_keybinds.get(action, []).duplicate(true)
		_profile.keybinds[action] = sanitized_events

	if not (_profile.touch_layout is Dictionary):
		_profile.touch_layout = DEFAULT_TOUCH_LAYOUT.duplicate(true)
	for control_id in TOUCH_CONTROL_IDS:
		if not _profile.touch_layout.has(control_id):
			var default_layout: Variant = DEFAULT_TOUCH_LAYOUT.get(control_id, null)
			if default_layout is Dictionary:
				_profile.touch_layout[control_id] = (default_layout as Dictionary).duplicate(true)

func _apply_action_bindings(action: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	InputMap.action_erase_events(action)

	var encoded_variant: Variant = _profile.keybinds.get(action, _default_keybinds.get(action, []))
	if encoded_variant is Array:
		for event_variant in encoded_variant:
			var event := _deserialize_input_event(event_variant)
			if event != null:
				InputMap.action_add_event(action, event)

	if InputMap.action_get_events(action).is_empty():
		_restore_default_action_bindings(action)

func _restore_default_action_bindings(action: String) -> void:
	InputMap.action_erase_events(action)
	var defaults_variant: Variant = _default_keybinds.get(action, [])
	if defaults_variant is Array:
		for event_variant in defaults_variant:
			var event := _deserialize_input_event(event_variant)
			if event != null:
				InputMap.action_add_event(action, event)

func _capture_current_keybinds() -> Dictionary:
	var result := {}
	for action in TRACKED_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var encoded: Array[String] = []
		for event in InputMap.action_get_events(action):
			encoded.append(var_to_str(event))
		result[action] = encoded
	return result

func _deserialize_input_event(serialized: Variant) -> InputEvent:
	if not (serialized is String):
		return null
	var parsed: Variant = str_to_var(serialized)
	if parsed is InputEvent:
		return parsed
	return null

func _serialize_touch_control(control: Node) -> Dictionary:
	var size := _viewport_size_for(control)
	if size.x <= 0.0 or size.y <= 0.0:
		return {}

	if control is TouchScreenButton:
		var button := control as TouchScreenButton
		return {
			"kind": "touch_button",
			"position_norm": [button.position.x / size.x, button.position.y / size.y],
			"scale": [button.scale.x, button.scale.y],
		}

	if control is Control:
		var node := control as Control
		return {
			"kind": "control_rect",
			"anchor_left": node.anchor_left,
			"anchor_top": node.anchor_top,
			"anchor_right": node.anchor_right,
			"anchor_bottom": node.anchor_bottom,
			"offset_left_norm": node.offset_left / size.x,
			"offset_top_norm": node.offset_top / size.y,
			"offset_right_norm": node.offset_right / size.x,
			"offset_bottom_norm": node.offset_bottom / size.y,
		}

	return {}

func _apply_touch_layout(control: Node, layout: Dictionary) -> void:
	var kind := String(layout.get("kind", ""))
	var size := _viewport_size_for(control)
	if size.x <= 0.0 or size.y <= 0.0:
		return

	if kind == "touch_button" and control is TouchScreenButton:
		var button := control as TouchScreenButton
		var position_values: Variant = layout.get("position_norm", [])
		if position_values is Array and position_values.size() >= 2:
			button.position = Vector2(float(position_values[0]) * size.x, float(position_values[1]) * size.y)
		var scale_values: Variant = layout.get("scale", [])
		if scale_values is Array and scale_values.size() >= 2:
			button.scale = Vector2(float(scale_values[0]), float(scale_values[1]))
		return

	if kind == "control_rect" and control is Control:
		var node := control as Control
		node.anchor_left = float(layout.get("anchor_left", node.anchor_left))
		node.anchor_top = float(layout.get("anchor_top", node.anchor_top))
		node.anchor_right = float(layout.get("anchor_right", node.anchor_right))
		node.anchor_bottom = float(layout.get("anchor_bottom", node.anchor_bottom))
		node.offset_left = float(layout.get("offset_left_norm", node.offset_left / size.x)) * size.x
		node.offset_top = float(layout.get("offset_top_norm", node.offset_top / size.y)) * size.y
		node.offset_right = float(layout.get("offset_right_norm", node.offset_right / size.x)) * size.x
		node.offset_bottom = float(layout.get("offset_bottom_norm", node.offset_bottom / size.y)) * size.y

func _viewport_size_for(node: Node) -> Vector2:
	if node == null:
		return Vector2.ZERO
	var viewport := node.get_viewport()
	if viewport == null:
		return Vector2.ZERO
	return viewport.get_visible_rect().size

func _sanitize_username(raw_name: String) -> String:
	var cleaned := raw_name.strip_edges()
	if cleaned == "":
		cleaned = _resolve_default_username()
	return cleaned.substr(0, 24)

func _sanitize_profile_username(raw_name: String) -> String:
	return raw_name.strip_edges().substr(0, 24)

func _resolve_default_username() -> String:
	var from_env := OS.get_environment("USER").strip_edges()
	if from_env != "":
		return from_env.substr(0, 24)
	from_env = OS.get_environment("USERNAME").strip_edges()
	if from_env != "":
		return from_env.substr(0, 24)
	return DEFAULT_PLAYER_NAME
