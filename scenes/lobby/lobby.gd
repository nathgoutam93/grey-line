extends Node2D

const DEFAULT_AVATAR_ID := "avatar_01"
const DEFAULT_AVATAR_PATH := "res://assets/sprites/character/head.png"

@onready var _ui_layer: CanvasLayer = get_node_or_null("UI")
@onready var _level: Node2D = get_node_or_null("Level")
@onready var _start_match_button: BaseButton = _find_button(["UI/Control/start_match", "UI/Control/LobbyFrame/VBoxContainer/HBoxContainer2/start_match"])
@onready var _lobby_status_label: Label = _find_label(["UI/Control/lobby_status", "UI/Control/LobbyFrame/VBoxContainer/lobby_status"])
@onready var _lobby_players_label: Label = _find_label(["UI/Control/lobby_players", "UI/Control/LobbyFrame/VBoxContainer/lobby_players"])
@onready var _map_name_label: Label = _find_label(["UI/Control/LobbyFrame/Content/MapThumbnailPanel/MapOverlay", "UI/Control/LobbyFrame/VBoxContainer/HBoxContainer/MapThumbnailPanel/MapOverlay"], "MapOverlay")

@onready var _slot_1_name: Label = _find_label([], "player_slot_1")
@onready var _slot_2_name: Label = _find_label([], "player_slot_2")
@onready var _slot_3_name: Label = _find_label([], "player_slot_3")
@onready var _slot_4_name: Label = _find_label([], "player_slot_4")
@onready var _slot_5_name: Label = _find_label([], "player_slot_5")

@onready var _slot_1_avatar: TextureRect = _find_texture_rect([], "avatar_slot_1")
@onready var _slot_2_avatar: TextureRect = _find_texture_rect([], "avatar_slot_2")
@onready var _slot_3_avatar: TextureRect = _find_texture_rect([], "avatar_slot_3")
@onready var _slot_4_avatar: TextureRect = _find_texture_rect([], "avatar_slot_4")
@onready var _slot_5_avatar: TextureRect = _find_texture_rect([], "avatar_slot_5")

var _avatar_catalog: Dictionary = {}
var _avatar_texture_cache: Dictionary = {}

func _ready() -> void:
	_load_avatar_catalog()
	if not MultiplayerSession.lobby_sync_updated.is_connected(_on_lobby_sync_updated):
		MultiplayerSession.lobby_sync_updated.connect(_on_lobby_sync_updated)
	if not MultiplayerSession.lobby_ui_visibility_requested.is_connected(_on_lobby_ui_visibility_requested):
		MultiplayerSession.lobby_ui_visibility_requested.connect(_on_lobby_ui_visibility_requested)
	if not MultiplayerSession.server_map_load_requested.is_connected(_on_server_map_load_requested):
		MultiplayerSession.server_map_load_requested.connect(_on_server_map_load_requested)
	_connect_start_button()
	MultiplayerSession.enter_lobby()
	sync_lobby(MultiplayerSession.get_lobby_sync_payload())

func _exit_tree() -> void:
	if MultiplayerSession.lobby_sync_updated.is_connected(_on_lobby_sync_updated):
		MultiplayerSession.lobby_sync_updated.disconnect(_on_lobby_sync_updated)
	if MultiplayerSession.lobby_ui_visibility_requested.is_connected(_on_lobby_ui_visibility_requested):
		MultiplayerSession.lobby_ui_visibility_requested.disconnect(_on_lobby_ui_visibility_requested)
	if MultiplayerSession.server_map_load_requested.is_connected(_on_server_map_load_requested):
		MultiplayerSession.server_map_load_requested.disconnect(_on_server_map_load_requested)

func _on_lobby_sync_updated(payload: Dictionary) -> void:
	sync_lobby(payload)

func _on_lobby_ui_visibility_requested(visible: bool) -> void:
	if _ui_layer != null:
		_ui_layer.visible = visible

func _on_server_map_load_requested(map_path: String) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	if _level == null:
		return
	var packed := load(map_path)
	if not (packed is PackedScene):
		push_error("Failed to load map scene at path: %s" % map_path)
		return
	_clear_level_children()
	_level.add_child((packed as PackedScene).instantiate())

func _clear_level_children() -> void:
	if _level == null:
		return
	for child in _level.get_children():
		_level.remove_child(child)
		child.queue_free()

func sync_lobby(payload: Dictionary) -> void:
	var names_variant: Variant = payload.get("player_names", {})
	var avatars_variant: Variant = payload.get("player_avatar_ids", {})
	var map_scene_path := String(payload.get("map_scene_path", ""))
	var is_connected := bool(payload.get("is_connected", false))
	var is_server := bool(payload.get("is_server", false))
	var has_started := bool(payload.get("match_started", false))
	var local_peer_id := int(payload.get("local_peer_id", -1))

	var names: Dictionary = names_variant if names_variant is Dictionary else {}
	var avatars: Dictionary = avatars_variant if avatars_variant is Dictionary else {}

	_render_status(is_connected, is_server, has_started)
	_render_map_name(map_scene_path)
	_render_slots(names, avatars, local_peer_id)
	_render_start_button(is_connected, is_server, has_started)
	_render_debug_player_list(names)

func _render_start_button(is_connected: bool, is_server: bool, has_started: bool) -> void:
	if _start_match_button != null:
		_start_match_button.visible = is_connected and is_server and not has_started

func _render_status(is_connected: bool, is_server: bool, has_started: bool) -> void:
	if _lobby_status_label == null:
		return
	if not is_connected:
		_lobby_status_label.text = "Not connected"
	elif has_started:
		_lobby_status_label.text = "Match started"
	elif is_server:
		_lobby_status_label.text = "Lobby ready - host can start"
	else:
		_lobby_status_label.text = "Waiting for host to start"

func _render_map_name(map_scene_path: String) -> void:
	if _map_name_label == null:
		return
	var scene_file := map_scene_path.strip_edges().get_file().trim_suffix(".tscn")
	if scene_file == "":
		_map_name_label.text = "MAP NAME"
		return
	_map_name_label.text = scene_file.replace("_", " ").capitalize()

func _render_slots(player_names: Dictionary, player_avatars: Dictionary, local_peer_id: int) -> void:
	var slot_names: Array = [_slot_1_name, _slot_2_name, _slot_3_name, _slot_4_name, _slot_5_name]
	var slot_avatars: Array = [_slot_1_avatar, _slot_2_avatar, _slot_3_avatar, _slot_4_avatar, _slot_5_avatar]

	var slot_entries: Array = [null, null, null, null, null]
	var remote_entries: Array = []
	var local_entry: Dictionary = {}

	var ids := player_names.keys()
	ids.sort()
	for id_variant in ids:
		var peer_id := int(id_variant)
		var entry := {
			"peer_id": peer_id,
			"name": String(player_names.get(peer_id, "Player %d" % peer_id)),
			"avatar_id": String(player_avatars.get(peer_id, DEFAULT_AVATAR_ID)),
		}
		if peer_id == local_peer_id:
			local_entry = entry
		else:
			remote_entries.append(entry)

	if not local_entry.is_empty():
		slot_entries[2] = local_entry

	var fill_order := [1, 3, 0, 4]
	for slot_index in fill_order:
		if remote_entries.is_empty():
			break
		slot_entries[slot_index] = remote_entries.pop_front()

	for idx in range(slot_names.size()):
		var name_label : Label = slot_names[idx]
		var avatar_rect : TextureRect = slot_avatars[idx]
		var entry_variant: Variant = slot_entries[idx]
		if entry_variant is Dictionary:
			var entry := entry_variant as Dictionary
			if name_label != null:
				name_label.text = String(entry.get("name", "+"))
			if avatar_rect != null:
				avatar_rect.texture = _resolve_avatar_texture(String(entry.get("avatar_id", DEFAULT_AVATAR_ID)))
		else:
			if name_label != null:
				name_label.text = "+"
			if avatar_rect != null:
				avatar_rect.texture = null

func _render_debug_player_list(player_names: Dictionary) -> void:
	if _lobby_players_label == null:
		return
	var ids := player_names.keys()
	ids.sort()
	var lines: Array[String] = []
	for id_variant in ids:
		var peer_id := int(id_variant)
		lines.append("%d - %s" % [peer_id, String(player_names.get(peer_id, "Player %d" % peer_id))])
	_lobby_players_label.text = "\n".join(lines)

func _resolve_avatar_texture(avatar_id: String) -> Texture2D:
	if _avatar_texture_cache.has(avatar_id):
		return _avatar_texture_cache[avatar_id] as Texture2D

	var texture_path := String(_avatar_catalog.get(avatar_id, DEFAULT_AVATAR_PATH)).strip_edges()
	if texture_path == "":
		texture_path = DEFAULT_AVATAR_PATH
	var loaded := load(texture_path) as Texture2D
	if loaded == null and texture_path != DEFAULT_AVATAR_PATH:
		loaded = load(DEFAULT_AVATAR_PATH) as Texture2D
	_avatar_texture_cache[avatar_id] = loaded
	return loaded

func _load_avatar_catalog() -> void:
	_avatar_catalog.clear()
	_avatar_texture_cache.clear()
	var profile := get_node_or_null("/root/PlayerProfile")
	if profile != null and profile.has_method("get_avatar_catalog"):
		var catalog_variant: Variant = profile.call("get_avatar_catalog")
		if catalog_variant is Dictionary:
			_avatar_catalog = (catalog_variant as Dictionary).duplicate(true)

func _connect_start_button() -> void:
	if _start_match_button == null:
		return
	var call := Callable(MultiplayerSession, "start_match")
	if not _start_match_button.is_connected("pressed", call):
		_start_match_button.connect("pressed", call)

func _find_label(paths: Array, fallback_name: String = "") -> Label:
	for node_path in paths:
		var found := get_node_or_null(String(node_path)) as Label
		if found != null:
			return found
	if fallback_name != "":
		var root := get_node_or_null("UI/Control")
		if root != null:
			return root.find_child(fallback_name, true, false) as Label
	return null

func _find_button(paths: Array, fallback_name: String = "") -> BaseButton:
	for node_path in paths:
		var found := get_node_or_null(String(node_path)) as BaseButton
		if found != null:
			return found
	if fallback_name != "":
		var root := get_node_or_null("UI/Control")
		if root != null:
			return root.find_child(fallback_name, true, false) as BaseButton
	return null

func _find_texture_rect(paths: Array, fallback_name: String = "") -> TextureRect:
	for node_path in paths:
		var found := get_node_or_null(String(node_path)) as TextureRect
		if found != null:
			return found
	if fallback_name != "":
		var root := get_node_or_null("UI/Control")
		if root != null:
			return root.find_child(fallback_name, true, false) as TextureRect
	return null
