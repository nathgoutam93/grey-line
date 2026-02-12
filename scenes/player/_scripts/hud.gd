extends CanvasLayer

@onready var _player: PlayerController = get_parent()

@onready var health_label: Label = get_node("Control/HBoxContainer/Panel/hp")
@onready var weapon_name_label: Label = get_node("Control/HBoxContainer/Panel3/weapon_name")
@onready var ammo_left_label: Label = get_node("Control/HBoxContainer/Panel2/HBoxContainer/ammo_left")
@onready var mag_size_label: Label = get_node("Control/HBoxContainer/Panel2/HBoxContainer/mag_size")

func _ready() -> void:
	_update_visibility()

func _update_visibility() -> void:
	var is_local_hud := _player.is_local_player or _player.owner_peer_id == multiplayer.get_unique_id()
	visible = is_local_hud

func _process(_delta: float) -> void:
	_update_visibility()
	if not visible:
		return

	health_label.text = str(_player.health_component.current_health)
	weapon_name_label.text = str(_player.weapon_manager.get_current_weapon_name())
	ammo_left_label.text = str(_player.weapon_manager.get_ammo_in_mag())
	mag_size_label.text = str(_player.weapon_manager.get_mag_size())
