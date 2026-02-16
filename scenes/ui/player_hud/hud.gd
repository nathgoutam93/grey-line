extends CanvasLayer

@onready var _player: PlayerController = get_parent()
@onready var crosshair: Node2D = get_node_or_null("crosshair")
@onready var look_joystick: VirtualJoystick = _resolve_look_joystick()
@onready var controls_root: Control = get_node_or_null("Controls")
@onready var kill_feedback_container: VBoxContainer = get_node("KillFeedbackLayer/KillFeedbackContainer")
@onready var kill_feed_container: VBoxContainer = get_node("KillFeedLayer/KillFeedContainer")

@onready var health_label: Label = get_node("Control/HBoxContainer/Panel/hp")
@onready var ammo_panel: Control = get_node("Control/HBoxContainer/Panel2/HBoxContainer")
@onready var ammo_left_label: Label = get_node("Control/HBoxContainer/Panel2/HBoxContainer/ammo_left")
@onready var mag_size_label: Label = get_node("Control/HBoxContainer/Panel2/HBoxContainer/mag_size")
@onready var primary_slot_ui: Control = get_node("Control/VBoxContainer/WeaponSlot")
@onready var secondary_slot_ui: Control = get_node("Control/VBoxContainer/WeaponSlot2")
@onready var melee_slot_ui: Control = get_node("Control/VBoxContainer/WeaponSlot3")

const HUD_WEAPON_SLOTS := [
	WeaponManager.WeaponSlot.PRIMARY,
	WeaponManager.WeaponSlot.SECONDARY,
	WeaponManager.WeaponSlot.MELEE
]

@export var kill_feedback_item_scene: PackedScene
@export var kill_feed_item_scene: PackedScene

var _slot_nodes_by_slot := {}
var _is_local_hud := false
var _visibility_initialized := false

func _ready() -> void:
	_slot_nodes_by_slot = {
		WeaponManager.WeaponSlot.PRIMARY: primary_slot_ui,
		WeaponManager.WeaponSlot.SECONDARY: secondary_slot_ui,
		WeaponManager.WeaponSlot.MELEE: melee_slot_ui
	}

	await get_tree().process_frame
	await get_tree().process_frame
	_sync_weapon_slots()
	_update_visibility()

func _resolve_look_joystick() -> VirtualJoystick:
	var node := get_node_or_null("Controls/LookJoystick")
	if node is VirtualJoystick:
		return node

	return null

func get_look_joystick() -> VirtualJoystick:
	return look_joystick

func _local_peer_id_or_zero() -> int:
	var peer := multiplayer.multiplayer_peer
	if peer == null:
		return 0
	if peer.has_method("get_connection_status") and peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return 0
	return multiplayer.get_unique_id()

func _update_visibility() -> void:
	var should_be_local_hud := _player.is_local_player
	if not should_be_local_hud:
		var local_peer_id := _local_peer_id_or_zero()
		should_be_local_hud = local_peer_id != 0 and _player.owner_peer_id == local_peer_id
	if _visibility_initialized and should_be_local_hud == _is_local_hud:
		return

	_visibility_initialized = true
	_is_local_hud = should_be_local_hud
	visible = _is_local_hud
	_set_controls_input_enabled(_is_local_hud)

func _set_controls_input_enabled(is_enabled: bool) -> void:
	if not is_instance_valid(controls_root):
		return
	controls_root.process_mode = Node.PROCESS_MODE_INHERIT if is_enabled else Node.PROCESS_MODE_DISABLED

func _sync_weapon_slots() -> void:
	if not _player or not _player.weapon_manager:
		return

	for slot in HUD_WEAPON_SLOTS:
		var weapon_instance := _player.weapon_manager.get_weapon_in_slot(slot) as WeaponInstance
		var slot_ui := _slot_nodes_by_slot.get(slot) as Control
		if not slot_ui:
			continue

		var icon := slot_ui.get_node_or_null("icon") as TextureRect
		var weapon_name := slot_ui.get_node_or_null("name") as Label
		var key_label := slot_ui.get_node_or_null("key") as Label

		var has_weapon := weapon_instance != null and weapon_instance.data != null
		slot_ui.visible = has_weapon
		if not has_weapon:
			continue

		if icon:
			icon.texture = weapon_instance.data.icon
		if weapon_name:
			weapon_name.text = weapon_instance.data.name
		if key_label:
			key_label.text = str(slot + 1)

	_update_slot_selection_visual()

func _update_slot_selection_visual() -> void:
	if not _player or not _player.weapon_manager:
		return

	var current_slot := _player.weapon_manager.current_slot
	for slot in _slot_nodes_by_slot:
		var slot_ui := _slot_nodes_by_slot[slot] as CanvasItem
		if not slot_ui:
			continue
		if not slot_ui.visible:
			continue
		if slot == current_slot:
			slot_ui.modulate = Color(1.0, 1.0, 1.0, 1.0)
		else:
			slot_ui.modulate = Color(0.55, 0.55, 0.55, 0.7)

func _process(_delta: float) -> void:
	_update_crosshair()
	_update_visibility()
	_sync_weapon_slots()
	_update_slot_selection_visual()
	if not visible:
		return

	health_label.text = str(_player.health_component.current_health)
	var current_weapon := _player.weapon_manager.current_weapon
	var uses_ammo := current_weapon != null and current_weapon.data != null and current_weapon.data.uses_ammo
	ammo_panel.visible = uses_ammo
	if not uses_ammo:
		return
	ammo_left_label.text = str(_player.weapon_manager.get_ammo_in_mag())
	mag_size_label.text = str(_player.weapon_manager.get_ammo_reserve())

func _update_crosshair() -> void:
	if not crosshair:
		return
	if not is_instance_valid(_player) or not is_instance_valid(_player.player_input):
		return

	var aim_screen_pos := _player.player_input.get_aim_screen_position()
	if crosshair.has_method("set_aim_screen_position"):
		crosshair.call("set_aim_screen_position", aim_screen_pos)
	else:
		crosshair.position = aim_screen_pos

func show_kill_feedback() -> void:
	if not visible:
		return

	var feedback := _spawn_kill_feedback_item()
	if feedback == null:
		return

	feedback.scale = Vector2(0.9, 0.9)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(feedback, "position:y", feedback.position.y - 12.0, 0.3)
	tween.tween_property(feedback, "modulate:a", 0.0, 0.35).set_delay(1)
	tween.tween_property(feedback, "scale", Vector2(1.0, 1.0), 0.2)
	tween.set_parallel(false)
	tween.tween_callback(feedback.queue_free)

func _spawn_kill_feedback_item() -> Control:
	var item: Control = null

	if kill_feedback_item_scene:
		item = kill_feedback_item_scene.instantiate() as Control

	if item == null:
		var fallback := Label.new()
		fallback.text = "KILL +1"
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		item = fallback

	kill_feedback_container.add_child(item)
	return item

func show_kill_feed_toast(killer_name: String, victim_name: String) -> void:
	if not visible:
		return

	var item := _spawn_kill_feed_item()
	if item == null:
		return

	var text := "%s killed %s" % [killer_name, victim_name]
	if item.has_node("MarginContainer/Text"):
		var label := item.get_node("MarginContainer/Text") as Label
		if label:
			label.text = text
	elif item is Label:
		(item as Label).text = text

	item.modulate = Color(1.0, 1.0, 1.0, 0.0)
	var show_tween := create_tween()
	show_tween.tween_property(item, "modulate:a", 1.0, 0.16)

	var expire_tween := create_tween()
	expire_tween.tween_interval(2.8)
	expire_tween.tween_property(item, "modulate:a", 0.0, 0.25)
	expire_tween.tween_callback(item.queue_free)

func _spawn_kill_feed_item() -> Control:
	var item: Control = null

	if kill_feed_item_scene:
		item = kill_feed_item_scene.instantiate() as Control

	if item == null:
		var fallback := Label.new()
		fallback.text = "A killed B"
		item = fallback

	kill_feed_container.add_child(item)

	while kill_feed_container.get_child_count() > 5:
		var oldest := kill_feed_container.get_child(0)
		if oldest:
			oldest.queue_free()

	return item
