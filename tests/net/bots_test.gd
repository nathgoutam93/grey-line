extends "res://tests/net/net_test_base.gd"

## Puppets use real player spawning, simulation, snapshots and match scoring.
## The host scripts a bot; the client reports its replicated proxy state.

func run_client() -> void:
	pass # Samples are answered in on_message, including after respawning.

func on_message(key: String, value: Variant) -> void:
	if role != "client" or not key.begins_with("sample:"):
		return
	var puppet := player(int(value))
	var reply := {"exists": puppet != null}
	if puppet != null:
		reply = {
			"exists": true,
			"name": String(puppet.name),
			"owner": puppet.owner_peer_id,
			"authority": puppet.get_multiplayer_authority(),
			"local": puppet.is_local_player or puppet.net_sync.is_owner_role(),
			"brain": puppet.net_sync.bot_brain != null,
			"position": puppet.global_position,
			"presence": puppet.net_sync._net_presence,
			"drawn": puppet.visible,
			"health": puppet.health_component.current_health,
			"label": MultiplayerSession.get_player_name(int(value)),
		}
	send("result:" + key.trim_prefix("sample:"), reply)

func _sample(scenario: String, bot_id: int) -> Dictionary:
	send("sample:" + scenario, bot_id)
	var reply: Variant = await wait_for("result:" + scenario, 5.0)
	return reply if reply is Dictionary else {}

func run_host() -> void:
	var bot_id := await add_bot()
	if bot_id == 0:
		return
	var puppet := player(bot_id)
	var brain := bot(bot_id)
	check("bot_has_server_identity", bot_id == -1 and puppet.owner_peer_id == bot_id
		and puppet.get_multiplayer_authority() == 1 and not puppet.net_sync.is_owner_role()
		and not puppet.player_input.is_processing() and MultiplayerSession.is_peer_connected(bot_id),
		"id=%d, authority=%d" % [bot_id, puppet.get_multiplayer_authority()])

	var viewer := player(client_peer())
	var facing := Vector2.RIGHT.rotated(viewer.rotation)
	var open := find_open_spot(facing, 1000.0)
	if open == Vector2.INF:
		results.fail("setup", "no open spot on the map")
		return
	viewer.global_position = open
	player(1).global_position = open + Vector2(0, 2000)
	await hold(1.0) # allow the owning client to reconcile its new position/aim
	facing = Vector2.RIGHT.rotated(viewer.rotation)
	puppet.global_position = open + facing * 300.0
	brain.aim_dir = facing
	await hold(0.5)
	var before := await _sample("spawn", bot_id)
	check("bot_spawns_on_client", before.get("name", "") == "-1"
		and int(before.get("owner", 0)) == bot_id and int(before.get("authority", 0)) == 1
		and not bool(before.get("local", true)) and not bool(before.get("brain", true))
		and before.get("label", "") == "Bot 1", "client proxy: %s" % before)

	var start := puppet.global_position
	var start_tick := NetworkTick.tick
	brain.move = Vector2(0, -1)
	var walked := await wait_until(func(): return NetworkTick.tick >= start_tick + NetworkTick.tick_rate, 3.0)
	brain.stop()
	var expected_distance := puppet.get_speed() * (NetworkTick.tick - start_tick) * NetworkTick.get_tick_delta()
	var expected_position := start + facing * expected_distance
	await hold(0.3) # let the final snapshots reach the interpolated proxy
	var moved := await _sample("moved", bot_id)
	var client_position: Vector2 = moved.get("position", Vector2.INF)
	var error := client_position.distance_to(puppet.global_position)
	check("bot_moves_like_a_player", walked and not moved.is_empty()
		and int(moved.get("presence", -1)) == PlayerNetSync.NetPresence.VISIBLE
		and bool(moved.get("drawn", false)) and error <= 40.0
		and puppet.global_position.distance_to(expected_position) < 2.0
		and client_position.distance_to(start) > 100.0,
		"moved %.1f px (expected %.1f), client error %.2f px" % [start.distance_to(puppet.global_position), expected_distance, error])

	var life_id := puppet.get_instance_id()
	puppet.health_component.take_damage(500, 1)
	var scoreboard := game_mode().get_node("Scoreboard") as MatchScoreboard
	var counted := int(scoreboard.player_stats.get(1, {}).get("kills", 0)) == 1 \
		and int(scoreboard.player_stats.get(bot_id, {}).get("deaths", 0)) == 1
	var respawned := await wait_until(func(): return player(bot_id) != null and player(bot_id).get_instance_id() != life_id, 8.0)
	var after := await _sample("respawn", bot_id)
	check("bot_takes_damage_and_respawns", counted and respawned and bot(bot_id) != null
		and bot(bot_id) != brain and int(after.get("health", 0)) == 100,
		"scored=%s, respawned=%s, client health=%d" % [counted, respawned, int(after.get("health", 0))])

	# Negative killer ids still score normally, without sending HUD feedback
	# to a nonexistent ENet peer.
	player(1).health_component.take_damage(500, bot_id)
	check("bot_kill_is_scored", int(scoreboard.player_stats.get(bot_id, {}).get("kills", 0)) == 1
		and int(scoreboard.player_stats.get(1, {}).get("deaths", 0)) == 1, "bot kill and host death counted")

	MultiplayerSession.remove_bot(bot_id)
	await hold(0.5)
	var removed := await _sample("removed", bot_id)
	check("bot_removal_replicates_without_respawn", player(bot_id) == null and not bool(removed.get("exists", true))
		and not MultiplayerSession.is_peer_connected(bot_id) and not MultiplayerSession.player_names.has(bot_id)
		and not scoreboard.player_stats.has(bot_id), "removed from server, client, lobby and scoreboard")
