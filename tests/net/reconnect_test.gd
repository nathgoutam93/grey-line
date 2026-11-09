extends "res://tests/net/net_test_base.gd"

## Reconnect: the client drops out of a live round without confirming Leave,
## automatically reconnects under a new peer id and takes back its slot (name,
## team, stats), spectates until the next round, then plays it with working
## input. A confirmed Leave at the end forfeits the slot for good.

var _old_id := 0
var _bot_id := 0

func _mode() -> RoundGameMode:
	return game_mode() as RoundGameMode

func run_host_lobby() -> void:
	MultiplayerSession.set_team(1, Teams.ALPHA)
	MultiplayerSession.set_team(client_peer(), Teams.BRAVO)
	_bot_id = MultiplayerSession.add_bot()
	MultiplayerSession.set_team(_bot_id, Teams.BRAVO)
	get_tree().node_added.connect(_configure_mode)

func _configure_mode(node: Node) -> void:
	var mode := node as RoundGameMode
	if mode == null:
		return
	mode.freeze_seconds = 1.5
	mode.round_seconds = 60.0
	mode.round_end_seconds = 1.5
	mode.rounds_to_win = 4
	get_tree().node_added.disconnect(_configure_mode)

func _phase(next: RoundGameMode.Phase, timeout: float = 10.0) -> bool:
	if await wait_until(func(): return _mode().phase == next, timeout):
		return true
	finish_with_failure("phase", "expected %s, got %s" % [RoundGameMode.Phase.keys()[next], RoundGameMode.Phase.keys()[_mode().phase]])
	return false

# --- host -------------------------------------------------------------------

func run_host() -> void:
	var mode := _mode()
	var session := MultiplayerSession
	_old_id = client_peer()
	if not await _phase(RoundGameMode.Phase.LIVE):
		return
	# One finished round, so scores and roles have state worth restoring.
	mode._finish_round(Teams.BRAVO)
	if not await _phase(RoundGameMode.Phase.LIVE):
		return
	if not await wait_until(func(): return player(_old_id) != null and player(_bot_id) != null, 5.0):
		finish_with_failure("setup", "round 2 players missing")
		return
	mode.scoreboard.player_stats[_old_id]["kills"] = 2
	var name_before := session.get_player_name(_old_id)

	# The client reconnects at once, so record the held slot when the drop lands.
	var held := {}
	var on_drop := func(id: int):
		held.merge({"id": id, "dropped": session.is_dropped(id), "name": session.get_player_name(id), "team": session.get_team(id), "kills": int(mode.scoreboard.player_stats.get(id, {}).get("kills", -1))})
	session.player_dropped.connect(on_drop, CONNECT_ONE_SHOT)
	send("drop")
	if not await wait_until(func(): return not multiplayer.get_peers().has(_old_id), 10.0):
		finish_with_failure("drop", "client connection did not close")
		return
	await wait_until(func(): return not held.is_empty(), 2.0)
	var husk := player(_old_id)
	check("slot_held_on_drop", int(held.get("id", 0)) == _old_id and bool(held.get("dropped", false)) and held.get("name") == name_before and int(held.get("team", -1)) == Teams.BRAVO and int(held.get("kills", -1)) == 2, "held at drop: %s" % [held])
	var start := husk.global_position if husk != null else Vector2.INF
	await hold(0.5)
	var counts := mode._living_counts()
	check("dropped_body_stays_frozen_and_alive", husk != null and is_instance_valid(husk) and not husk.is_dead and husk.net_sync.owner_dropped and husk.global_position.distance_to(start) < 0.5 and counts.x + counts.y == 3 and mode.phase == RoundGameMode.Phase.LIVE, "body frozen at %s, living %s, phase %s" % [start, counts, RoundGameMode.Phase.keys()[mode.phase]])

	if not await wait_until(func(): return client_peer() > 0 and session.player_names.has(client_peer()), 20.0):
		finish_with_failure("rejoin", "client did not rejoin its slot")
		return
	var new_id := client_peer()
	var stats: Dictionary = mode.scoreboard.player_stats.get(new_id, {})
	check("rejoin_restores_slot", new_id != _old_id and session.current_id(_old_id) == new_id and not session.is_dropped(_old_id) and not session.player_names.has(_old_id) and session.get_player_name(new_id) == name_before and session.get_team(new_id) == Teams.BRAVO and int(stats.get("kills", -1)) == 2 and not mode.scoreboard.player_stats.has(_old_id), "peer %d -> %d keeps name, team and kills" % [_old_id, new_id])
	check("rejoin_mid_round_waits_for_next_round", player(new_id) == null and player(_old_id) != null and player(_old_id).net_sync.owner_dropped, "no new body mid-round; the dropped body remains until it dies or the round ends")

	var report: Variant = await wait_for("rejoined", 15.0)
	check("rejoined_client_receives_round_state", report is Dictionary and int(report.get("id", 0)) == new_id and int(report.get("team", 0)) == Teams.BRAVO and int(report.get("phase", -1)) == RoundGameMode.Phase.LIVE and int(report.get("round", -1)) == 1 and int(report.get("bravo", -1)) == 1 and int(report.get("kills", -1)) == 2 and bool(report.get("lobby_hidden", false)), "client report %s" % [report])
	check("rejoined_client_spectates_teammate", report is Dictionary and int(report.get("spectate", 0)) == _bot_id and not bool(report.get("own_player", true)), "spectating the living teammate, no own body")

	# The dropped body is still killable; its death counts for the rejoined slot.
	var deaths_before := int(mode.scoreboard.player_stats[new_id].get("deaths", 0))
	player(_old_id).health_component.take_damage(500, 1)
	await hold(0.2)
	check("dropped_body_death_counts_for_slot", int(mode.scoreboard.player_stats[new_id].get("deaths", 0)) == deaths_before + 1 and mode.phase == RoundGameMode.Phase.LIVE, "death credited to the rejoined player; the teammate keeps the round alive")
	player(_bot_id).health_component.take_damage(500, 1)
	if not await _phase(RoundGameMode.Phase.ROUND_END):
		return
	if not await _phase(RoundGameMode.Phase.LIVE):
		return
	if not await wait_until(func(): return player(new_id) != null, 5.0):
		finish_with_failure("next_round", "rejoined player did not spawn in the next round")
		return
	var body := player(new_id)
	check("rejoined_player_plays_next_round", body.team == Teams.BRAVO and not body.net_sync.owner_dropped and player(_old_id) == null, "fresh body on team %d" % body.team)
	var origin := body.global_position
	send("move")
	var moved: Variant = await wait_for("moved", 6.0)
	check("rejoined_input_accepted", moved is Dictionary and bool(moved.get("local", false)) and body.global_position.distance_to(origin) > 10.0, "server moved %.1f px" % body.global_position.distance_to(origin))

	send("leave")
	if not await wait_until(func(): return not multiplayer.get_peers().has(new_id), 6.0):
		finish_with_failure("leave", "client did not disconnect after Leave")
		return
	await hold(0.3)
	check("leave_forfeits_slot", not session.player_names.has(new_id) and not session.is_dropped(new_id) and not mode.scoreboard.player_stats.has(new_id) and player(new_id) == null, "slot, stats and body released")

# --- client -----------------------------------------------------------------

func on_message(key: String, _value: Variant) -> void:
	if role != "client":
		return
	match key:
		"drop": _drop_and_rejoin()
		"move": _move()
		"leave": _leave()

func _drop_and_rejoin() -> void:
	var old_id := multiplayer.get_unique_id()
	check("ticket_before_drop", MultiplayerSession.has_rejoin_ticket(), "a running match holds a rejoin ticket")
	# Same as a lost connection: no forfeit, the socket just goes away.
	multiplayer.multiplayer_peer.close()
	multiplayer.server_disconnected.emit()
	if not await wait_until(func(): return MultiplayerSession.is_rejoining(), 3.0):
		results.fail("auto_rejoin_starts", "drop did not start reconnecting")
		return
	if not await wait_until(func(): return not MultiplayerSession.is_rejoining() and MultiplayerSession.match_started and NetUtil.has_active_peer(multiplayer), 20.0):
		results.fail("auto_rejoin_accepted", "reconnect was not accepted")
		return
	check("rejoin_uses_new_peer_id", multiplayer.get_unique_id() != old_id, "new ENet id %d" % multiplayer.get_unique_id())
	await wait_until(func(): return _mode() != null and _mode().round_index == 1 and _mode().local_spectate_target != 0, 8.0)
	var mode := _mode()
	var own := multiplayer.get_unique_id()
	var lobby_ui := get_tree().current_scene.get_node_or_null("UI") as CanvasLayer
	await wait_until(func(): return mode != null and int(mode.scoreboard.player_stats.get(own, {}).get("kills", -1)) == 2, 3.0)
	send("rejoined", {
		"id": own,
		"team": MultiplayerSession.get_team(own),
		"phase": mode.phase if mode != null else -1,
		"round": mode.round_index if mode != null else -1,
		"bravo": int(mode.team_scores.get(Teams.BRAVO, -1)) if mode != null else -1,
		"spectate": mode.local_spectate_target if mode != null else 0,
		"own_player": local_player() != null,
		"kills": int(mode.scoreboard.player_stats.get(own, {}).get("kills", -1)) if mode != null else -1,
		"lobby_hidden": lobby_ui != null and not lobby_ui.visible,
	})

func _move() -> void:
	await wait_until(func(): return local_player() != null and _mode().phase == RoundGameMode.Phase.LIVE, 5.0)
	var has_local := local_player() != null
	for action in ["move_up", "move_down", "move_left"]:
		Input.action_press(action)
		await hold(0.3)
		Input.action_release(action)
	send("moved", {"local": has_local})

func _leave() -> void:
	await MultiplayerSession.leave_match()
	await hold(2.0)
	check("leave_does_not_rejoin", not MultiplayerSession.is_rejoining() and not MultiplayerSession.has_rejoin_ticket() and not NetUtil.has_active_peer(multiplayer), "no ticket and no reconnect after a confirmed Leave")
	_quit()
