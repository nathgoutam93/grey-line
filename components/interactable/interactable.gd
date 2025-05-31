extends Area2D
class_name Interactable

signal player_entered(player: PlayerController)
signal player_exited(player: PlayerController)

var owner_ref
var player_ref = null

func _ready():
	owner_ref = get_parent()

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _on_body_entered(body):
	if body.is_in_group("Player"):
		player_ref = body
		player_ref.add_interactable(self)
		emit_signal("player_entered", body)

func _on_body_exited(body):
	if body == player_ref:
		player_ref.remove_interactable(self)
		emit_signal("player_exited", body)
		player_ref = null

func on_interact():
	if owner_ref and owner_ref.has_method("on_interact"):
		owner_ref.on_interact(player_ref)
