extends Node2D

const DEFAULT_PLAYER_NAME := "Player"
const DEFAULT_AVATAR_PATH := "res://assets/sprites/character/head.png"
const MAP_1_SCENE_PATH := "res://scenes/maps/map_1/map_1.tscn"
const MAP_1_DISPLAY_NAME := "Map 1"
const MAP_1_THUMBNAIL_PATH := "res://scenes/maps/map_1/_assets/map_f.png"

@onready var _player_name_label: Label = get_node_or_null("UI/Control/PlayerCard/Margin/HBox/Name")
@onready var _player_avatar: TextureRect = get_node_or_null("UI/Control/PlayerCard/Margin/HBox/Avatar")
@onready var _settings_panel: Node = get_node_or_null("UI/SettingsPanel")
@onready var _multiplayer_manager: Node = get_node_or_null("MultiplayerManager")
@onready var _map_card_button: Button = get_node_or_null("UI/Control/MapPanel/Margin/VBox/MapCard")
@onready var _map_thumbnail: TextureRect = get_node_or_null("UI/Control/MapPanel/Margin/VBox/MapCard/Margin/VBox/Thumbnail")
@onready var _map_name_label: Label = get_node_or_null("UI/Control/MapPanel/Margin/VBox/MapCard/Margin/VBox/Name")
@onready var _map_status_label: Label = get_node_or_null("UI/Control/MapPanel/Margin/VBox/MapCard/Margin/VBox/Status")

var _selected_map_scene_path := MAP_1_SCENE_PATH

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_refresh_player_card()
	_setup_map_selection()
	if _settings_panel != null and _settings_panel.has_signal("profile_changed"):
		var refresh_call := Callable(self, "_refresh_player_card")
		if not _settings_panel.is_connected("profile_changed", refresh_call):
			_settings_panel.connect("profile_changed", refresh_call)

func _refresh_player_card() -> void:
	var profile := get_node_or_null("/root/PlayerProfile")
	if profile == null:
		return

	var resolved_name := DEFAULT_PLAYER_NAME
	if profile.has_method("get_username"):
		var candidate := String(profile.call("get_username")).strip_edges()
		if candidate != "":
			resolved_name = candidate
	if _player_name_label != null:
		_player_name_label.text = resolved_name

	var avatar_texture: Texture2D = null
	var avatar_path := DEFAULT_AVATAR_PATH
	if profile.has_method("get_avatar_catalog") and profile.has_method("get_avatar_id"):
		var catalog_variant : Dictionary = profile.call("get_avatar_catalog")
		var avatar_id := String(profile.call("get_avatar_id"))
		if catalog_variant is Dictionary:
			var catalog := catalog_variant as Dictionary
			var candidate_path := String(catalog.get(avatar_id, "")).strip_edges()
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

func _on_map_card_pressed() -> void:
	_apply_selected_map(MAP_1_SCENE_PATH)

func _apply_selected_map(scene_path: String) -> void:
	var cleaned_path := scene_path.strip_edges()
	if cleaned_path == "":
		return

	_selected_map_scene_path = cleaned_path
	if _map_status_label != null:
		_map_status_label.text = "Selected"

	if _multiplayer_manager != null:
		if _multiplayer_manager.has_method("set_selected_map_scene_path"):
			_multiplayer_manager.call("set_selected_map_scene_path", cleaned_path)
		else:
			_multiplayer_manager.set("map_scene_path", cleaned_path)
