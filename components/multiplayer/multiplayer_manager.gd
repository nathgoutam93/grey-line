extends Node

@export var port: int = 3000
@export var max_players: int = 8
@export var address: String = "127.0.0.1"
@export var map_scene_path: String = "res://scenes/maps/counter_strike/counter_strike.tscn"
@export var enable_lan_discovery: bool = true
@export var discovery_port: int = 3001
@export var discovery_timeout_seconds: float = 0.4
@export var discovery_attempts: int = 3
@export var discovery_token: String = "GREYLINE_DISCOVERY_V1"

@onready var level: Node2D = get_node("../Level")
@onready var ui_layer: CanvasLayer = get_node("../UI")
@onready var hostname_input: LineEdit = get_node_or_null("../UI/Control/hostname")
@onready var player_name_input: LineEdit = get_node_or_null("../UI/Control/player_name")
@onready var discovery_status_label: Label = get_node_or_null("../UI/Control/discovery_status")
@onready var lobby_status_label: Label = get_node_or_null("../UI/Control/lobby_status")
@onready var lobby_players_label: Label = get_node_or_null("../UI/Control/lobby_players")
@onready var start_match_button: TouchScreenButton = get_node_or_null("../UI/Control/start_match")

var local_player_name := ""
var player_names := {}
var match_started := false
var discovery_listener: PacketPeerUDP
var discovery_listener_active := false
const DEFAULT_PLAYER_NAME := "Player"
const MAIN_MENU_SCENE_PATH := "res://scenes/main_menu/main_menu.tscn"
const LOBBY_SCENE_PATH := "res://scenes/lobby/lobby.tscn"
static var persisted_player_names := {}
static var persisted_match_started := false

func _ready():
	add_to_group("multiplayer_manager")
	_release_mouse_capture()

	if _is_main_menu_scene():
		# Entering main menu always starts from a clean networking state.
		_reset_network_session()
		player_names.clear()
		match_started = false
		persisted_player_names.clear()
		persisted_match_started = false
		if ui_layer:
			ui_layer.show()
	elif multiplayer.multiplayer_peer != null:
		player_names = persisted_player_names.duplicate(true)
		match_started = persisted_match_started

	_apply_default_player_name()
	if hostname_input and hostname_input.text.strip_edges() == "" and not _is_loopback_address(address):
		hostname_input.text = address
	_set_manual_join_visible(false)
	_set_discovery_status("Auto-discover LAN host")

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

	if start_match_button != null and not start_match_button.pressed.is_connected(start_match):
		start_match_button.pressed.connect(start_match)
	if player_name_input != null:
		player_name_input.editable = false

	if OS.has_feature("dedicated_server"):
		local_player_name = "DedicatedServer"
		host_game()
		return

	_refresh_lobby_ui()
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		_start_lan_discovery_listener()
	if _is_lobby_scene() and multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		call_deferred("_request_lobby_sync_from_server")

	# Some Android builds can alter LineEdit state after initial _ready().
	call_deferred("_apply_default_player_name")

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


func host_game():
	if not _is_profile_ready():
		_set_discovery_status("Complete profile in Settings.")
		return
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port, max_players)
	if error != OK:
		push_error("Failed to start server: %s (%s)" % [error, error_string(error)])
		return

	multiplayer.multiplayer_peer = peer
	local_player_name = _resolve_local_player_name()
	_set_profile_username(local_player_name)
	_set_player_name_for_peer(multiplayer.get_unique_id(), local_player_name)
	match_started = false
	_start_lan_discovery_listener()
	print("Hosting game on port %d..." % port)
	_open_lobby_scene()

func join_game():
	if not _is_profile_ready():
		_set_discovery_status("Complete profile in Settings.")
		return
	local_player_name = _resolve_local_player_name()
	_set_profile_username(local_player_name)
	_stop_lan_discovery_listener()
	var target_address := ""
	var target_port := port

	if hostname_input and hostname_input.visible:
		target_address = hostname_input.text.strip_edges()
		if target_address == "":
			_set_discovery_status("Enter host/IP manually.")
			return
		_connect_to_server(target_address, target_port)
		return

	_set_discovery_status("Searching LAN hosts...")
	var discovered_host := await _discover_lan_host()
	if discovered_host.is_empty():
		_set_manual_join_visible(true)
		_set_discovery_status("No LAN host found. Enter host/IP manually.")
		return

	target_address = String(discovered_host.get("address", "")).strip_edges()
	target_port = int(discovered_host.get("port", port))
	_set_discovery_status("Host found: %s" % target_address)
	_connect_to_server(target_address, target_port)

func _connect_to_server(target_address: String, target_port: int) -> void:
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(target_address, target_port)
	if error != OK:
		push_error("Failed to connect to server: %s (%s)" % [error, error_string(error)])
		_set_manual_join_visible(true)
		_set_discovery_status("Connect failed. Enter host/IP manually.")
		return

	multiplayer.multiplayer_peer = peer
	print("Connecting to server at %s:%d..." % [target_address, target_port])
	_set_discovery_status("Connecting to %s:%d..." % [target_address, target_port])

func _on_connected_to_server() -> void:
	rpc_id(1, "_register_player_name", local_player_name)
	_open_lobby_scene()

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if match_started:
		var peer := multiplayer.multiplayer_peer
		if peer != null and peer.has_method("disconnect_peer"):
			peer.disconnect_peer(id)
		return
	_sync_player_names_to_all.rpc(player_names, match_started)
	_persist_runtime_state()
	_refresh_lobby_ui()

func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		player_names.erase(id)
		_sync_player_names_to_all.rpc(player_names, match_started)
		_persist_runtime_state()
	_refresh_lobby_ui()

func _on_connection_failed() -> void:
	_set_manual_join_visible(true)
	_set_discovery_status("Connection failed. Enter host/IP manually.")
	_release_mouse_capture()
	if ui_layer:
		ui_layer.show()

func _on_server_disconnected() -> void:
	_set_manual_join_visible(true)
	_set_discovery_status("Disconnected from server.")
	_release_mouse_capture()
	if ui_layer:
		ui_layer.show()

@rpc("any_peer", "reliable")
func _register_player_name(raw_name: String) -> void:
	if not multiplayer.is_server():
		return

	if match_started:
		var peer := multiplayer.multiplayer_peer
		if peer != null and peer.has_method("disconnect_peer"):
			peer.disconnect_peer(multiplayer.get_remote_sender_id())
		return

	var peer_id := multiplayer.get_remote_sender_id()
	var resolved_name := _sanitize_player_name(raw_name, peer_id)
	_set_player_name_for_peer(peer_id, resolved_name)
	_sync_player_names_to_all.rpc(player_names, match_started)
	_persist_runtime_state()

func get_player_name(peer_id: int) -> String:
	return String(player_names.get(peer_id, "Player %d" % peer_id))

func is_peer_connected(peer_id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if peer_id == multiplayer.get_unique_id():
		return true
	return multiplayer.get_peers().has(peer_id)

func _set_player_name_for_peer(peer_id: int, raw_name: String) -> void:
	player_names[peer_id] = _sanitize_player_name(raw_name, peer_id)
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

func _sanitize_player_name(raw_name: String, peer_id: int) -> String:
	var cleaned := raw_name.strip_edges()
	if cleaned == "":
		cleaned = DEFAULT_PLAYER_NAME
	return cleaned.substr(0, 24)

func _load_map_scene() -> PackedScene:
	if map_scene_path.strip_edges() == "":
		push_error("No map_scene_path configured on MultiplayerManager.")
		return null

	var loaded := load(map_scene_path)
	if loaded is PackedScene:
		return loaded

	push_error("Failed to load map scene at path: %s" % map_scene_path)
	return null

func _apply_default_player_name() -> void:
	var profile_name := _get_profile_username()
	if player_name_input == null and profile_name.strip_edges() != "":
		local_player_name = _sanitize_player_name(profile_name, 1)
		return

	local_player_name = _resolve_local_player_name()
	if player_name_input == null:
		push_warning("player_name LineEdit not found at ../UI/Control/player_name")
		return

	player_name_input.editable = false
	player_name_input.text = local_player_name
	if player_name_input.placeholder_text.strip_edges() == "":
		player_name_input.placeholder_text = "Change in Settings"

func _start_game():
	if ui_layer:
		ui_layer.hide()

	if multiplayer.is_server():
		var map_scene := _load_map_scene()
		if map_scene == null:
			return
		_change_level.call_deferred(map_scene)

func _change_level(scene: PackedScene):
	for c in level.get_children():
		level.remove_child(c)
		c.queue_free()

	level.add_child(scene.instantiate())

func return_to_lobby_after_match() -> void:
	_stop_lan_discovery_listener()
	_release_mouse_capture()
	_reset_network_session()

	player_names.clear()
	match_started = false
	persisted_player_names.clear()
	persisted_match_started = false
	if ui_layer:
		ui_layer.show()
	_set_manual_join_visible(false)
	_set_discovery_status("Auto-discover LAN host")

	for c in level.get_children():
		level.remove_child(c)
		c.queue_free()

	if not _is_main_menu_scene():
		get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)

func start_match() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if not multiplayer.is_server():
		return
	if match_started:
		return

	match_started = true
	_stop_lan_discovery_listener()
	_sync_player_names_to_all.rpc(player_names, match_started)
	_persist_runtime_state()
	_start_match_ui.rpc()
	_start_game()

@rpc("authority", "call_local", "reliable")
func _start_match_ui() -> void:
	if ui_layer:
		ui_layer.hide()

@rpc("authority", "call_local", "reliable")
func _sync_player_names_to_all(names: Dictionary, has_started: bool) -> void:
	player_names = names.duplicate(true)
	match_started = has_started
	_persist_runtime_state()
	_refresh_lobby_ui()

func _refresh_lobby_ui() -> void:
	var is_lobby := _is_lobby_scene()
	if start_match_button != null:
		start_match_button.visible = is_lobby and multiplayer.multiplayer_peer != null and multiplayer.is_server() and not match_started

	if lobby_status_label != null:
		if not is_lobby:
			lobby_status_label.text = ""
		elif multiplayer.multiplayer_peer == null:
			lobby_status_label.text = "Not connected"
		elif match_started:
			lobby_status_label.text = "Match started"
		elif multiplayer.is_server():
			lobby_status_label.text = "Lobby ready - host can start"
		else:
			lobby_status_label.text = "Waiting for host to start"

	if lobby_players_label != null:
		if not is_lobby:
			lobby_players_label.text = ""
			return
		var ids := player_names.keys()
		ids.sort()
		var lines: Array[String] = []
		for id_variant in ids:
			var peer_id := int(id_variant)
			lines.append("%d - %s" % [peer_id, String(player_names.get(peer_id, "Player %d" % peer_id))])
		lobby_players_label.text = "\n".join(lines)

func _open_lobby_scene() -> void:
	_persist_runtime_state()
	call_deferred("_change_scene_to_lobby")

func _change_scene_to_lobby() -> void:
	if _is_lobby_scene():
		return
	get_tree().change_scene_to_file(LOBBY_SCENE_PATH)

func _persist_runtime_state() -> void:
	_set_profile_username(local_player_name)
	persisted_player_names = player_names.duplicate(true)
	persisted_match_started = match_started

func _get_profile_username() -> String:
	var profile := get_node_or_null("/root/PlayerProfile")
	if profile != null and profile.has_method("get_username"):
		return String(profile.call("get_username"))
	return ""

func _is_profile_ready() -> bool:
	var profile := get_node_or_null("/root/PlayerProfile")
	if profile != null and profile.has_method("is_profile_completed"):
		return bool(profile.call("is_profile_completed"))
	return true

func _set_profile_username(name: String) -> void:
	var profile := get_node_or_null("/root/PlayerProfile")
	if profile != null and profile.has_method("set_username"):
		profile.call("set_username", name)

func _request_lobby_sync_from_server() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.is_server():
		return
	rpc_id(1, "_register_player_name", local_player_name)
	request_lobby_sync.rpc_id(1)

@rpc("any_peer", "reliable")
func request_lobby_sync() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	_sync_player_names_to_all.rpc_id(peer_id, player_names, match_started)

func _reset_network_session() -> void:
	var existing_peer := multiplayer.multiplayer_peer
	if existing_peer != null:
		if existing_peer.has_method("close"):
			existing_peer.close()
		multiplayer.multiplayer_peer = null

func _is_main_menu_scene() -> bool:
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return false
	return current_scene.scene_file_path == MAIN_MENU_SCENE_PATH

func _is_lobby_scene() -> bool:
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return false
	return current_scene.scene_file_path == LOBBY_SCENE_PATH

func _set_manual_join_visible(visible: bool) -> void:
	if hostname_input:
		hostname_input.visible = visible

func _set_discovery_status(text: String) -> void:
	if discovery_status_label:
		discovery_status_label.text = text

func _release_mouse_capture() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _is_loopback_address(value: String) -> bool:
	var trimmed := value.strip_edges()
	return trimmed == "" or trimmed == "127.0.0.1" or trimmed == "localhost"

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
