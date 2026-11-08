extends Node
class_name MatchScoreboard

## Kills, deaths, ping and loadout per player, the kill feed and the
## leaderboard (child `Scoreboard` of the game mode). The server owns the
## stats and broadcasts them; clients display them and report their ping.
## Configured by the game mode through setup().

## Server only: a kill took `peer_id` to the score limit.
signal score_limit_reached(peer_id: int)

const STATS_REFRESH_INTERVAL := 0.35
const PING_PROBE_INTERVAL := 1.0
const RPC_CHANNEL_UI := 2

## Server only: cleared when the match ends (stops scoring and refreshes).
var active := true
## { peer_id: { "player_identifier", "kills", "deaths", "ping_ms", "loadout", "current_weapon" } }
var player_stats := {}

var _map: Node2D
var _leaderboard: DeathmatchLeaderboard
var _score_limit := 25
var _stats_refresh_elapsed := 0.0
var _ping_probe_elapsed := 0.0

func setup(map: Node2D, leaderboard: DeathmatchLeaderboard, score_limit: int) -> void:
	_map = map
	_leaderboard = leaderboard
	_score_limit = score_limit

func _process(delta: float) -> void:
	if not NetUtil.has_active_peer(multiplayer):
		return
	if not multiplayer.is_server():
		_ping_probe_elapsed += delta
		if _ping_probe_elapsed >= PING_PROBE_INTERVAL:
			_ping_probe_elapsed = 0.0
			_request_ping_echo.rpc_id(1, Time.get_ticks_msec())
		return
	if not active:
		return
	_stats_refresh_elapsed += delta
	if _stats_refresh_elapsed < STATS_REFRESH_INTERVAL:
		return
	_stats_refresh_elapsed = 0.0
	if refresh_all_combat_data():
		broadcast_stats()

# --- server API -------------------------------------------------------------

## Server only: start tracking a freshly set-up player (called on every spawn).
func track_player(peer_id: int, player: PlayerController) -> void:
	if not player_stats.has(peer_id):
		player_stats[peer_id] = _new_player_stats(peer_id)
	_refresh_combat_data(peer_id, player)
	broadcast_stats()
	player.health_component.die_detailed.connect(func(killer_id: int, is_headshot: bool): register_death(peer_id, killer_id, is_headshot))

func remove_peer(peer_id: int) -> void:
	player_stats.erase(peer_id)
	broadcast_stats()

func broadcast_stats(stats: Dictionary = player_stats) -> void:
	_update_stats.rpc(stats)

func send_stats_to(peer_id: int) -> void:
	_update_stats.rpc_id(peer_id, player_stats)

func register_death(victim_id: int, killer_id: int, is_headshot: bool = false) -> void:
	if not multiplayer.is_server() or not active:
		return

	var killer_name := player_identifier(killer_id) if killer_id > 0 else "Unknown"
	var victim_name := player_identifier(victim_id)

	if player_stats.has(victim_id):
		player_stats[victim_id]["deaths"] += 1
	if player_stats.has(killer_id) and killer_id != victim_id:
		player_stats[killer_id]["kills"] += 1
		_notify_local_kill_feedback.rpc_id(killer_id, is_headshot)
		if int(player_stats[killer_id].get("kills", 0)) >= _score_limit:
			score_limit_reached.emit(killer_id)

	_notify_kill_feed.rpc(killer_name, victim_name)
	_refresh_combat_data(victim_id)
	_refresh_combat_data(killer_id)

	print("K/D updated:")
	print("Player %d -> Kills: %d, Deaths: %d" % [
		killer_id,
		player_stats.get(killer_id, {}).get("kills", 0),
		player_stats.get(killer_id, {}).get("deaths", 0)
	])

	broadcast_stats()

## Server only: re-read every player's loadout; true if anything changed.
func refresh_all_combat_data() -> bool:
	var has_any_change := false
	for peer_id in player_stats.keys():
		if _refresh_combat_data(int(peer_id)):
			has_any_change = true
	return has_any_change

func final_stats() -> Dictionary:
	return player_stats.duplicate(true)

## Most kills wins; -1 on a tie (time limit).
func resolve_top_scorer() -> int:
	var best_peer_id := -1
	var best_kills := -1
	var has_tie := false
	for peer_id_variant in player_stats.keys():
		var peer_id := int(peer_id_variant)
		var stats: Dictionary = player_stats.get(peer_id, {})
		var kills := int(stats.get("kills", 0))
		if kills > best_kills:
			best_kills = kills
			best_peer_id = peer_id
			has_tie = false
		elif kills == best_kills:
			has_tie = true
	if has_tie:
		return -1
	return best_peer_id

func winner_name(winner_id: int) -> String:
	if winner_id <= 0:
		return "No one"
	if player_stats.has(winner_id):
		var identifier := String(player_stats[winner_id].get("player_identifier", "")).strip_edges()
		if identifier != "":
			return identifier
	return player_identifier(winner_id)

func player_identifier(peer_id: int) -> String:
	var player_name := MultiplayerSession.get_player_name(peer_id).strip_edges()
	if player_name != "":
		return player_name
	return str(peer_id)

# --- display (all peers) ----------------------------------------------------

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _update_stats(stats: Dictionary):
	if is_instance_valid(_leaderboard):
		_leaderboard.populate_leaderboard(stats)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _notify_local_kill_feedback(is_headshot: bool = false) -> void:
	var hud := _local_player_hud()
	if hud:
		hud.show_kill_feedback(is_headshot)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _notify_kill_feed(killer_name: String, victim_name: String) -> void:
	var hud := _local_player_hud()
	if hud:
		hud.show_kill_feed_toast(killer_name, victim_name)

func _local_player_hud() -> PlayerHud:
	if not NetUtil.has_active_peer(multiplayer) or not is_instance_valid(_map):
		return null
	var local_player := _map.get_node_or_null(str(multiplayer.get_unique_id())) as PlayerController
	if local_player == null:
		return null
	return local_player.hud as PlayerHud

# --- ping -------------------------------------------------------------------

@rpc("any_peer", "call_remote", "unreliable", RPC_CHANNEL_UI)
func _request_ping_echo(client_send_msec: int) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	_receive_ping_echo.rpc_id(peer_id, client_send_msec)

@rpc("authority", "call_local", "unreliable", RPC_CHANNEL_UI)
func _receive_ping_echo(client_send_msec: int) -> void:
	if multiplayer.is_server() or client_send_msec <= 0:
		return
	var rtt_ms := maxi(0, int(Time.get_ticks_msec() - client_send_msec))
	_report_client_ping.rpc_id(1, rtt_ms)

@rpc("any_peer", "call_remote", "unreliable", RPC_CHANNEL_UI)
func _report_client_ping(rtt_ms: int) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	if not player_stats.has(peer_id):
		player_stats[peer_id] = _new_player_stats(peer_id)
	var stats: Dictionary = player_stats[peer_id]
	var sanitized_rtt := maxi(0, mini(rtt_ms, 9999))
	if int(stats.get("ping_ms", -1)) == sanitized_rtt:
		return
	stats["ping_ms"] = sanitized_rtt
	player_stats[peer_id] = stats
	broadcast_stats()

# --- helpers ----------------------------------------------------------------

func _new_player_stats(peer_id: int) -> Dictionary:
	return {
		"player_identifier": player_identifier(peer_id),
		"kills": 0,
		"deaths": 0,
		"ping_ms": 0,
		"loadout": {},
		"current_weapon": {}
	}

func _slot_name(slot: int) -> String:
	match slot:
		EquipmentManager.EquipmentSlot.PRIMARY:
			return "primary"
		EquipmentManager.EquipmentSlot.SECONDARY:
			return "secondary"
		EquipmentManager.EquipmentSlot.MELEE:
			return "melee"
		EquipmentManager.EquipmentSlot.UTILITY_1:
			return "utility_q"
		EquipmentManager.EquipmentSlot.UTILITY_2:
			return "utility_e"
		EquipmentManager.EquipmentSlot.UTILITY_3:
			return "utility_x"
		_:
			return "unknown"

func _weapon_payload(equipment: EquipmentInstance) -> Dictionary:
	if equipment == null or equipment.equipment_data == null:
		return {}
	if equipment is WeaponInstance:
		var weapon := equipment as WeaponInstance
		return {
			"name": weapon.data.name,
			"slot": _slot_name(weapon.data.slot),
			"ammo_in_mag": weapon.ammo_in_mag,
			"ammo_reserve": weapon.ammo_reserve,
			"mag_size": weapon.data.mag_size,
			"uses_ammo": weapon.data.uses_ammo
		}
	# Generic equipment (non-weapon)
	return {"name": equipment.equipment_data.name}

func _refresh_combat_data(peer_id: int, player: PlayerController = null) -> bool:
	if not multiplayer.is_server():
		return false
	if not player_stats.has(peer_id):
		player_stats[peer_id] = _new_player_stats(peer_id)
	if player == null and is_instance_valid(_map):
		player = _map.get_node_or_null(str(peer_id)) as PlayerController

	var loadout_payload := {}
	var current_weapon_payload := {}
	if player and player.equipment_manager:
		var equipment_manager := player.equipment_manager
		current_weapon_payload = _weapon_payload(equipment_manager.get_current_item())
		if not current_weapon_payload.is_empty():
			current_weapon_payload["slot"] = _slot_name(int(equipment_manager.current_slot))
			loadout_payload = current_weapon_payload.duplicate(true)

	var stats: Dictionary = player_stats[peer_id]
	var has_changed := false
	var identifier := player_identifier(peer_id)
	if stats.get("player_identifier", "") != identifier:
		stats["player_identifier"] = identifier
		has_changed = true
	if stats.get("loadout", {}) != loadout_payload:
		stats["loadout"] = loadout_payload
		has_changed = true
	if stats.get("current_weapon", {}) != current_weapon_payload:
		stats["current_weapon"] = current_weapon_payload
		has_changed = true
	player_stats[peer_id] = stats
	return has_changed
