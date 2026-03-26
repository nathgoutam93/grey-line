extends Control
class_name MainMenuSettingsPanel

const ACTIONS: Array[String] = [
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
const TOUCH_CONTROL_IDS: Array[String] = [
	"MovementJoystick",
	"Shoot",
	"Headshot",
	"Reload",
	"TouchAimZone",
]

@onready var _menu_player_name_input: LineEdit = get_node_or_null("../UI/Control/player_name")
@onready var _settings_button: Button = get_node_or_null("SettingsButton")
@onready var _settings_popup: PanelContainer = get_node_or_null("SettingsPopup")
@onready var _tabs: TabContainer = get_node_or_null("SettingsPopup/Margin/VBox/Tabs")
@onready var _username_input: LineEdit = get_node_or_null("SettingsPopup/Margin/VBox/Tabs/Profile/UsernameInput")
@onready var _avatar_option: OptionButton = get_node_or_null("SettingsPopup/Margin/VBox/Tabs/Profile/AvatarOption")
@onready var _avatar_preview: TextureRect = get_node_or_null("SettingsPopup/Margin/VBox/Tabs/Profile/AvatarPreview")
@onready var _onboarding_hint: Label = get_node_or_null("SettingsPopup/Margin/VBox/Tabs/Profile/OnboardingHint")
@onready var _complete_profile_button: Button = get_node_or_null("SettingsPopup/Margin/VBox/Tabs/Profile/CompleteProfileButton")
@onready var _status_label: Label = get_node_or_null("SettingsPopup/Margin/VBox/StatusLabel")
@onready var _close_button: Button = get_node_or_null("SettingsPopup/Margin/VBox/CloseButton")
@onready var _reset_keybinds_button: Button = get_node_or_null("SettingsPopup/Margin/VBox/Tabs/Keybinds/ResetKeybindsButton")
@onready var _reset_touch_button: Button = get_node_or_null("SettingsPopup/Margin/VBox/Tabs/TouchControls/ResetTouchButton")
@onready var _join_button: TouchScreenButton = get_node_or_null("../UI/Control/HBoxContainer/join")
@onready var _host_button: TouchScreenButton = get_node_or_null("../UI/Control/HBoxContainer/host")

var _profile: Node = null
var _waiting_rebind_action := ""
var _keybind_buttons: Dictionary = {}
var _touch_x_sliders: Dictionary = {}
var _touch_y_sliders: Dictionary = {}
var _touch_value_labels: Dictionary = {}
var _updating_touch_ui := false
var _onboarding_required := false

func _ready() -> void:
	_profile = get_node_or_null("/root/PlayerProfile")
	if _profile == null:
		return

	_resolve_control_maps()
	_connect_signals()
	_load_profile_into_ui()
	_refresh_onboarding_gate(true)
	set_process_unhandled_input(true)

func _resolve_control_maps() -> void:
	for action in ACTIONS:
		var button := get_node_or_null("SettingsPopup/Margin/VBox/Tabs/Keybinds/ActionsScroll/ActionsList/%s/RebindButton" % action) as Button
		if button != null:
			_keybind_buttons[action] = button

	for control_id in TOUCH_CONTROL_IDS:
		var x_slider := get_node_or_null("SettingsPopup/Margin/VBox/Tabs/TouchControls/%s/X" % control_id) as HSlider
		var y_slider := get_node_or_null("SettingsPopup/Margin/VBox/Tabs/TouchControls/%s/Y" % control_id) as HSlider
		var value_label := get_node_or_null("SettingsPopup/Margin/VBox/Tabs/TouchControls/%s/Value" % control_id) as Label
		if x_slider != null and y_slider != null and value_label != null:
			_touch_x_sliders[control_id] = x_slider
			_touch_y_sliders[control_id] = y_slider
			_touch_value_labels[control_id] = value_label

func _connect_signals() -> void:
	if _settings_button != null and not _settings_button.pressed.is_connected(_on_toggle_settings_pressed):
		_settings_button.pressed.connect(_on_toggle_settings_pressed)
	if _close_button != null and not _close_button.pressed.is_connected(_on_toggle_settings_pressed):
		_close_button.pressed.connect(_on_toggle_settings_pressed)

	if _username_input != null:
		if not _username_input.text_changed.is_connected(_on_username_changed):
			_username_input.text_changed.connect(_on_username_changed)
		if not _username_input.text_submitted.is_connected(_on_username_submitted):
			_username_input.text_submitted.connect(_on_username_submitted)

	if _avatar_option != null and not _avatar_option.item_selected.is_connected(_on_avatar_selected):
		_avatar_option.item_selected.connect(_on_avatar_selected)

	for action in _keybind_buttons.keys():
		var button := _keybind_buttons[action] as Button
		if button != null and not button.pressed.is_connected(_on_rebind_button_pressed.bind(action)):
			button.pressed.connect(_on_rebind_button_pressed.bind(action))

	for control_id in _touch_x_sliders.keys():
		var x_slider := _touch_x_sliders[control_id] as HSlider
		var y_slider := _touch_y_sliders[control_id] as HSlider
		if x_slider != null and not x_slider.value_changed.is_connected(_on_touch_x_changed.bind(control_id)):
			x_slider.value_changed.connect(_on_touch_x_changed.bind(control_id))
		if y_slider != null and not y_slider.value_changed.is_connected(_on_touch_y_changed.bind(control_id)):
			y_slider.value_changed.connect(_on_touch_y_changed.bind(control_id))

	if _reset_keybinds_button != null and not _reset_keybinds_button.pressed.is_connected(_on_reset_keybinds_pressed):
		_reset_keybinds_button.pressed.connect(_on_reset_keybinds_pressed)
	if _reset_touch_button != null and not _reset_touch_button.pressed.is_connected(_on_reset_touch_pressed):
		_reset_touch_button.pressed.connect(_on_reset_touch_pressed)
	if _complete_profile_button != null and not _complete_profile_button.pressed.is_connected(_on_complete_profile_pressed):
		_complete_profile_button.pressed.connect(_on_complete_profile_pressed)

	if _menu_player_name_input != null and not _menu_player_name_input.text_changed.is_connected(_on_menu_name_changed):
		_menu_player_name_input.text_changed.connect(_on_menu_name_changed)

func _load_profile_into_ui() -> void:
	if _profile == null:
		return

	var username_variant: Variant = _profile.call("get_username")
	if username_variant is String and _username_input != null:
		_username_input.text = username_variant as String
		if _menu_player_name_input != null and _menu_player_name_input.text != _username_input.text:
			_menu_player_name_input.text = _username_input.text

	if _avatar_option != null:
		var catalog_variant: Variant = _profile.call("get_avatar_catalog")
		_avatar_option.clear()
		if catalog_variant is Dictionary:
			var catalog := catalog_variant as Dictionary
			var ids: Array[String] = []
			for id_variant in catalog.keys():
				ids.append(String(id_variant))
			ids.sort()
			for avatar_id in ids:
				_avatar_option.add_item(avatar_id)
				_avatar_option.set_item_metadata(_avatar_option.item_count - 1, avatar_id)

			var selected_avatar_variant: Variant = _profile.call("get_avatar_id")
			if selected_avatar_variant is String:
				var selected_avatar_id := selected_avatar_variant as String
				for idx in range(_avatar_option.item_count):
					var metadata: Variant = _avatar_option.get_item_metadata(idx)
					if String(metadata) == selected_avatar_id:
						_avatar_option.select(idx)
						break

	_refresh_avatar_preview()
	_refresh_keybind_buttons()
	_refresh_touch_controls()

func _refresh_avatar_preview() -> void:
	if _profile == null or _avatar_option == null or _avatar_preview == null or _avatar_option.item_count == 0:
		return
	var selected_index := maxi(_avatar_option.selected, 0)
	var avatar_id := String(_avatar_option.get_item_metadata(selected_index))
	var catalog_variant: Variant = _profile.call("get_avatar_catalog")
	if not (catalog_variant is Dictionary):
		return
	var catalog := catalog_variant as Dictionary
	var path := String(catalog.get(avatar_id, ""))
	_avatar_preview.texture = load(path) as Texture2D if path.strip_edges() != "" else null

func _refresh_keybind_buttons() -> void:
	for action in _keybind_buttons.keys():
		if not InputMap.has_action(action):
			continue
		var button := _keybind_buttons[action] as Button
		if button != null:
			button.text = "Rebind: %s" % _action_event_text(String(action))

func _refresh_touch_controls() -> void:
	if _profile == null:
		return
	_updating_touch_ui = true
	for control_id in _touch_x_sliders.keys():
		var x_slider := _touch_x_sliders[control_id] as HSlider
		var y_slider := _touch_y_sliders[control_id] as HSlider
		var value_label := _touch_value_labels[control_id] as Label
		if x_slider == null or y_slider == null or value_label == null:
			continue
		var pos_variant: Variant = _profile.call("get_touch_control_position_norm", control_id)
		if pos_variant is Vector2:
			var pos := pos_variant as Vector2
			x_slider.value = pos.x
			y_slider.value = pos.y
			value_label.text = "(%.3f, %.3f)" % [pos.x, pos.y]
	_updating_touch_ui = false

func _action_event_text(action: String) -> String:
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "Unbound"
	var first_event_variant: Variant = events[0]
	if first_event_variant is InputEvent:
		return _event_to_text(first_event_variant as InputEvent)
	return "Unbound"

func _event_to_text(event: InputEvent) -> String:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		return OS.get_keycode_string(key_event.physical_keycode)
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		return "Mouse %d" % mouse_event.button_index
	return event.as_text()

func _normalized_binding_event(event: InputEvent) -> InputEvent:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		var normalized_key := InputEventKey.new()
		normalized_key.physical_keycode = key_event.physical_keycode
		normalized_key.keycode = key_event.keycode
		normalized_key.shift_pressed = key_event.shift_pressed
		normalized_key.alt_pressed = key_event.alt_pressed
		normalized_key.ctrl_pressed = key_event.ctrl_pressed
		normalized_key.meta_pressed = key_event.meta_pressed
		normalized_key.echo = false
		return normalized_key
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		var normalized_mouse := InputEventMouseButton.new()
		normalized_mouse.button_index = mouse_event.button_index
		return normalized_mouse
	return event

func _on_toggle_settings_pressed() -> void:
	if _settings_popup == null:
		return
	if _onboarding_required and _settings_popup.visible:
		return
	_settings_popup.visible = not _settings_popup.visible
	if _settings_popup.visible:
		_load_profile_into_ui()
		_refresh_onboarding_gate(false)
		_set_status("Settings loaded.")
	else:
		_waiting_rebind_action = ""
		_set_status("")

func _on_username_changed(new_text: String) -> void:
	if _profile == null:
		return
	_profile.call("set_username", new_text)
	if _menu_player_name_input != null and _menu_player_name_input.text != new_text:
		_menu_player_name_input.text = new_text
	_refresh_onboarding_gate(false)
	_set_status("Username saved.")

func _on_username_submitted(new_text: String) -> void:
	_on_username_changed(new_text)

func _on_menu_name_changed(new_text: String) -> void:
	if _username_input != null and _username_input.text != new_text:
		_username_input.text = new_text

func _on_avatar_selected(index: int) -> void:
	if _profile == null or _avatar_option == null:
		return
	var avatar_id := String(_avatar_option.get_item_metadata(index))
	_profile.call("set_avatar_id", avatar_id)
	_refresh_avatar_preview()
	_refresh_onboarding_gate(false)
	_set_status("Avatar saved.")

func _on_rebind_button_pressed(action: String) -> void:
	_waiting_rebind_action = action
	_set_status("Press a key or mouse button for %s (Esc to cancel)." % String(action).replace("_", " ").capitalize())

func _unhandled_input(event: InputEvent) -> void:
	if _waiting_rebind_action == "" or _settings_popup == null or not _settings_popup.visible:
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if key_event.keycode == KEY_ESCAPE:
			_waiting_rebind_action = ""
			_set_status("Rebind canceled.")
			get_viewport().set_input_as_handled()
			return
		_apply_rebind_event(_normalized_binding_event(key_event))
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if not mouse_event.pressed:
			return
		_apply_rebind_event(_normalized_binding_event(mouse_event))
		get_viewport().set_input_as_handled()

func _apply_rebind_event(event: InputEvent) -> void:
	if _waiting_rebind_action == "" or _profile == null:
		return
	var action := _waiting_rebind_action
	_waiting_rebind_action = ""
	if not InputMap.has_action(action):
		return
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, event)
	_profile.call("set_action_binding", action, [event])
	_refresh_keybind_buttons()
	_set_status("%s bound to %s." % [String(action), _event_to_text(event)])

func _on_reset_keybinds_pressed() -> void:
	if _profile == null:
		return
	_profile.call("reset_keybinds_to_default")
	_refresh_keybind_buttons()
	_set_status("Keybinds reset to default.")

func _on_touch_x_changed(value: float, control_id: String) -> void:
	if _updating_touch_ui or _profile == null:
		return
	_apply_touch_position_change(control_id, value, true)

func _on_touch_y_changed(value: float, control_id: String) -> void:
	if _updating_touch_ui or _profile == null:
		return
	_apply_touch_position_change(control_id, value, false)

func _apply_touch_position_change(control_id: String, value: float, is_x: bool) -> void:
	var x_slider := _touch_x_sliders.get(control_id) as HSlider
	var y_slider := _touch_y_sliders.get(control_id) as HSlider
	var value_label := _touch_value_labels.get(control_id) as Label
	if x_slider == null or y_slider == null or value_label == null:
		return
	var position := Vector2(x_slider.value, y_slider.value)
	if is_x:
		position.x = value
	else:
		position.y = value
	_profile.call("set_touch_control_position_norm", control_id, position)
	value_label.text = "(%.3f, %.3f)" % [position.x, position.y]
	_set_status("%s position saved." % control_id)

func _on_reset_touch_pressed() -> void:
	if _profile == null:
		return
	_profile.call("reset_touch_layout_to_default")
	_refresh_touch_controls()
	_set_status("Touch layout reset to default.")

func _on_complete_profile_pressed() -> void:
	if _profile == null or _username_input == null:
		return
	var username := _username_input.text.strip_edges()
	if username == "":
		_set_status("Username is required.")
		return
	if _avatar_option == null or _avatar_option.item_count == 0:
		_set_status("Avatar selection is required.")
		return
	var avatar_id := String(_avatar_option.get_item_metadata(maxi(_avatar_option.selected, 0)))
	_profile.call("set_username", username)
	_profile.call("set_avatar_id", avatar_id)
	_profile.call("complete_profile_setup")
	_load_profile_into_ui()
	_refresh_onboarding_gate(false)
	if _settings_popup != null:
		_settings_popup.visible = false
	_set_status("Profile setup complete.")

func _refresh_onboarding_gate(force_open: bool) -> void:
	_onboarding_required = _is_profile_completed() == false
	if _onboarding_hint != null:
		_onboarding_hint.visible = _onboarding_required
	if _complete_profile_button != null:
		_complete_profile_button.visible = _onboarding_required
	if _close_button != null:
		_close_button.visible = not _onboarding_required
	if _settings_button != null:
		_settings_button.visible = not _onboarding_required
	if _join_button != null:
		_join_button.visible = not _onboarding_required
	if _host_button != null:
		_host_button.visible = not _onboarding_required
	if _tabs != null and _onboarding_required:
		_tabs.current_tab = 0
	if _settings_popup != null and _onboarding_required and force_open:
		_settings_popup.visible = true
		_set_status("First launch setup: configure username and avatar.")

func _is_profile_completed() -> bool:
	if _profile == null:
		return true
	if _profile.has_method("is_profile_completed"):
		return bool(_profile.call("is_profile_completed"))
	return true

func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
