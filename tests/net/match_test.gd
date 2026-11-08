extends "res://tests/net/net_test_base.gd"

## Match flow: the host kills the client's player until the map's score limit
## (3 on map_1). Checks: kills/deaths are counted after every kill, the client
## respawns with a working NetSync each time, the score limit ends the match
## and the client shows its result.

const KILLS := 3

var _lives := 0
var _was_alive := false
var _end_seen := false

func run_client() -> void:
	send("watching")
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var me := local_player()
		var alive := me != null and me.net_sync != null
		if alive and not _was_alive:
			_lives += 1
		_was_alive = alive
		var gm := game_mode()
		if gm != null and gm.post_match_transition_started:
			_end_seen = true
			send("report", {"lives": _lives, "result": gm.match_result_label.text})
			return
	send("report", {"lives": _lives, "result": ""})

func run_host() -> void:
	var gm := game_mode()
	var victim_id := client_peer()
	if await wait_for("watching", 10.0) == null:
		results.fail("client_report", "client never started watching")
		return
	for i in range(KILLS):
		if not await wait_until(func(): return player(victim_id) != null, 12.0):
			results.fail("client_respawns", "client player missing before kill %d" % (i + 1))
			return
		await hold(1.0) # let the client see (and count) the new life first
		player(victim_id).health_component.take_damage(500, 1, i == 1)
		await hold(0.3)
		var stats: Dictionary = gm.scoreboard.player_stats
		var kills := int(stats.get(1, {}).get("kills", -1))
		var deaths := int(stats.get(victim_id, {}).get("deaths", -1))
		check("kill_%d_counted" % (i + 1), kills == i + 1 and deaths == i + 1, "host %d kills, client %d deaths" % [kills, deaths])
	check("score_limit_ends_match", gm.match_ended and gm.winning_peer_id == 1, "match_ended=%s winner=%d" % [gm.match_ended, gm.winning_peer_id])
	var report: Variant = await wait_for("report", 10.0)
	if report == null:
		results.fail("client_report", "no report from the client")
		return
	check("client_respawned_each_time", int(report["lives"]) == KILLS, "client had %d lives (expected %d)" % [int(report["lives"]), KILLS])
	check("client_shows_result", String(report["result"]) == "DEFEAT", "result label '%s'" % report["result"])
