extends Control
class_name LobbyView

const BACKGROUND := Color("#080e15")
const PANEL := Color("#101b26")
const TEXT := Color("#edf2f5")
const MUTED := Color("#899ba9")
const ACCENT := Color("#65df9a")
const MAP_PREVIEW := preload("res://scenes/maps/map_1/_assets/map_f.png")
const CQC_PREVIEW := preload("res://scenes/maps/cqc_1/preview.png")
const DEFAULT_AVATAR_PATH := "res://assets/sprites/character/head.png"

signal start_requested
signal switch_team_requested
signal add_bot_requested
signal remove_bot_requested
signal map_cycle_requested

var _rosters: Dictionary = {}
var _counts: Dictionary = {}
var _team_tags: Dictionary = {}
var _avatar_cache: Dictionary = {}
var _avatar_catalog: Dictionary = {}
var _map_thumbnail: TextureRect
var _map_name: Label
var _connection: Label
var _balance: Label
var _status: Label
var _start: Button
var _switch: Button
var _host_tools: HBoxContainer
var _remove_bot: Button
var _content: GridContainer
var _mode_title: Label
var _mode_name: Label
var _map_cycle: Button

func _ready() -> void:
	_avatar_catalog = PlayerProfile.get_avatar_catalog()
	_build()
	resized.connect(_resize_layout)
	_resize_layout()

func _build() -> void:
	var background := ColorRect.new()
	background.color = BACKGROUND
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.name = "LobbyFrame"
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 24)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 16)
	margin.add_child(layout)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	layout.add_child(header)
	var title := VBoxContainer.new()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	title.add_child(_label("GREYLINE / MULTIPLAYER", 13, ACCENT))
	_mode_title = _label("TEAM DEATHMATCH", 28, TEXT)
	_mode_title.name = "ModeTitle"
	title.add_child(_mode_title)
	_connection = _label("MATCH LOBBY", 13, MUTED)
	title.add_child(_connection)
	var map_card := PanelContainer.new()
	map_card.add_theme_stylebox_override("panel", _style(PANEL, Color("#263747"), 12))
	header.add_child(map_card)
	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 14)
	map_card.add_child(map_row)
	var thumbnail := TextureRect.new()
	_map_thumbnail = thumbnail
	thumbnail.name = "MapPreview"
	thumbnail.texture = MAP_PREVIEW
	thumbnail.custom_minimum_size = Vector2(86, 64)
	thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	map_row.add_child(thumbnail)
	var map_text := VBoxContainer.new()
	map_text.custom_minimum_size.x = 108
	map_row.add_child(map_text)
	map_text.add_child(_label("SELECTED MAP", 11, MUTED))
	_map_name = _label("Map 1", 20, TEXT)
	map_text.add_child(_map_name)
	_mode_name = _label("Team deathmatch", 12, MUTED)
	_mode_name.name = "MapMode"
	map_text.add_child(_mode_name)
	_map_cycle = _button("Change map", "CycleMap")
	_map_cycle.pressed.connect(func(): map_cycle_requested.emit())
	map_text.add_child(_map_cycle)

	_content = GridContainer.new()
	_content.columns = 2
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("h_separation", 18)
	_content.add_theme_constant_override("v_separation", 14)
	layout.add_child(_content)
	_build_team(Teams.ALPHA)
	_build_team(Teams.BRAVO)

	var footer := VBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	layout.add_child(footer)
	var information := HBoxContainer.new()
	footer.add_child(information)
	_balance = _label("0 VS 0", 15, TEXT)
	_balance.name = "TeamBalance"
	_balance.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	information.add_child(_balance)
	_status = _label("Waiting for players", 13, MUTED)
	_status.name = "lobby_status"
	information.add_child(_status)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	footer.add_child(actions)
	_host_tools = HBoxContainer.new()
	_host_tools.add_theme_constant_override("separation", 8)
	actions.add_child(_host_tools)
	_host_tools.add_child(_label("HOST TOOLS", 11, MUTED))
	var add_bot := _button("Add bot", "AddBot")
	add_bot.pressed.connect(func(): add_bot_requested.emit())
	_host_tools.add_child(add_bot)
	_remove_bot = _button("Remove bot", "RemoveBot")
	_remove_bot.pressed.connect(func(): remove_bot_requested.emit())
	_host_tools.add_child(_remove_bot)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	_switch = _button("Switch team", "SwitchTeam")
	_switch.pressed.connect(func(): switch_team_requested.emit())
	actions.add_child(_switch)
	_start = _button("START MATCH", "start_match", true)
	_start.pressed.connect(func(): start_requested.emit())
	actions.add_child(_start)

func _build_team(team: int) -> void:
	var color: Color = Teams.COLORS[team]
	var panel := PanelContainer.new()
	panel.name = Teams.display_name(team) + "Panel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size.x = 240
	panel.size_flags_stretch_ratio = 1.0
	panel.add_theme_stylebox_override("panel", _style(PANEL, color.darkened(0.55), 16))
	_content.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var name_label := _label(Teams.display_name(team).to_upper(), 26, color)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)
	var count := _label("0 PLAYERS", 13, color)
	count.name = Teams.display_name(team) + "Count"
	header.add_child(count)
	_counts[team] = count
	var tag := _label("OPPOSING TEAM", 11, MUTED)
	column.add_child(tag)
	_team_tags[team] = tag
	var line := ColorRect.new()
	line.custom_minimum_size.y = 2
	line.color = color
	column.add_child(line)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var roster := VBoxContainer.new()
	roster.name = Teams.display_name(team) + "Roster"
	roster.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster.add_theme_constant_override("separation", 8)
	scroll.add_child(roster)
	_rosters[team] = roster

func render(payload: Dictionary) -> void:
	var names: Dictionary = payload.get("player_names", {})
	var avatars: Dictionary = payload.get("player_avatar_ids", {})
	var teams: Dictionary = payload.get("player_teams", {})
	var local_id := int(payload.get("local_peer_id", 0))
	var connected := bool(payload.get("is_connected", false))
	var host := bool(payload.get("is_server", false))
	var started := bool(payload.get("match_started", false))
	var counts := {Teams.ALPHA: 0, Teams.BRAVO: 0}
	var ids := names.keys()
	ids.sort_custom(func(a: int, b: int):
		if a == local_id or b == local_id:
			return a == local_id and b != local_id
		if (a > 0) != (b > 0):
			return a > 0
		return a < b if a > 0 else a > b)
	for team in [Teams.ALPHA, Teams.BRAVO]:
		var roster: VBoxContainer = _rosters[team]
		for child in roster.get_children():
			roster.remove_child(child)
			child.queue_free()
		for id in ids:
			if int(teams.get(id, Teams.NONE)) != team:
				continue
			counts[team] += 1
			_add_player(roster, int(id), String(names[id]), String(avatars.get(id, "avatar_01")), team, local_id)
		# Empty rows are visual placeholders, never a limit on the roster.
		for _i in range(maxi(3 - int(counts[team]), 0)):
			_add_empty_slot(roster)
		var count: Label = _counts[team]
		count.text = "%d %s" % [counts[team], "PLAYER" if counts[team] == 1 else "PLAYERS"]
		var tag: Label = _team_tags[team]
		tag.text = "YOUR TEAM" if connected and int(teams.get(local_id, Teams.NONE)) == team else "OPPOSING TEAM"
	_connection.text = "%d CONNECTED  /  %s" % [names.size(), "HOST LOBBY" if host else "PLAYER LOBBY"]
	var scene_file := String(payload.get("map_scene_path", "")).get_file().trim_suffix(".tscn")
	_map_name.text = scene_file.replace("_", " ").capitalize() if not scene_file.is_empty() else "No map"
	if scene_file == "cqc_1":
		_map_name.text = "CQC 1"
	_map_thumbnail.texture = CQC_PREVIEW if scene_file == "cqc_1" else MAP_PREVIEW
	_map_thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED if scene_file == "cqc_1" else TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var rounds := scene_file in ["map_1_rounds", "cqc_1"]
	_mode_title.text = "ATTACK / DEFEND" if rounds else "TEAM DEATHMATCH"
	_mode_name.text = "One life per round" if rounds else "Team deathmatch"
	_map_cycle.visible = connected and host and not started
	var assigned := int(counts[Teams.ALPHA]) + int(counts[Teams.BRAVO]) == names.size()
	var balanced := assigned and absi(int(counts[Teams.ALPHA]) - int(counts[Teams.BRAVO])) <= 1
	_balance.text = "%d VS %d  ·  %s" % [counts[Teams.ALPHA], counts[Teams.BRAVO], "Teams balanced" if balanced else "Waiting for balanced teams"]
	_status.text = "Match started" if started else "Host can start the match" if host else "Waiting for host" if connected else "Not connected"
	_start.visible = connected and host and not started
	_switch.visible = connected and not started
	var wanted := Teams.other(int(teams.get(local_id, Teams.NONE)))
	_switch.text = "Switch to " + Teams.display_name(wanted)
	_switch.disabled = not Teams.can_switch(teams, local_id, wanted, ceili(int(payload.get("max_players", 8)) / 2.0))
	_switch.tooltip_text = "Switching would unbalance the teams." if _switch.disabled else "Join " + Teams.display_name(wanted)
	_host_tools.visible = OS.is_debug_build() and connected and host and not started
	_remove_bot.disabled = not ids.any(func(id: int): return id < 0)

func _add_player(roster: VBoxContainer, id: int, player_name: String, avatar_id: String, team: int, local_id: int) -> void:
	var color: Color = Teams.COLORS[team]
	var row := PanelContainer.new()
	row.custom_minimum_size.y = 64
	row.add_theme_stylebox_override("panel", _style(Color("#172633") if id == local_id else Color("#13212d"), color if id == local_id else Color("#263747"), 10))
	roster.add_child(row)
	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	row.add_child(content)
	var avatar := TextureRect.new()
	avatar.custom_minimum_size = Vector2(40, 40)
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar.texture = _avatar_texture(avatar_id)
	content.add_child(avatar)
	var name_label := _label(("[A] " if team == Teams.ALPHA else "[B] ") + player_name, 17, color)
	name_label.name = "player_slot_" + str(id)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.set_meta("peer_id", id)
	content.add_child(name_label)
	var badge := "YOU" if id == local_id else "BOT" if id < 0 else "HOST" if id == 1 else "PLAYER"
	content.add_child(_label(badge, 11, ACCENT if id == local_id else MUTED))

func _add_empty_slot(roster: VBoxContainer) -> void:
	var slot := PanelContainer.new()
	slot.custom_minimum_size.y = 64
	slot.add_theme_stylebox_override("panel", _style(Color("#0e1822"), Color("#1c2a36"), 10))
	roster.add_child(slot)
	slot.add_child(_label("+    Waiting for player", 14, MUTED))

func _avatar_texture(avatar_id: String) -> Texture2D:
	if not _avatar_cache.has(avatar_id):
		var path := String(_avatar_catalog.get(avatar_id, DEFAULT_AVATAR_PATH))
		_avatar_cache[avatar_id] = load(path) as Texture2D
	return _avatar_cache[avatar_id] as Texture2D

func _resize_layout() -> void:
	# Stack rosters on narrow windows; both lists keep independent scrolling.
	_content.columns = 1 if size.x < 720 else 2

func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label

func _button(value: String, node_name: String, primary: bool = false) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = value
	button.custom_minimum_size = Vector2(0, 42)
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_color_override("font_color", BACKGROUND if primary else TEXT)
	button.add_theme_color_override("font_hover_color", BACKGROUND if primary else TEXT)
	button.add_theme_color_override("font_pressed_color", BACKGROUND if primary else TEXT)
	button.add_theme_color_override("font_disabled_color", MUTED.darkened(0.2))
	button.add_theme_stylebox_override("normal", _style(ACCENT if primary else PANEL, ACCENT if primary else Color("#344858"), 12))
	button.add_theme_stylebox_override("hover", _style(ACCENT.lightened(0.15) if primary else Color("#203445"), ACCENT, 12))
	button.add_theme_stylebox_override("pressed", _style(ACCENT.darkened(0.12) if primary else Color("#172633"), ACCENT, 12))
	button.add_theme_stylebox_override("disabled", _style(Color("#0f1821"), Color("#263747"), 12))
	return button

func _style(background: Color, border: Color, padding: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style
