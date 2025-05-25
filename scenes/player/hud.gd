extends CanvasLayer

@onready var _player: PlayerController = get_parent()

@onready var weapon_name_label: Label = get_node("Control/HBoxContainer/weapon_name")
@onready var ammo_left_label: Label = get_node("Control/HBoxContainer/HBoxContainer/ammo_left")
@onready var mag_size_label: Label = get_node("Control/HBoxContainer/HBoxContainer/mag_size")


func _ready() -> void:
    if _player.is_remote:
        hide()

func _process(_delta: float) -> void:
    weapon_name_label.text = str(_player.current_weapon.data.name)
    ammo_left_label.text = str(_player.current_weapon.ammo_in_mag)
    mag_size_label.text = str(_player.current_weapon.data.mag_size)