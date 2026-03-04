extends CanvasLayer

@onready var _player: PlayerController = get_parent()
@onready var controls_root: Control = get_node_or_null("Controls")
@onready var touch_aim_zone: TouchAimZone = get_node_or_null("Controls/TouchAimZone")
@onready var kill_feedback_container: VBoxContainer = get_node("KillFeedbackLayer/KillFeedbackContainer")
@onready var kill_feed_container: VBoxContainer = get_node("KillFeedLayer/KillFeedContainer")
@onready var stun_flash_overlay: ColorRect = get_node_or_null("StunFlashOverlay")

@onready var health_label: Label = get_node("Control/HBoxContainer/Panel/hp")
@onready var ammo_panel: Control = get_node("Control/HBoxContainer/Panel2/HBoxContainer")
@onready var ammo_left_label: Label = get_node("Control/HBoxContainer/Panel2/HBoxContainer/ammo_left")
@onready var mag_size_label: Label = get_node("Control/HBoxContainer/Panel2/HBoxContainer/mag_size")
@onready var primary_slot_ui: Control = get_node("Control/VBoxContainer/WeaponSlot")
@onready var secondary_slot_ui: Control = get_node("Control/VBoxContainer/WeaponSlot2")
@onready var melee_slot_ui: Control = get_node("Control/VBoxContainer/WeaponSlot3")
@onready var utility_slot_ui: Control = get_node("Control/VBoxContainer/WeaponSlot4")
@onready var throwable_slot_ui: Control = get_node("Control/VBoxContainer/WeaponSlot5")
@onready var utility_extra_slot_ui: Control = get_node("Control/VBoxContainer/WeaponSlot6")

const HUD_EQUIPMENT_SLOTS := [
	EquipmentData.EquipmentSlot.PRIMARY,
	EquipmentData.EquipmentSlot.SECONDARY,
	EquipmentData.EquipmentSlot.MELEE,
	EquipmentData.EquipmentSlot.UTILITY_1,
	EquipmentData.EquipmentSlot.UTILITY_2,
	EquipmentData.EquipmentSlot.UTILITY_3
]
const SLOT_HOTKEY_LABELS := {
	EquipmentData.EquipmentSlot.PRIMARY: "1",
	EquipmentData.EquipmentSlot.SECONDARY: "2",
	EquipmentData.EquipmentSlot.MELEE: "3",
	EquipmentData.EquipmentSlot.UTILITY_1: "Q",
	EquipmentData.EquipmentSlot.UTILITY_2: "E",
	EquipmentData.EquipmentSlot.UTILITY_3: "X"
}

@export var kill_feedback_item_scene: PackedScene
@export var headshot_feedback_item_scene: PackedScene
@export var kill_feed_item_scene: PackedScene

var _slot_nodes_by_slot := {}
var _is_local_hud := false
var _visibility_initialized := false
var _stun_flash_tween: Tween = null

func _ready() -> void:
	_slot_nodes_by_slot = {
		EquipmentData.EquipmentSlot.PRIMARY: primary_slot_ui,
		EquipmentData.EquipmentSlot.SECONDARY: secondary_slot_ui,
		EquipmentData.EquipmentSlot.MELEE: melee_slot_ui,
		EquipmentData.EquipmentSlot.UTILITY_1: utility_slot_ui,
		EquipmentData.EquipmentSlot.UTILITY_2: throwable_slot_ui,
		EquipmentData.EquipmentSlot.UTILITY_3: utility_extra_slot_ui
	}

	await get_tree().process_frame
	await get_tree().process_frame
	_sync_weapon_slots()
	_update_visibility()
	
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


func _get_equipment_manager() -> Node:
	return _player.equipment_manager


func _sync_weapon_slots() -> void:
	if not _player:
		return
	
	var equipment_manager = _get_equipment_manager()
	if not equipment_manager:
		return

	for slot in HUD_EQUIPMENT_SLOTS:
		var item_instance = equipment_manager.get_item_in_slot(slot)
		var slot_ui := _slot_nodes_by_slot.get(slot) as Control
		if not slot_ui:
			continue

		var icon := slot_ui.get_node_or_null("icon") as TextureRect
		var item_name := slot_ui.get_node_or_null("name") as Label
		var key_label := slot_ui.get_node_or_null("key") as Label

		var has_item := item_instance != null and item_instance.equipment_data != null
		slot_ui.visible = has_item
		if not has_item:
			continue

		if icon:
			icon.texture = item_instance.equipment_data.icon
		if item_name:
			item_name.text = item_instance.equipment_data.name
		if key_label:
			key_label.text = SLOT_HOTKEY_LABELS.get(slot, "")

	_update_slot_selection_visual()

func _update_slot_selection_visual() -> void:
	if not _player:
		return
	
	var equipment_manager = _get_equipment_manager()
	if not equipment_manager:
		return

	var current_slot = int(equipment_manager.get("current_slot"))
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
	_update_visibility()
	_sync_weapon_slots()
	_update_slot_selection_visual()
	if not visible:
		return

	health_label.text = str(_player.health_component.current_health)
	
	var equipment_manager = _get_equipment_manager()
	if not equipment_manager:
		return
	var current_item = equipment_manager.get_current_item()
	var uses_ammo := current_item != null and current_item is WeaponInstance and (current_item as WeaponInstance).data != null and (current_item as WeaponInstance).data.uses_ammo
	ammo_panel.visible = uses_ammo
	if not uses_ammo:
		return
	var weapon_instance = current_item as WeaponInstance
	ammo_left_label.text = str(weapon_instance.ammo_in_mag)
	mag_size_label.text = str(weapon_instance.ammo_reserve)

func show_kill_feedback(is_headshot: bool = false) -> void:
	if not visible:
		return

	var feedback := _spawn_kill_feedback_item(is_headshot)
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

func _spawn_kill_feedback_item(is_headshot: bool = false) -> Control:
	var item: Control = null

	var scene_to_use: PackedScene = kill_feedback_item_scene
	if is_headshot and headshot_feedback_item_scene:
		scene_to_use = headshot_feedback_item_scene

	if scene_to_use:
		item = scene_to_use.instantiate() as Control

	if item == null:
		var fallback := Label.new()
		fallback.text = "HEADSHOT +1" if is_headshot else "KILL +1"
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

func get_touch_aim_zone() -> TouchAimZone:
	return touch_aim_zone


func show_stun_flash(duration_seconds: float, max_alpha: float = 0.95) -> void:
	if not is_instance_valid(stun_flash_overlay):
		return
	if _stun_flash_tween != null:
		_stun_flash_tween.kill()
	_stun_flash_tween = create_tween()
	stun_flash_overlay.visible = true
	stun_flash_overlay.modulate = Color(1.0, 1.0, 1.0, clampf(max_alpha, 0.0, 1.0))
	_stun_flash_tween.tween_property(stun_flash_overlay, "modulate:a", 0.0, maxf(duration_seconds, 0.05))
	_stun_flash_tween.tween_callback(func():
		stun_flash_overlay.visible = false
	)
