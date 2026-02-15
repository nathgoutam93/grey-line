extends CanvasLayer

@onready var _player: PlayerController = get_parent()

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

var _slot_nodes_by_slot := {}

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

func _update_visibility() -> void:
	var is_local_hud := _player.is_local_player or _player.owner_peer_id == multiplayer.get_unique_id()
	visible = is_local_hud

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
