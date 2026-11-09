extends Node

signal main_menu_state_changed(status_text: String, manual_join_visible: bool)
signal lobby_sync_updated(payload: Dictionary)
signal lobby_ui_visibility_requested(visible: bool)
signal server_map_load_requested(map_scene_path: String)
signal bot_added(bot_id: int)
signal bot_removed(bot_id: int)
## Server: a player dropped out of a running match without confirming Leave;
## their slot (name, team, stats) is held until the match ends.
signal player_dropped(peer_id: int)
## Server: a slot was released (explicit Leave, or a disconnect outside a match).
signal player_left(peer_id: int)
## Server: a dropped player reconnected as `new_id` and took back `old_id`'s slot.
signal player_rejoined(old_id: int, new_id: int)

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
var player_teams := {}
var match_started := false
var bot_ids: Array[int] = []
var _next_bot_id := -1

var discovery_listener: PacketPeerUDP
var discovery_listener_active := false
var manual_join_visible := false
var discovery_status_text := "Auto-discover LAN host"

const DEFAULT_PLAYER_NAME := "Player"
const DEFAULT_AVATAR_ID := "avatar_01"
const MAIN_MENU_SCENE_PATH := "res://scenes/main_menu/main_menu.tscn"
const LOBBY_SCENE_PATH := "res://scenes/lobby/lobby.tscn"
const RPC_CHANNEL_UI := 2
const MAPS: Array[String] = ["res://scenes/maps/map_1/map_1.tscn", "res://scenes/maps/map_1/map_1_rounds.tscn", "res://scenes/maps/cqc_1/cqc_1.tscn"]

## Reconnect. Clients get a random server-issued token when they register; a
## client that drops out of a running match presents it to take back its
## slot under its new ENet peer id. Explicit Leave forfeits the slot.
const REJOIN_TICKET_PATH := "user://rejoin_ticket.json"
const REJOIN_TICKET_MAX_AGE_SECONDS := 6 * 3600
const REJOIN_TOKEN_BYTES := 16
const REJOIN_TOKEN_LENGTH := REJOIN_TOKEN_BYTES * 2 # hex
## Server: a peer that connects mid-match must present a valid token this fast.
const REJOIN_ADMIT_TIMEOUT_SECONDS := 10.0
## Client: automatic attempts after a drop, before falling back to the menu button.
const AUTO_REJOIN_WINDOW_SECONDS := 60.0
const MANUAL_REJOIN_WINDOW_SECONDS := 8.0
const REJOIN_RETRY_SECONDS := 2.0
const LEAVE_DISCONNECT_WAIT_SECONDS := 1.0

# Server state
var _slot_tokens := {} # peer id -> token
var dropped_ids: Array[int] = [] # held slots whose player is disconnected
var _peer_aliases := {} # previous peer id of a rejoined slot -> its current id
var _forfeited := {} # peers that confirmed Leave

# Client state
var _rejoin_ticket := {} # { address, port, token, saved_unix }
var _rejoin_pending := false
var _rejoin_deadline_msec := 0
var _rejoin_attempt := 0
var _match_closed := false
var _leaving := false
var _last_server_address := ""
var _last_server_port := 0
var rejoin_status := ""
var _menu_notice := "" # shown once by the next main menu

static var persisted_player_names := {}
static var persisted_player_avatar_ids := {}
static var persisted_player_teams := {}
static var persisted_match_started := false
static var persisted_map_scene_path := ""

func _ready() -> void:
	_load_rejoin_ticket()
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
	_rejoin_pending = false
	rejoin_status = ""
	_clear_slot_state()
	player_names.clear()
	player_avatar_ids.clear()
	player_teams.clear()
	match_started = false
	persisted_player_names.clear()
	persisted_player_avatar_ids.clear()
	persisted_player_teams.clear()
	persisted_match_started = false
	manual_join_visible = false
	discovery_status_text = _menu_notice if not _menu_notice.is_empty() else "Auto-discover LAN host"
	_menu_notice = ""
	_emit_main_menu_state()

func enter_lobby() -> void:
	_release_mouse_capture()
	_apply_default_player_name()

	if multiplayer.multiplayer_peer != null:
		player_names = persisted_player_names.duplicate(true)
		player_avatar_ids = persisted_player_avatar_ids.duplicate(true)
		player_teams = persisted_player_teams.duplicate(true)
		match_started = persisted_match_started

	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		_start_lan_discovery_listener()

	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		call_deferred("request_lobby_sync_from_server")

	if _rejoin_pending and multiplayer.multiplayer_peer == null:
		_attempt_rejoin.call_deferred()

	_emit_lobby_sync()

func host_game() -> Dictionary:
	if not _is_profile_ready():
		_set_discovery_status("Complete profile in Settings.")
		return {"ok": false, "message": "Profile incomplete."}

	clear_rejoin_ticket()
	_leaving = false
	_clear_slot_state()
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
	if not OS.has_feature("dedicated_server"):
		player_teams[multiplayer.get_unique_id()] = Teams.pick_team_for_new_player(player_teams)
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
	clear_rejoin_ticket()
	_rejoin_pending = false

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
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, player_teams, match_started)
	_persist_runtime_state()
	_start_match_ui.rpc()
	_emit_server_map_load_requested()

func return_to_lobby_after_match() -> void:
	if _rejoin_pending:
		return # A dropped client is already on its way back (see _begin_rejoin).
	_stop_lan_discovery_listener()
	_release_mouse_capture()
	if NetUtil.has_active_peer(multiplayer) and multiplayer.is_server() and not multiplayer.get_peers().is_empty():
		# Ending the match or the host leaving closes it: nobody can rejoin.
		_match_closed_event.rpc()
		_flush_peer()
	_reset_network_session()
	_clear_slot_state()

	player_names.clear()
	player_avatar_ids.clear()
	player_teams.clear()
	match_started = false
	persisted_player_names.clear()
	persisted_player_avatar_ids.clear()
	persisted_player_teams.clear()
	persisted_match_started = false
	manual_join_visible = false
	discovery_status_text = "Auto-discover LAN host"
	_emit_main_menu_state()

	if get_tree().current_scene == null or get_tree().current_scene.scene_file_path != MAIN_MENU_SCENE_PATH:
		get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)

func set_selected_map_scene_path(path: String) -> void:
	var cleaned_path := path.strip_edges()
	if not NetUtil.has_active_peer(multiplayer) or not multiplayer.is_server() or match_started or cleaned_path not in MAPS:
		return
	_selected_map_event.rpc(cleaned_path)

func cycle_selected_map() -> void:
	var index := MAPS.find(map_scene_path)
	set_selected_map_scene_path(MAPS[(index + 1) % MAPS.size()])

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _selected_map_event(path: String) -> void:
	if path not in MAPS:
		return
	map_scene_path = path
	persisted_map_scene_path = path
	_emit_lobby_sync()

func get_lobby_sync_payload() -> Dictionary:
	return {
		"player_names": player_names.duplicate(true),
		"player_avatar_ids": player_avatar_ids.duplicate(true),
		"player_teams": player_teams.duplicate(true),
		"match_started": match_started,
		"map_scene_path": map_scene_path,
		"max_players": max_players,
		"is_connected": multiplayer.multiplayer_peer != null,
		"is_server": multiplayer.multiplayer_peer != null and multiplayer.is_server(),
		"local_peer_id": multiplayer.get_unique_id() if multiplayer.multiplayer_peer != null else -1,
		"rejoin_status": rejoin_status,
		"rejoining": _rejoin_pending,
	}

func get_player_name(peer_id: int) -> String:
	peer_id = current_id(peer_id)
	return String(player_names.get(peer_id, "Player %d" % peer_id))

func get_team(peer_id: int) -> int:
	var mode := MatchGameMode.current(get_tree())
	if mode != null and not mode.teams_enabled:
		return Teams.NONE
	return int(player_teams.get(current_id(peer_id), Teams.NONE))

## Authoritative assignment; test scenarios may also use this during a match.
func set_team(peer_id: int, team: int) -> void:
	if not NetUtil.has_active_peer(multiplayer) or not multiplayer.is_server():
		return
	if not player_names.has(peer_id) or team not in [Teams.ALPHA, Teams.BRAVO, Teams.NONE]:
		return
	player_teams[peer_id] = team
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, player_teams, match_started)

@rpc("any_peer", "call_remote", "reliable", RPC_CHANNEL_UI)
func request_team(team: int) -> void:
	if not multiplayer.is_server() or match_started:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0 or not multiplayer.get_peers().has(peer_id):
		return
	if Teams.can_switch(player_teams, peer_id, team, ceili(max_players / 2.0)):
		set_team(peer_id, team)

func is_peer_connected(peer_id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if peer_id in bot_ids:
		return true
	if peer_id == multiplayer.get_unique_id():
		return true
	return multiplayer.get_peers().has(peer_id)

## Server only: register a puppet in the lobby and spawn it if a match is live.
func add_bot() -> int:
	if not NetUtil.has_active_peer(multiplayer) or not multiplayer.is_server():
		return 0
	var bot_id := _next_bot_id
	_next_bot_id -= 1
	bot_ids.append(bot_id)
	player_names[bot_id] = "Bot %d" % -bot_id
	player_avatar_ids[bot_id] = DEFAULT_AVATAR_ID
	player_teams[bot_id] = Teams.pick_team_for_new_player(player_teams)
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, player_teams, match_started)
	if match_started:
		bot_added.emit(bot_id)
	return bot_id

func remove_bot(bot_id: int) -> void:
	if not NetUtil.has_active_peer(multiplayer) or not multiplayer.is_server() or bot_id not in bot_ids:
		return
	# Unregister before freeing so the spawner cannot respawn this player.
	bot_ids.erase(bot_id)
	player_names.erase(bot_id)
	player_avatar_ids.erase(bot_id)
	player_teams.erase(bot_id)
	for node in get_tree().get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player != null and player.owner_peer_id == bot_id:
			player.queue_free()
	bot_removed.emit(bot_id)
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, player_teams, match_started)

func is_bot(peer_id: int) -> bool:
	return peer_id < 0

## Server: the id that now owns `peer_id`'s slot (a rejoined player's new peer
## id; otherwise `peer_id` itself). A dropped player's body keeps its old id.
func current_id(peer_id: int) -> int:
	return int(_peer_aliases.get(peer_id, peer_id))

## Server: true while `peer_id`'s slot belongs to the match: connected,
## dropped and held, or rejoined under a new id.
func holds_slot(peer_id: int) -> bool:
	return player_names.has(current_id(peer_id))

func is_dropped(peer_id: int) -> bool:
	return peer_id in dropped_ids

# --- reconnect: server ------------------------------------------------------

func _clear_slot_state() -> void:
	_slot_tokens.clear()
	dropped_ids.clear()
	_peer_aliases.clear()
	_forfeited.clear()

func _issue_rejoin_token(peer_id: int) -> void:
	if not _slot_tokens.has(peer_id):
		_slot_tokens[peer_id] = Crypto.new().generate_random_bytes(REJOIN_TOKEN_BYTES).hex_encode()
	_receive_rejoin_token.rpc_id(peer_id, String(_slot_tokens[peer_id]))

func _slot_for_token(token: String) -> int:
	if token.length() != REJOIN_TOKEN_LENGTH:
		return 0
	for id in _slot_tokens:
		if String(_slot_tokens[id]) == token:
			return int(id)
	return 0

func _hold_slot(peer_id: int) -> void:
	if peer_id in dropped_ids:
		return
	dropped_ids.append(peer_id)
	print("Holding slot of dropped peer %d" % peer_id)
	player_dropped.emit(peer_id)

func _release_slot(peer_id: int) -> void:
	player_names.erase(peer_id)
	player_avatar_ids.erase(peer_id)
	player_teams.erase(peer_id)
	_slot_tokens.erase(peer_id)
	_forfeited.erase(peer_id)
	dropped_ids.erase(peer_id)
	player_left.emit(peer_id)
	if multiplayer.multiplayer_peer != null:
		_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, player_teams, match_started)
	_persist_runtime_state()

func _rekey_slot(old_id: int, new_id: int) -> void:
	for data: Dictionary in [player_names, player_avatar_ids, player_teams, _slot_tokens]:
		if data.has(old_id):
			data[new_id] = data[old_id]
			data.erase(old_id)
	dropped_ids.erase(old_id)
	_forfeited.erase(old_id)
	for alias in _peer_aliases.keys():
		if int(_peer_aliases[alias]) == old_id:
			_peer_aliases[alias] = new_id
	_peer_aliases[old_id] = new_id

## Client -> server: take back a held slot with the token issued at registration.
@rpc("any_peer", "call_remote", "reliable", RPC_CHANNEL_UI)
func _request_rejoin(token: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not multiplayer.get_peers().has(sender) or player_names.has(sender):
		return
	var old_id := _slot_for_token(token)
	if not match_started or old_id == 0 or old_id == sender:
		_rejoin_rejected.rpc_id(sender, "The match is over." if not match_started else "Your slot is no longer held.")
		_flush_peer()
		multiplayer.multiplayer_peer.disconnect_peer(sender)
		return
	if old_id not in dropped_ids:
		# Back before the old connection timed out: drop it now.
		_hold_slot(old_id)
		_rekey_slot(old_id, sender)
		multiplayer.multiplayer_peer.disconnect_peer(old_id)
	else:
		_rekey_slot(old_id, sender)
	print("Peer %d rejoined the slot of %d" % [sender, old_id])
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, player_teams, match_started)
	_selected_map_event.rpc_id(sender, map_scene_path)
	_rejoin_accepted.rpc_id(sender)
	_persist_runtime_state()
	player_rejoined.emit(old_id, sender)

## Client -> server: the player confirmed Leave; release the slot for good.
@rpc("any_peer", "call_remote", "reliable", RPC_CHANNEL_UI)
func forfeit_match() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not multiplayer.get_peers().has(sender) or not player_names.has(sender):
		return
	_forfeited[sender] = true
	multiplayer.multiplayer_peer.disconnect_peer(sender)

func _expire_unadmitted_peer(peer_id: int) -> void:
	await get_tree().create_timer(REJOIN_ADMIT_TIMEOUT_SECONDS).timeout
	if NetUtil.has_active_peer(multiplayer) and multiplayer.is_server() and multiplayer.get_peers().has(peer_id) and not player_names.has(peer_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)

## Sends queued packets now (an RPC right before closing would be lost).
func _flush_peer() -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet != null and enet.host != null:
		enet.host.flush()

# --- reconnect: client ------------------------------------------------------

## A ticket counts once its match has started (saved_unix is set then).
func has_rejoin_ticket() -> bool:
	return String(_rejoin_ticket.get("token", "")).length() == REJOIN_TOKEN_LENGTH and _rejoin_ticket.has("saved_unix")

func is_rejoining() -> bool:
	return _rejoin_pending

func clear_rejoin_ticket() -> void:
	_rejoin_ticket.clear()
	if _ticket_persistence_enabled() and FileAccess.file_exists(REJOIN_TICKET_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(REJOIN_TICKET_PATH))

## Client: called by game modes when the match result is known.
func mark_match_over() -> void:
	_match_closed = true
	clear_rejoin_ticket()

## Main menu "Rejoin match": a few quick attempts with the saved ticket.
func rejoin_match() -> void:
	if not has_rejoin_ticket():
		return
	_begin_rejoin(MANUAL_REJOIN_WINDOW_SECONDS, "Rejoining match...")

func cancel_rejoin() -> void:
	if not _rejoin_pending:
		return
	_rejoin_pending = false
	rejoin_status = ""
	_reset_network_session()
	_menu_notice = "Rejoin cancelled."
	get_tree().change_scene_to_file.call_deferred(MAIN_MENU_SCENE_PATH)

## Confirmed Leave: forfeit the slot (no rejoin) and go back to the menu.
func leave_match() -> void:
	if _leaving:
		return
	_leaving = true
	clear_rejoin_ticket()
	if NetUtil.has_active_peer(multiplayer) and not multiplayer.is_server():
		forfeit_match.rpc_id(1)
		_flush_peer()
		# The server releases the slot and disconnects us; do not outrun the RPC.
		var deadline := Time.get_ticks_msec() + int(LEAVE_DISCONNECT_WAIT_SECONDS * 1000.0)
		while NetUtil.has_active_peer(multiplayer) and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
	return_to_lobby_after_match()

func _should_rejoin_after_drop() -> bool:
	return match_started and not _match_closed and not _leaving and has_rejoin_ticket()

func _begin_rejoin(window_seconds: float, status: String) -> void:
	_rejoin_pending = true
	_rejoin_attempt = 0
	_rejoin_deadline_msec = Time.get_ticks_msec() + int(window_seconds * 1000.0)
	rejoin_status = status
	_match_closed = false
	_leaving = false
	_release_mouse_capture()
	_reset_network_session()
	player_names.clear()
	player_avatar_ids.clear()
	player_teams.clear()
	match_started = false
	_persist_runtime_state()
	if is_instance_valid(MaskViewProvider.viewport):
		MaskViewProvider.viewport.player_camera = null
		MaskViewProvider.viewport.player = null
	# A fresh lobby scene: the server replicates the map into an empty Level as
	# soon as we connect, so it must be loaded before the connection.
	get_tree().change_scene_to_file.call_deferred(LOBBY_SCENE_PATH)

func _attempt_rejoin() -> void:
	if not _rejoin_pending or multiplayer.multiplayer_peer != null:
		return
	_rejoin_attempt += 1
	var address := String(_rejoin_ticket.get("address", ""))
	var target_port := int(_rejoin_ticket.get("port", port))
	rejoin_status = "Reconnecting to %s (attempt %d)..." % [address, _rejoin_attempt]
	_emit_lobby_sync()
	var peer := ENetMultiplayerPeer.new()
	if address.is_empty() or peer.create_client(address, target_port) != OK:
		_on_rejoin_attempt_failed()
		return
	_last_server_address = address
	_last_server_port = target_port
	multiplayer.multiplayer_peer = peer

func _on_rejoin_attempt_failed() -> void:
	if not _rejoin_pending:
		return
	multiplayer.multiplayer_peer = null
	if Time.get_ticks_msec() < _rejoin_deadline_msec:
		rejoin_status = "Host not reachable. Retrying..."
		_emit_lobby_sync()
		await get_tree().create_timer(REJOIN_RETRY_SECONDS).timeout
		_attempt_rejoin()
		return
	_rejoin_pending = false
	rejoin_status = ""
	_menu_notice = "Could not rejoin. Try Rejoin match again."
	get_tree().change_scene_to_file.call_deferred(MAIN_MENU_SCENE_PATH)

@rpc("authority", "call_remote", "reliable", RPC_CHANNEL_UI)
func _receive_rejoin_token(token: String) -> void:
	if token.length() != REJOIN_TOKEN_LENGTH:
		return
	_rejoin_ticket = {"address": _last_server_address, "port": _last_server_port, "token": token}
	if match_started:
		_save_rejoin_ticket()

@rpc("authority", "call_remote", "reliable", RPC_CHANNEL_UI)
func _rejoin_accepted() -> void:
	_rejoin_pending = false
	rejoin_status = ""
	match_started = true
	_match_closed = false
	_save_rejoin_ticket()
	_persist_runtime_state()
	lobby_ui_visibility_requested.emit(false)
	_emit_lobby_sync()

@rpc("authority", "call_remote", "reliable", RPC_CHANNEL_UI)
func _rejoin_rejected(reason: String) -> void:
	clear_rejoin_ticket()
	_rejoin_pending = false
	rejoin_status = ""
	_reset_network_session()
	_menu_notice = "Could not rejoin: %s" % reason.substr(0, 80)
	get_tree().change_scene_to_file.call_deferred(MAIN_MENU_SCENE_PATH)

@rpc("authority", "call_remote", "reliable", RPC_CHANNEL_UI)
func _match_closed_event() -> void:
	mark_match_over()

func _ticket_persistence_enabled() -> bool:
	return not OS.get_cmdline_user_args().has(PlayerProfileStore.EPHEMERAL_ARG)

func _save_rejoin_ticket() -> void:
	if String(_rejoin_ticket.get("token", "")).length() != REJOIN_TOKEN_LENGTH:
		return
	_rejoin_ticket["saved_unix"] = int(Time.get_unix_time_from_system())
	if not _ticket_persistence_enabled():
		return
	var file := FileAccess.open(REJOIN_TICKET_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_rejoin_ticket))

func _load_rejoin_ticket() -> void:
	if not _ticket_persistence_enabled() or not FileAccess.file_exists(REJOIN_TICKET_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(REJOIN_TICKET_PATH))
	if not (parsed is Dictionary):
		clear_rejoin_ticket()
		return
	var data: Dictionary = parsed
	var age := int(Time.get_unix_time_from_system()) - int(data.get("saved_unix", 0))
	if age < 0 or age > REJOIN_TICKET_MAX_AGE_SECONDS or String(data.get("token", "")).length() != REJOIN_TOKEN_LENGTH:
		clear_rejoin_ticket()
		return
	_rejoin_ticket = {"address": String(data.get("address", "")), "port": int(data.get("port", port)), "token": String(data["token"]), "saved_unix": int(data["saved_unix"])}

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
	if not multiplayer.is_server():
		match_started = true
		_save_rejoin_ticket()
	lobby_ui_visibility_requested.emit(false)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _sync_lobby_data_to_all(names: Dictionary, avatars: Dictionary, teams: Dictionary, has_started: bool) -> void:
	player_names = names.duplicate(true)
	player_avatar_ids = avatars.duplicate(true)
	player_teams = teams.duplicate(true)
	match_started = has_started
	for node in get_tree().get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player != null:
			# A dropped player's body keeps its old id after they rejoin.
			if player_names.has(current_id(player.owner_peer_id)):
				player.team = get_team(player.owner_peer_id)
			player.apply_team_visuals(get_team(multiplayer.get_unique_id()))
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
	if peer_id <= 0 or not multiplayer.get_peers().has(peer_id):
		return
	if not player_teams.has(peer_id):
		player_teams[peer_id] = Teams.pick_team_for_new_player(player_teams)
	var resolved_name := _sanitize_player_name(raw_name, peer_id)
	_set_player_name_for_peer(peer_id, resolved_name)
	_set_player_avatar_for_peer(peer_id, raw_avatar_id)
	_issue_rejoin_token(peer_id)
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, player_teams, match_started)
	_persist_runtime_state()

@rpc("any_peer", "call_remote", "reliable", RPC_CHANNEL_UI)
func request_lobby_sync() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	_sync_lobby_data_to_all.rpc_id(peer_id, player_names, player_avatar_ids, player_teams, match_started)
	_selected_map_event.rpc_id(peer_id, map_scene_path)

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
	_last_server_address = target_address
	_last_server_port = target_port
	_match_closed = false
	_leaving = false
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
	_disable_packet_throttle(1)
	if _rejoin_pending:
		rejoin_status = "Connected. Rejoining match..."
		_emit_lobby_sync()
		_request_rejoin.rpc_id(1, String(_rejoin_ticket.get("token", "")))
		return
	rpc_id(1, "_register_player_profile", local_player_name, _resolve_local_avatar_id())
	_open_lobby_scene()

## ENet's packet throttle drops a share of *unreliable* packets whenever round
## trip time spikes. Everything time-critical here (input frames, world
## snapshots) is unreliable, small and sent at a fixed rate, so throttling
## only throws away state and inputs exactly when the connection is shaky.
## Deceleration 0 keeps the throttle at its maximum: nothing is dropped on
## purpose (redundant inputs and fresh snapshots cover real packet loss).
const ENET_THROTTLE_INTERVAL_MS := 5000 # ENet's default

func _disable_packet_throttle(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var packet_peer := enet.get_peer(peer_id)
	if packet_peer != null:
		packet_peer.throttle_configure(ENET_THROTTLE_INTERVAL_MS, ENetPacketPeer.PACKET_THROTTLE_SCALE, 0)

func _on_connection_failed() -> void:
	if _rejoin_pending:
		_on_rejoin_attempt_failed()
		return
	_set_manual_join_visible(true)
	_set_discovery_status("Connection failed. Enter host/IP manually.")
	_release_mouse_capture()

func _on_server_disconnected() -> void:
	if _rejoin_pending:
		_on_rejoin_attempt_failed()
		return
	if _should_rejoin_after_drop():
		_begin_rejoin(AUTO_REJOIN_WINDOW_SECONDS, "Connection lost. Reconnecting...")
		return
	_set_manual_join_visible(true)
	_set_discovery_status("Disconnected from server.")
	_release_mouse_capture()

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	_disable_packet_throttle(id)
	if match_started:
		# Only a dropped player with a valid token gets in (see _request_rejoin).
		_expire_unadmitted_peer(id)
		return
	_sync_lobby_data_to_all.rpc(player_names, player_avatar_ids, player_teams, match_started)
	_persist_runtime_state()
	_emit_lobby_sync()

func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		if _peer_aliases.has(id):
			pass # The old connection of a slot that has already been rejoined.
		elif match_started and player_names.has(id) and _slot_tokens.has(id) and not _forfeited.has(id):
			_hold_slot(id)
		elif player_names.has(id):
			_release_slot(id)
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
	persisted_player_teams = player_teams.duplicate(true)
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
	bot_ids.clear()
	_next_bot_id = -1
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
