extends Node2D
class_name AnimationController

@onready var animation_player: AnimatedSprite2D = get_node("Sprite")

func _ready():
	if not animation_player:
		push_error("Animation Controller needs an AnimatedSprite2D")

func play(anim: String):
	animation_player.play(anim)
