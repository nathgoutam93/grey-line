extends Area2D
class_name Interactable

signal player_entered(player: PlayerController)
signal player_exited(player: PlayerController)

var owner_ref: Node

func _ready():
	owner_ref = get_parent()

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node2D) -> void:
	var player := body as PlayerController
	if player != null:
		if not player.interactables.has(self):
			player.add_interactable(self)
		player_entered.emit(player)

func _on_body_exited(body: Node2D) -> void:
	var player := body as PlayerController
	if player != null:
		player.remove_interactable(self)
		player_exited.emit(player)

func on_interact(player: PlayerController) -> void:
	if not multiplayer.is_server() or not is_instance_valid(player) or player.is_dead or not player.interactables.has(self):
		return
	if owner_ref is Door:
		(owner_ref as Door).on_interact(player)
	elif owner_ref is WeaponPickup:
		(owner_ref as WeaponPickup).on_interact(player)
