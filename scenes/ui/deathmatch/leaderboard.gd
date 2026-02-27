extends Panel
class_name DeathmatchLeaderboard

@export var player_score_scene: PackedScene

@onready var rows_container: VBoxContainer = $VBoxContainer

func populate_leaderboard(stats_payload: Dictionary) -> void:
	for child in rows_container.get_children():
		child.queue_free()

	var peer_ids := stats_payload.keys()
	peer_ids.sort()

	for peer_id in peer_ids:
		var row := player_score_scene.instantiate()
		rows_container.add_child(row)

		var player_stat: Dictionary = stats_payload.get(peer_id, {})
		var kills: int = int(player_stat.get("kills", 0))
		var deaths: int = int(player_stat.get("deaths", 0))
		var current_weapon_name := _weapon_name(player_stat.get("current_weapon", {}))
		var loadout_weapon_name := _weapon_name(player_stat.get("loadout", {}))

		var name_label: Label = row.get_node("Panel/name")
		var kda_label: Label = row.get_node("Panel3/kda")
		var loadout_label: Label = row.get_node("Panel2/loadout")
		var ping_label: Label = row.get_node("Panel4/ping")

		var player_identifier := String(player_stat.get("player_identifier", str(peer_id)))
		if player_identifier.strip_edges() == "":
			player_identifier = str(peer_id)
		name_label.text = player_identifier
		kda_label.text = "%d / %d" % [kills, deaths]
		loadout_label.text = "%s" % [current_weapon_name]
		ping_label.text = "%d ms" % int(player_stat.get("ping_ms", 0))

func _weapon_name(weapon_payload: Variant) -> String:
	if weapon_payload is Dictionary:
		var weapon_dict := weapon_payload as Dictionary
		if weapon_dict.has("name") and String(weapon_dict["name"]) != "":
			return String(weapon_dict["name"])
	return "-"
