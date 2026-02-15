extends CanvasLayer

@onready var _player: PlayerController = get_parent()

@onready var health_label: Label = get_node("Control/HBoxContainer/Panel/hp")
@onready var ammo_left_label: Label = get_node("Control/HBoxContainer/Panel2/HBoxContainer/ammo_left")
@onready var mag_size_label: Label = get_node("Control/HBoxContainer/Panel2/HBoxContainer/mag_size")
@onready var slot_container: VBoxContainer = get_node("Control/VBoxContainer")

const WEAPON_SLOT_SCENE := preload("res://scenes/ui/weapon_slot/weapon_slot.tscn")
const HUD_WEAPON_SLOTS := [
	WeaponManager.WeaponSlot.PRIMARY,
	WeaponManager.WeaponSlot.SECONDARY,
	WeaponManager.WeaponSlot.MELEE
]

var _weapon_slots_signature := ""
var _slot_nodes_by_slot := {}

func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_sync_weapon_slots(true)
	_update_visibility()

func _update_visibility() -> void:
	var is_local_hud := _player.is_local_player or _player.owner_peer_id == multiplayer.get_unique_id()
	visible = is_local_hud

func _sync_weapon_slots(force := false) -> void:
	if not _player or not _player.weapon_manager:
		return

	var signature_parts: Array[String] = []
	for slot in HUD_WEAPON_SLOTS:
		var weapon_instance := _player.weapon_manager.get_weapon_in_slot(slot) as WeaponInstance
		if weapon_instance and weapon_instance.data:
			signature_parts.append("%d:%s:%s" % [slot, weapon_instance.get_instance_id(), weapon_instance.data.name])
		else:
			signature_parts.append("%d:null" % slot)
	var signature := "|".join(signature_parts)

	if not force and signature == _weapon_slots_signature:
		return
	_weapon_slots_signature = signature

	for child in slot_container.get_children():
		child.queue_free()
	_slot_nodes_by_slot.clear()

	for slot in HUD_WEAPON_SLOTS:
		var weapon_instance := _player.weapon_manager.get_weapon_in_slot(slot) as WeaponInstance
		if not weapon_instance or not weapon_instance.data:
			continue

		var slot_ui := WEAPON_SLOT_SCENE.instantiate()
		var icon := slot_ui.get_node_or_null("icon") as TextureRect
		var weapon_name := slot_ui.get_node_or_null("name") as Label
		var key_label := slot_ui.get_node_or_null("key") as Label

		if icon:
			icon.texture = weapon_instance.data.icon
		if weapon_name:
			weapon_name.text = weapon_instance.data.name
		if key_label:
			key_label.text = str(slot + 1)

		slot_container.add_child(slot_ui)
		_slot_nodes_by_slot[slot] = slot_ui

	_update_slot_selection_visual()

func _update_slot_selection_visual() -> void:
	if not _player or not _player.weapon_manager:
		return

	var current_slot := _player.weapon_manager.current_slot
	for slot in _slot_nodes_by_slot:
		var slot_ui := _slot_nodes_by_slot[slot] as CanvasItem
		if not slot_ui:
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
	ammo_left_label.text = str(_player.weapon_manager.get_ammo_in_mag())
	mag_size_label.text = str(_player.weapon_manager.get_mag_size())
