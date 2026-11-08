extends Node

signal main_menu_state_changed(status_text: String, manual_join_visible: bool)
signal lobby_sync_updated(payload: Dictionary)
signal lobby_ui_visibility_requested(visible: bool)
signal server_map_load_requested(map_scene_path: String)

@export var port: int = 3000
@export var max_players: int = 8
@export var address: String = "127.0.0.1"
@export var map_scene_path: String = "res://scenes/maps/map_1/map_1.tscn"
@export var enable_lan_discovery: bool = true
@export var discovery_port: int = 3001
@export var discovery_timeout_seconds: float = 0.4
@export var discovery_attempts: int = 3
@export var discovery_token: String = "GREYLINE_DISCOVERY_V1"

var local_player_name := ""
var player_names := {}
var player_avatar_ids := {}
var match_started := false

var discovery_listener: PacketPeerUDP
var discovery_listener_active := false
var manual_join_visible := false
var discovery_status_text := "Auto-discover LAN host"

const DEFAULT_PLAYER_NAME := "Player"
const DEFAULT_AVATAR_ID := "avatar_01"
const MAIN_MENU_SCENE_PATH := "res://scenes/main_menu/main_menu.tscn"
const LOBBY_SCENE_PATH := "res://scenes/lobby/lobby.tscn"
const RPC_CHANNEL_UI := 2

static var persisted_player_names := {}
static var persisted_player_avatar_ids := {}
static var persisted_match_started := false
static var persisted_map_scene_path := ""

func _ready() -> void:
	_apply_persisted_map_scene_path()
	_apply_default_player_name()
	_connect_multiplayer_signals()
	_release_mouse_capture()

	if OS.has_feature("dedicated_server"):
		local_player_name = "DedicatedServer"
		host_game()
		return

func _process(_delta: float) -> void:
	if not discovery_listener_active or discovery_listener == null:
		return

	while discovery_listener.get_available_packet_count() > 0:
		var packet := discovery_listener.get_packet().get_string_from_utf8()
		var sender_ip := discovery_listener.get_packet_ip()
		var sender_port := discovery_listener.get_packet_port()
		if packet != "%s:DISCOVER" % discovery_token:
			continue
		discovery_listener.set_dest_address(sender_ip, sender_port)
		var payload := "%s:HOST:%d" % [discovery_token, port]
		discovery_listener.put_packet(payload.to_utf8_buffer())

func _exit_tree() -> void:
	_stop_lan_discovery_listener()
	_release_mouse_capture()

func enter_main_menu() -> void:
	_release_mouse_capture()
	_reset_network_session()
	_stop_lan_discovery_listener()
	player_names.clear()
	player_avatar_ids.clear()
	match_started = false
	persisted_player_names.clear()
	persisted_player_avatar_ids.clear()
	persisted_match_started = false
	manual_join_visible = false
	discovery_status_text = "Auto-discover LAN host"
	_emit_main_menu_state()

func enter_lobby() -> void:
	_release_mouse_capture()
	_apply_default_player_name()

	if multiplayer.multiplayer_peer != null:
		player_names = persisted_player_names.duplicate(true)
		player_avatar_ids = persisted_player_avatar_ids.duplicate(true)
		match_started = persisted_match_started

	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		_start_lan_discovery_listener()

	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		call_deferred("request_lobby_sync_from_server")

	_emit_lobby_sync()

func host_game() -> Dictionary:
	if not _is_profile_ready():
		_set_discovery_status("Complete profile in Settings.")
		return {"ok": false, "message": "Profile incomplete."}

	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(port, max_players)
	if error != OK:
		push_error("Failed to start server: %s (%s)" % [error, error_string(error)])
		return {"ok": false, "message": "Failed to start server."}

	multiplayer.multiplayer_peer = peer
	local_player_name = _resolve_local_player_name()
	_set_profile_username(local_player_name)
	_set_player_name_for_peer(multiplayer.get_unique_id(), local_player_name)
	_set_player_avatar_for_peer(multiplayer.get_unique_id(), _resolve_local_avatar_id())
	match_started = false
	_start_lan_discovery_listener()
	_persist_runtime_state()
	_open_lobby_scene()
	return {"ok": true}

func join_game(manual_host: String = "", manual_mode: bool = false) -> Dictionary:
	if not _is_profile_ready():
		_set_discovery_status("Complete profile in Settings.")
		return {"ok": false, "manual_required": false}

	local_player_name = _resolve_local_player_name()
	_set_profile_username(local_player_name)
	_stop_lan_discovery_listener()

	var target_address := manual_host.strip_edges()
	var target_port := port

	if manual_mode and target_address == "":
		_set_manual_join_visible(true)
		_set_discovery_status("Enter host/IP manually.")
		return {"ok": false, "manual_required": true}

	if target_address != "":
		_set_manual_join_visible(true)
		return _connect_to_server(target_address, target_port)

	_set_discovery_status("Searching LAN hosts...")
	var discovered_host := await _discover_lan_host()
	if discovered_host.is_empty():
		_set_manual_join_visible(true)
		_set_discovery_status("No LAN host found. Enter host/IP manually.")
		return {"ok": false, "manual_required": true}

	target_address = String(discovered_host.get("address", "")).strip_edges()
	target_port = int(discovered_host.get("port", port))
	_set_discovery_status("Host found: %s" % target_address)
	return _connect_to_server(target_address, target_port)

func start_match() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if not multiplayer.is_server():
		return
	if match_started:
		return

	match_started = true
	_stop_lan_discovery_listener()
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, match_started)
	_persist_runtime_state()
	_start_match_ui.rpc()
	_emit_server_map_load_requested()

func return_to_lobby_after_match() -> void:
	_stop_lan_discovery_listener()
	_release_mouse_capture()
	_reset_network_session()

	player_names.clear()
	player_avatar_ids.clear()
	match_started = false
	persisted_player_names.clear()
	persisted_player_avatar_ids.clear()
	persisted_match_started = false
	manual_join_visible = false
	discovery_status_text = "Auto-discover LAN host"
	_emit_main_menu_state()

	if get_tree().current_scene == null or get_tree().current_scene.scene_file_path != MAIN_MENU_SCENE_PATH:
		get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)

func set_selected_map_scene_path(path: String) -> void:
	var cleaned_path := path.strip_edges()
	if cleaned_path == "":
		return
	map_scene_path = cleaned_path
	persisted_map_scene_path = cleaned_path
	_emit_lobby_sync()

func get_lobby_sync_payload() -> Dictionary:
	return {
		"player_names": player_names.duplicate(true),
		"player_avatar_ids": player_avatar_ids.duplicate(true),
		"match_started": match_started,
		"map_scene_path": map_scene_path,
		"is_connected": multiplayer.multiplayer_peer != null,
		"is_server": multiplayer.multiplayer_peer != null and multiplayer.is_server(),
		"local_peer_id": multiplayer.get_unique_id() if multiplayer.multiplayer_peer != null else -1,
	}

func get_player_name(peer_id: int) -> String:
	return String(player_names.get(peer_id, "Player %d" % peer_id))

func is_peer_connected(peer_id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if peer_id == multiplayer.get_unique_id():
		return true
	return multiplayer.get_peers().has(peer_id)

func get_discovery_status_text() -> String:
	return discovery_status_text

func is_manual_join_visible() -> bool:
	return manual_join_visible

func request_lobby_sync_from_server() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.is_server():
		return
	rpc_id(1, "_register_player_profile", local_player_name, _resolve_local_avatar_id())
	request_lobby_sync.rpc_id(1)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _start_match_ui() -> void:
	lobby_ui_visibility_requested.emit(false)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _sync_lobby_data_to_all(names: Dictionary, avatars: Dictionary, has_started: bool) -> void:
	player_names = names.duplicate(true)
	player_avatar_ids = avatars.duplicate(true)
	match_started = has_started
	_persist_runtime_state()
	_emit_lobby_sync()

@rpc("any_peer", "call_remote", "reliable", RPC_CHANNEL_UI)
func _register_player_profile(raw_name: String, raw_avatar_id: String) -> void:
	if not multiplayer.is_server():
		return

	if match_started:
		var peer := multiplayer.multiplayer_peer
		if peer != null:
			peer.disconnect_peer(multiplayer.get_remote_sender_id())
		return

	var peer_id := multiplayer.get_remote_sender_id()
	var resolved_name := _sanitize_player_name(raw_name, peer_id)
	_set_player_name_for_peer(peer_id, resolved_name)
	_set_player_avatar_for_peer(peer_id, raw_avatar_id)
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, match_started)
	_persist_runtime_state()

@rpc("any_peer", "call_remote", "reliable", RPC_CHANNEL_UI)
func request_lobby_sync() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	_sync_lobby_data_to_all.rpc_id(peer_id, player_names, player_avatar_ids, match_started)

func _open_lobby_scene() -> void:
	_persist_runtime_state()
	if get_tree().current_scene != null and get_tree().current_scene.scene_file_path == LOBBY_SCENE_PATH:
		return
	call_deferred("_change_scene_to_lobby")

func _change_scene_to_lobby() -> void:
	get_tree().change_scene_to_file(LOBBY_SCENE_PATH)

func _emit_server_map_load_requested() -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	server_map_load_requested.emit(map_scene_path)

func _emit_lobby_sync() -> void:
	lobby_sync_updated.emit(get_lobby_sync_payload())

func _emit_main_menu_state() -> void:
	main_menu_state_changed.emit(discovery_status_text, manual_join_visible)

func _set_manual_join_visible(visible: bool) -> void:
	manual_join_visible = visible
	_emit_main_menu_state()

func _set_discovery_status(text: String) -> void:
	discovery_status_text = text
	_emit_main_menu_state()

func _connect_to_server(target_address: String, target_port: int) -> Dictionary:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(target_address, target_port)
	if error != OK:
		push_error("Failed to connect to server: %s (%s)" % [error, error_string(error)])
		_set_manual_join_visible(true)
		_set_discovery_status("Connect failed. Enter host/IP manually.")
		return {"ok": false, "manual_required": true}

	multiplayer.multiplayer_peer = peer
	_set_discovery_status("Connecting to %s:%d..." % [target_address, target_port])
	return {"ok": true, "manual_required": false}

func _connect_multiplayer_signals() -> void:
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _on_connected_to_server() -> void:
	rpc_id(1, "_register_player_profile", local_player_name, _resolve_local_avatar_id())
	_open_lobby_scene()

func _on_connection_failed() -> void:
	_set_manual_join_visible(true)
	_set_discovery_status("Connection failed. Enter host/IP manually.")
	_release_mouse_capture()

func _on_server_disconnected() -> void:
	_set_manual_join_visible(true)
	_set_discovery_status("Disconnected from server.")
	_release_mouse_capture()

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if match_started:
		var peer := multiplayer.multiplayer_peer
		if peer != null:
			peer.disconnect_peer(id)
		return
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, match_started)
	_persist_runtime_state()
	_emit_lobby_sync()

func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		player_names.erase(id)
		player_avatar_ids.erase(id)
		_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, match_started)
		_persist_runtime_state()
	_emit_lobby_sync()

func _set_player_name_for_peer(peer_id: int, raw_name: String) -> void:
	player_names[peer_id] = _sanitize_player_name(raw_name, peer_id)
	_persist_runtime_state()

func _set_player_avatar_for_peer(peer_id: int, raw_avatar_id: String) -> void:
	player_avatar_ids[peer_id] = _sanitize_avatar_id(raw_avatar_id)
	_persist_runtime_state()

func _resolve_local_player_name() -> String:
	var profile_name := _get_profile_username()
	if profile_name.strip_edges() != "":
		return _sanitize_player_name(profile_name, 1)

	var raw_name := ""
	if OS.has_feature("dedicated_server"):
		raw_name = "DedicatedServer"
	else:
		raw_name = OS.get_environment("USER")
		if raw_name.strip_edges() == "":
			raw_name = OS.get_environment("USERNAME")
	if raw_name.strip_edges() == "":
		raw_name = DEFAULT_PLAYER_NAME
	var peer_id := 1
	if multiplayer.multiplayer_peer != null:
		peer_id = multiplayer.get_unique_id()
	return _sanitize_player_name(raw_name, peer_id)

func _resolve_local_avatar_id() -> String:
	var profile := _profile()
	if profile != null:
		return _sanitize_avatar_id(profile.get_avatar_id())
	return DEFAULT_AVATAR_ID

func _sanitize_player_name(raw_name: String, peer_id: int) -> String:
	var cleaned := raw_name.strip_edges()
	if cleaned == "":
		cleaned = DEFAULT_PLAYER_NAME
	return cleaned.substr(0, 24)

func _sanitize_avatar_id(raw_avatar_id: String) -> String:
	var cleaned := raw_avatar_id.strip_edges()
	if cleaned == "":
		return DEFAULT_AVATAR_ID
	var profile := _profile()
	if profile != null and profile.get_avatar_catalog().has(cleaned):
		return cleaned
	return DEFAULT_AVATAR_ID

func _apply_default_player_name() -> void:
	local_player_name = _resolve_local_player_name()

func _apply_persisted_map_scene_path() -> void:
	if persisted_map_scene_path.strip_edges() != "":
		map_scene_path = persisted_map_scene_path
	else:
		persisted_map_scene_path = map_scene_path.strip_edges()

func _persist_runtime_state() -> void:
	_set_profile_username(local_player_name)
	persisted_player_names = player_names.duplicate(true)
	persisted_player_avatar_ids = player_avatar_ids.duplicate(true)
	persisted_match_started = match_started
	persisted_map_scene_path = map_scene_path.strip_edges()

## The PlayerProfile autoload, or null while it is not in the tree yet (it is
## registered after this one, so it is missing during our own _ready).
func _profile() -> PlayerProfileStore:
	return get_node_or_null("/root/PlayerProfile") as PlayerProfileStore

func _get_profile_username() -> String:
	var profile := _profile()
	return profile.get_username() if profile != null else ""

func _is_profile_ready() -> bool:
	var profile := _profile()
	return profile.is_profile_completed() if profile != null else true

func _set_profile_username(name: String) -> void:
	var profile := _profile()
	if profile != null:
		profile.set_username(name)

func _reset_network_session() -> void:
	var existing_peer := multiplayer.multiplayer_peer
	if existing_peer != null:
		existing_peer.close()
		multiplayer.multiplayer_peer = null

func _release_mouse_capture() -> void:
	Input.emulate_mouse_from_touch = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _start_lan_discovery_listener() -> void:
	if not enable_lan_discovery:
		return
	_stop_lan_discovery_listener()

	discovery_listener = PacketPeerUDP.new()
	var bind_error := discovery_listener.bind(discovery_port, "0.0.0.0")
	if bind_error != OK:
		push_warning("LAN discovery disabled (bind failed): %s" % bind_error)
		discovery_listener = null
		discovery_listener_active = false
		set_process(false)
		return

	discovery_listener.set_broadcast_enabled(true)
	discovery_listener_active = true
	set_process(true)

func _stop_lan_discovery_listener() -> void:
	if discovery_listener != null:
		discovery_listener.close()
	discovery_listener = null
	discovery_listener_active = false
	set_process(false)

func _discover_lan_host() -> Dictionary:
	if not enable_lan_discovery:
		return {}

	var probe := PacketPeerUDP.new()
	var bind_error := probe.bind(0, "0.0.0.0")
	if bind_error != OK:
		push_warning("LAN discovery probe failed to bind: %s" % bind_error)
		return {}

	probe.set_broadcast_enabled(true)
	probe.set_dest_address("255.255.255.255", discovery_port)

	for _attempt in range(discovery_attempts):
		var request := "%s:DISCOVER" % discovery_token
		var send_error := probe.put_packet(request.to_utf8_buffer())
		if send_error != OK:
			continue

		var timeout_deadline := Time.get_ticks_msec() + int(discovery_timeout_seconds * 1000.0)
		while Time.get_ticks_msec() < timeout_deadline:
			await get_tree().process_frame
			while probe.get_available_packet_count() > 0:
				var payload := probe.get_packet().get_string_from_utf8()
				var sender_ip := probe.get_packet_ip()
				if not payload.begins_with("%s:HOST:" % discovery_token):
					continue
				var parts := payload.split(":")
				var discovered_port := port
				if parts.size() >= 3:
					discovered_port = int(parts[2])
				probe.close()
				return {
					"address": sender_ip,
					"port": discovered_port,
				}

	probe.close()
	return {}
