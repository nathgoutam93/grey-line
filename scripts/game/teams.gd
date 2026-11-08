extends RefCounted
class_name Teams

const NONE := -1
const ALPHA := 0
const BRAVO := 1
const COLORS := {ALPHA: Color("#e8a33d"), BRAVO: Color("#3d8de8")}
const NAMES := {ALPHA: "Alpha", BRAVO: "Bravo"}

static func display_name(team: int) -> String:
	return NAMES.get(team, "None")

static func other(team: int) -> int:
	if team == ALPHA:
		return BRAVO
	return ALPHA if team == BRAVO else NONE

static func is_teammate(a: PlayerController, b: PlayerController) -> bool:
	return a != null and b != null and a.team != NONE and a.team == b.team

static func can_damage(attacker_team: int, victim_team: int, attacker_id: int, victim_id: int, friendly_fire: bool) -> bool:
	return attacker_id == victim_id or attacker_team == NONE or victim_team == NONE \
		or attacker_team != victim_team or friendly_fire

static func pick_team_for_new_player(teams: Dictionary) -> int:
	return ALPHA if teams.values().count(ALPHA) <= teams.values().count(BRAVO) else BRAVO

static func can_switch(teams: Dictionary, peer_id: int, wanted: int, max_per_team: int) -> bool:
	if wanted not in [ALPHA, BRAVO] or not teams.has(peer_id):
		return false
	var proposed := teams.duplicate()
	proposed[peer_id] = wanted
	var alpha := proposed.values().count(ALPHA)
	var bravo := proposed.values().count(BRAVO)
	return alpha <= max_per_team and bravo <= max_per_team and absi(alpha - bravo) <= 1
