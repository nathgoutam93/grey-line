extends "res://tests/net/net_test_base.gd"

var _bot_id := 0

func run_host_lobby() -> void:
	var client_id := client_peer()
	check("lobby_auto_balances", MultiplayerSession.get_team(1) == Teams.ALPHA
		and MultiplayerSession.get_team(client_id) == Teams.BRAVO, "host Alpha, client Bravo")
	send("unbalanced_request")
	await wait_for("unbalanced_sent", 5.0)
	await hold(0.3)
	check("unbalanced_request_rejected", MultiplayerSession.get_team(client_id) == Teams.BRAVO, "server rejected a 2–0 split")
	_bot_id = MultiplayerSession.add_bot()
	check("bot_auto_balances", MultiplayerSession.get_team(_bot_id) == Teams.ALPHA, "bot joined the smaller team")
	var extra_a := MultiplayerSession.add_bot()
	var extra_b := MultiplayerSession.add_bot()
	check("five_players_balance_three_two", MultiplayerSession.player_names.size() == 5
		and MultiplayerSession.player_teams.values().count(Teams.ALPHA) == 3
		and MultiplayerSession.player_teams.values().count(Teams.BRAVO) == 2, "five players assigned 3 Alpha / 2 Bravo")
	send("five_player_rosters")
	var rosters: Variant = await wait_for("five_player_rosters", 5.0)
	check("five_player_rosters_replicate", rosters is Vector2i and rosters == Vector2i(3, 2), "client roster counts: %s" % [rosters])
	MultiplayerSession.remove_bot(extra_b)
	MultiplayerSession.remove_bot(extra_a)
	var button := get_tree().current_scene.find_child("SwitchTeam", true, false) as Button
	check("host_switch_button_available", button != null and button.visible and not button.disabled, "host can switch with three players")
	if button != null:
		button.pressed.emit()
	check("host_switches_in_lobby", MultiplayerSession.get_team(1) == Teams.BRAVO, "host switched to Bravo")
	send("client_switch")
	var switched := await wait_until(func(): return MultiplayerSession.get_team(client_id) == Teams.ALPHA, 5.0)
	check("client_switches_in_lobby", switched, "client's balanced request accepted")
	var labels: Variant = await wait_for("lobby_labels", 5.0)
	check("lobby_labels_show_teams", labels == true, "client slots show team prefixes and colours")
	var start := get_tree().current_scene.find_child("start_match", true, false) as Button
	if start != null:
		start.pressed.emit()
	check("host_start_button_starts_match", start != null and MultiplayerSession.match_started, "host can start from the redesigned lobby")

func run_client() -> void:
	pass

func on_message(key: String, value: Variant) -> void:
	if role != "client":
		return
	if key == "unbalanced_request":
		MultiplayerSession.request_team.rpc_id(1, Teams.ALPHA)
		send("unbalanced_sent")
	elif key == "client_switch":
		var button := get_tree().current_scene.find_child("SwitchTeam", true, false) as Button
		await wait_until(func(): return button != null and not button.disabled, 5.0)
		if button != null and not button.disabled:
			button.pressed.emit()
		var labelled := false
		for node in get_tree().current_scene.find_children("player_slot_*", "Label", true, false):
			var label := node as Label
			if label.text.begins_with("[A] ") or label.text.begins_with("[B] "):
				labelled = label.get_theme_color("font_color") in Teams.COLORS.values()
		send("lobby_labels", labelled)
	elif key == "five_player_rosters":
		await wait_until(func(): return MultiplayerSession.player_names.size() == 5, 5.0)
		var alpha := get_tree().current_scene.find_child("AlphaRoster", true, false)
		var bravo := get_tree().current_scene.find_child("BravoRoster", true, false)
		send("five_player_rosters", Vector2i(alpha.find_children("player_slot_*", "Label", true, false).size(), bravo.find_children("player_slot_*", "Label", true, false).size()))
	elif key == "match_switch":
		MultiplayerSession.request_team.rpc_id(1, int(value))
		send("match_switch_sent")
	elif key.begins_with("sample:"):
		var target := player(int(value))
		var sample := {}
		if target != null:
			sample = {
				"team": target.team,
				"presence": target.net_sync._net_presence,
				"drawn": target.visible,
				"unmasked": target.skeletal_character.material == null,
				"tint": target.skeletal_character.modulate,
				"scores": (game_mode().get_node("Scoreboard") as MatchScoreboard).team_scores.duplicate(),
				"result": (game_mode() as DeathmatchGameMode).match_result_label.text,
			}
		send("result:" + key.trim_prefix("sample:"), sample)

func _sample(scenario: String, peer_id: int) -> Dictionary:
	send("sample:" + scenario, peer_id)
	var sample: Variant = await wait_for("result:" + scenario, 5.0)
	return sample if sample is Dictionary else {}

func run_host() -> void:
	if not await wait_until(func(): return bot(_bot_id) != null, 8.0):
		results.fail("setup", "lobby bot did not spawn")
		return
	var client_id := client_peer()
	MultiplayerSession.set_team(1, Teams.ALPHA)
	MultiplayerSession.set_team(client_id, Teams.BRAVO)
	MultiplayerSession.set_team(_bot_id, Teams.BRAVO)
	var viewer := player(client_id)
	var puppet := player(_bot_id)
	var host := player(1)
	var brain := bot(_bot_id)
	var facing := Vector2.RIGHT.rotated(viewer.rotation)
	var wall := find_wall_setup(facing)
	if wall.is_empty():
		results.fail("setup", "no wall setup found")
		return
	viewer.global_position = wall[0]
	puppet.global_position = wall[1]
	await hold(1.0)
	var teammate := await _sample("wall", _bot_id)
	var tint: Color = Teams.COLORS[Teams.BRAVO]
	check("teammate_always_visible", not VisibilityQuery.can_see(viewer, puppet, [])
		and int(teammate.get("presence", -1)) == PlayerNetSync.NetPresence.VISIBLE
		and bool(teammate.get("drawn", false)) and bool(teammate.get("unmasked", false))
		and teammate.get("tint", Color.WHITE) == tint.lerp(Color.WHITE, 0.6), "teammate is visible, tinted and unmasked through a wall")

	var open := find_open_spot(facing, 1000.0)
	if open == Vector2.INF:
		results.fail("setup", "no open spot found")
		return
	viewer.global_position = open
	await hold(0.5)
	facing = Vector2.RIGHT.rotated(viewer.rotation)
	host.global_position = open - facing * 600.0
	puppet.global_position = open - facing * 300.0
	brain.face_point(puppet.global_position, host.global_position)
	await hold(1.0)
	var enemy := await _sample("enemy", 1)
	check("enemy_still_needs_line_of_sight", int(enemy.get("presence", -1)) == PlayerNetSync.NetPresence.CULLED
		and not bool(enemy.get("drawn", true)) and not bool(enemy.get("unmasked", true)), "silent enemy behind the viewer stays culled and masked")
	check("teammate_sight_does_not_reveal_enemy", VisibilityQuery.can_see(puppet, host, [])
		and not VisibilityQuery.can_see(viewer, host, [])
		and int(enemy.get("presence", -1)) == PlayerNetSync.NetPresence.CULLED, "bot sees the enemy; its teammate still cannot")

	send("match_switch", Teams.ALPHA)
	await wait_for("match_switch_sent", 5.0)
	await hold(0.2)
	check("match_team_request_rejected", MultiplayerSession.get_team(client_id) == Teams.BRAVO, "client cannot switch once the match starts")

	puppet.global_position = open + facing * 220.0
	brain.face_point(puppet.global_position, viewer.global_position)
	var rifle := puppet.equipment_manager.get_item_in_slot(EquipmentManager.EquipmentSlot.PRIMARY) as WeaponInstance
	brain.slot_select = EquipmentManager.EquipmentSlot.PRIMARY
	if not await wait_until(func(): return rifle != null and puppet.get_current_equipment() == rifle and not rifle.is_locked, 3.0):
		results.fail("setup", "bot did not equip its rifle")
		return
	var weapon := puppet.get_current_equipment() as WeaponInstance
	var ammo_before := weapon.ammo_in_mag
	var health_before := viewer.health_component.current_health
	brain.fire_held = true
	var start_tick := NetworkTick.tick
	await wait_until(func(): return NetworkTick.tick >= start_tick + NetworkTick.tick_rate, 3.0)
	brain.stop()
	await hold(0.2)
	check("no_friendly_fire", viewer.health_component.current_health == health_before
		and weapon.ammo_in_mag < ammo_before, "bot fired for one second; teammate health stayed at %d" % health_before)

	MultiplayerSession.set_team(_bot_id, Teams.ALPHA)
	await hold(0.3)
	var switched := await _sample("enemy_mask", _bot_id)
	check("team_change_restores_enemy_mask", int(switched.get("team", Teams.NONE)) == Teams.ALPHA
		and not bool(switched.get("unmasked", true)), "former teammate now uses the enemy fog mask")
	brain.fire_held = true
	var hurt := await wait_until(func(): return viewer.health_component.current_health < health_before, 2.0)
	brain.stop()
	check("enemy_fire_hurts", hurt, "client health fell from %d to %d" % [health_before, viewer.health_component.current_health])

	MultiplayerSession.set_team(_bot_id, Teams.BRAVO)
	var mode := game_mode() as DeathmatchGameMode
	mode.friendly_fire = true
	await hold(0.2)
	var friendly_health := viewer.health_component.current_health
	brain.fire_held = true
	var friendly_hurt := await wait_until(func(): return viewer.health_component.current_health < friendly_health, 2.0)
	brain.stop()
	mode.friendly_fire = false
	check("friendly_fire_toggle_allows_damage", friendly_hurt, "enabling friendly fire lets the teammate's rifle hurt")

	puppet.health_component.take_damage(500, 1)
	var scoreboard := game_mode().get_node("Scoreboard") as MatchScoreboard
	check("team_score_counts_enemy_kills", int(scoreboard.team_scores[Teams.ALPHA]) == 1, "Alpha team score is 1")
	await hold(0.3)
	var scored := await _sample("score", 1)
	var scores: Dictionary = scored.get("scores", {})
	check("team_scores_replicate", int(scores.get(Teams.ALPHA, -1)) == 1, "client received the team score")

	var second_bot := await add_bot()
	if second_bot == 0 or not await wait_until(func(): return player(_bot_id) != null, 8.0):
		results.fail("setup", "bots unavailable for combined team scoring")
		return
	MultiplayerSession.set_team(second_bot, Teams.ALPHA)
	player(_bot_id).health_component.take_damage(500, second_bot)
	check("teammate_kills_add_to_team_score", int(scoreboard.team_scores[Teams.ALPHA]) == 2
		and int(scoreboard.player_stats[1]["kills"]) == 1
		and int(scoreboard.player_stats[second_bot]["kills"]) == 1 and not mode.match_ended,
		"two different Alpha players contribute to the team total")
	viewer.health_component.take_damage(500, 1)
	await hold(0.3)
	var ended := await _sample("team_result", 1)
	check("combined_team_score_ends_match", mode.match_ended and mode.winning_team == Teams.ALPHA
		and mode.match_result_label.text == "VICTORY" and ended.get("result", "") == "DEFEAT",
		"combined score reaches 3; Alpha wins and Bravo loses")
