extends Node2D

const DEFAULT_PLAYER_NAME := "Player"
const DEFAULT_AVATAR_PATH := "res://assets/sprites/character/head.png"
const MAP_1_SCENE_PATH := "res://scenes/maps/map_1/map_1.tscn"
const MAP_1_DISPLAY_NAME := "Map 1"
const MAP_1_THUMBNAIL_PATH := "res://scenes/maps/map_1/_assets/map_f.png"

@onready var _player_name_label: Label = get_node_or_null("UI/Control/PlayerCard/Margin/HBox/Name")
@onready var _player_avatar: TextureRect = get_node_or_null("UI/Control/PlayerCard/Margin/HBox/Avatar")
@onready var _settings_panel: Node = get_node_or_null("UI/SettingsPanel")
@onready var _map_card_button: Button = get_node_or_null("UI/Control/MapPanel/Margin/VBox/MapCard")
@onready var _map_thumbnail: TextureRect = get_node_or_null("UI/Control/MapPanel/Margin/VBox/MapCard/Margin/VBox/Thumbnail")
@onready var _map_name_label: Label = get_node_or_null("UI/Control/MapPanel/Margin/VBox/MapCard/Margin/VBox/Name")
@onready var _map_status_label: Label = get_node_or_null("UI/Control/MapPanel/Margin/VBox/MapCard/Margin/VBox/Status")
@onready var _hostname_input: LineEdit = get_node_or_null("UI/Control/hostname")
@onready var _discovery_status_label: Label = get_node_or_null("UI/Control/discovery_status")
@onready var _join_button: Button = get_node_or_null("UI/Control/HBoxContainer/join")
@onready var _host_button: Button = get_node_or_null("UI/Control/HBoxContainer/host")

var _selected_map_scene_path := MAP_1_SCENE_PATH

func _ready() -> void:
	Input.emulate_mouse_from_touch = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	MultiplayerSession.enter_main_menu()
	if not MultiplayerSession.main_menu_state_changed.is_connected(_on_main_menu_state_changed):
		MultiplayerSession.main_menu_state_changed.connect(_on_main_menu_state_changed)
	_refresh_player_card()
	_setup_map_selection()
	_connect_action_buttons()
	_on_main_menu_state_changed(MultiplayerSession.get_discovery_status_text(), MultiplayerSession.is_manual_join_visible())
	if _settings_panel != null and _settings_panel.has_signal("profile_changed"):
		var refresh_call := Callable(self, "_refresh_player_card")
		if not _settings_panel.is_connected("profile_changed", refresh_call):
			_settings_panel.connect("profile_changed", refresh_call)

func _exit_tree() -> void:
	if MultiplayerSession.main_menu_state_changed.is_connected(_on_main_menu_state_changed):
		MultiplayerSession.main_menu_state_changed.disconnect(_on_main_menu_state_changed)

func _refresh_player_card() -> void:
	var resolved_name := DEFAULT_PLAYER_NAME
	var candidate := PlayerProfile.get_username().strip_edges()
	if candidate != "":
		resolved_name = candidate
	if _player_name_label != null:
		_player_name_label.text = resolved_name

	var avatar_texture: Texture2D = null
	var avatar_path := DEFAULT_AVATAR_PATH
	var candidate_path := String(PlayerProfile.get_avatar_catalog().get(PlayerProfile.get_avatar_id(), "")).strip_edges()
	if candidate_path != "":
		avatar_path = candidate_path
	avatar_texture = load(avatar_path) as Texture2D
	if _player_avatar != null:
		_player_avatar.texture = avatar_texture

func _setup_map_selection() -> void:
	if _map_name_label != null:
		_map_name_label.text = MAP_1_DISPLAY_NAME

	if _map_thumbnail != null:
		_map_thumbnail.texture = load(MAP_1_THUMBNAIL_PATH) as Texture2D

	if _map_card_button != null and not _map_card_button.pressed.is_connected(_on_map_card_pressed):
		_map_card_button.pressed.connect(_on_map_card_pressed)

	_apply_selected_map(MAP_1_SCENE_PATH)

func _connect_action_buttons() -> void:
	if _join_button != null and not _join_button.pressed.is_connected(_on_join_pressed):
		_join_button.pressed.connect(_on_join_pressed)
	if _host_button != null and not _host_button.pressed.is_connected(_on_host_pressed):
		_host_button.pressed.connect(_on_host_pressed)

func _on_join_pressed() -> void:
	var manual_host := ""
	var manual_mode := false
	if _hostname_input != null and _hostname_input.visible:
		manual_mode = true
		manual_host = _hostname_input.text
	await MultiplayerSession.join_game(manual_host, manual_mode)

func _on_host_pressed() -> void:
	MultiplayerSession.host_game()

func _on_main_menu_state_changed(status_text: String, manual_visible: bool) -> void:
	if _discovery_status_label != null:
		_discovery_status_label.text = status_text
	if _hostname_input != null:
		_hostname_input.visible = manual_visible

func _on_map_card_pressed() -> void:
	_apply_selected_map(MAP_1_SCENE_PATH)

func _apply_selected_map(scene_path: String) -> void:
	var cleaned_path := scene_path.strip_edges()
	if cleaned_path == "":
		return

	_selected_map_scene_path = cleaned_path
	if _map_status_label != null:
		_map_status_label.text = "Selected"

	MultiplayerSession.set_selected_map_scene_path(cleaned_path)
