extends "res://tests/net/net_test_base.gd"

## Reconnect in team deathmatch: a dropped player's body leaves (no free
## kills) while name, team and stats are held; on rejoin they respawn at once
## with the same slot and working input.

func _mode() -> DeathmatchGameMode:
	return game_mode() as DeathmatchGameMode

func run_host() -> void:
	var mode := _mode()
	var session := MultiplayerSession
	var old_id := client_peer()
	var team := session.get_team(old_id)
	var name_before := session.get_player_name(old_id)
	mode.scoreboard.player_stats[old_id]["kills"] = 3
	var held := {}
	session.player_dropped.connect(func(id: int):
		held.merge({"id": id, "team": session.get_team(id), "kills": int(mode.scoreboard.player_stats.get(id, {}).get("kills", -1))}), CONNECT_ONE_SHOT)
	send("drop")
	if not await wait_until(func(): return not held.is_empty(), 10.0):
		finish_with_failure("drop", "drop was not registered")
		return
	await get_tree().process_frame
	check("dm_slot_held_body_removed", int(held.get("id", 0)) == old_id and int(held.get("team", -1)) == team and int(held.get("kills", -1)) == 3 and player(old_id) == null, "held %s" % [held])
	if not await wait_until(func(): return client_peer() > 0 and session.player_names.has(client_peer()) and player(client_peer()) != null, 20.0):
		finish_with_failure("rejoin", "client did not rejoin and respawn")
		return
	var new_id := client_peer()
	check("dm_rejoin_respawns_with_slot", new_id != old_id and session.get_team(new_id) == team and session.get_player_name(new_id) == name_before and int(mode.scoreboard.player_stats.get(new_id, {}).get("kills", -1)) == 3 and player(new_id).team == team, "peer %d -> %d" % [old_id, new_id])
	var body := player(new_id)
	var origin := body.global_position
	send("move")
	var moved: Variant = await wait_for("moved", 8.0)
	check("dm_rejoined_input_accepted", moved is Dictionary and bool(moved.get("local", false)) and is_instance_valid(body) and body.global_position.distance_to(origin) > 10.0, "server moved %.1f px" % (body.global_position.distance_to(origin) if is_instance_valid(body) else -1.0))

func on_message(key: String, _value: Variant) -> void:
	if role != "client":
		return
	if key == "drop":
		multiplayer.multiplayer_peer.close()
		multiplayer.server_disconnected.emit()
	elif key == "move":
		await wait_until(func(): return local_player() != null, 8.0)
		var has_local := local_player() != null
		await hold(0.5)
		for action in ["move_up", "move_down", "move_left"]:
			Input.action_press(action)
			await hold(0.3)
			Input.action_release(action)
		send("moved", {"local": has_local})
