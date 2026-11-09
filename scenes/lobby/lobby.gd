extends Node2D

@onready var _ui_layer: CanvasLayer = $UI
@onready var _level: Node2D = $Level
@onready var _view: LobbyView = $UI/Control

func _ready() -> void:
	MultiplayerSession.lobby_sync_updated.connect(_on_lobby_sync_updated)
	MultiplayerSession.lobby_ui_visibility_requested.connect(_on_lobby_ui_visibility_requested)
	MultiplayerSession.server_map_load_requested.connect(_on_server_map_load_requested)
	_view.start_requested.connect(MultiplayerSession.start_match)
	_view.switch_team_requested.connect(_on_switch_team_pressed)
	_view.add_bot_requested.connect(func(): MultiplayerSession.add_bot())
	_view.remove_bot_requested.connect(_on_remove_bot_pressed)
	_view.map_cycle_requested.connect(MultiplayerSession.cycle_selected_map)
	MultiplayerSession.enter_lobby()
	_view.render(MultiplayerSession.get_lobby_sync_payload())

func _exit_tree() -> void:
	if MultiplayerSession.lobby_sync_updated.is_connected(_on_lobby_sync_updated):
		MultiplayerSession.lobby_sync_updated.disconnect(_on_lobby_sync_updated)
	if MultiplayerSession.lobby_ui_visibility_requested.is_connected(_on_lobby_ui_visibility_requested):
		MultiplayerSession.lobby_ui_visibility_requested.disconnect(_on_lobby_ui_visibility_requested)
	if MultiplayerSession.server_map_load_requested.is_connected(_on_server_map_load_requested):
		MultiplayerSession.server_map_load_requested.disconnect(_on_server_map_load_requested)

func _on_lobby_sync_updated(payload: Dictionary) -> void:
	_view.render(payload)

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

func _on_switch_team_pressed() -> void:
	if not NetUtil.has_active_peer(multiplayer) or MultiplayerSession.match_started:
		return
	var peer_id := multiplayer.get_unique_id()
	var wanted := Teams.other(MultiplayerSession.get_team(peer_id))
	if multiplayer.is_server():
		if Teams.can_switch(MultiplayerSession.player_teams, peer_id, wanted, ceili(MultiplayerSession.max_players / 2.0)):
			MultiplayerSession.set_team(peer_id, wanted)
	else:
		MultiplayerSession.request_team.rpc_id(1, wanted)

func _on_remove_bot_pressed() -> void:
	if not MultiplayerSession.bot_ids.is_empty():
		MultiplayerSession.remove_bot(MultiplayerSession.bot_ids.back())
