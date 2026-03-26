extends Node2D

const DEFAULT_PLAYER_NAME := "Player"
const DEFAULT_AVATAR_PATH := "res://assets/sprites/character/head.png"

@onready var _player_name_label: Label = get_node_or_null("UI/Control/PlayerCard/Margin/HBox/Name")
@onready var _player_avatar: TextureRect = get_node_or_null("UI/Control/PlayerCard/Margin/HBox/Avatar")
@onready var _settings_panel: Node = get_node_or_null("UI/SettingsPanel")

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_refresh_player_card()
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
