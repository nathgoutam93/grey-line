extends Node2D
class_name PlayerMesh

@export var hand_socket: Node2D
@export var anim_player: AnimationPlayer
@export var leg_anim_player: AnimationPlayer

const LEG_IDLE_ANIMATION := "leg_idle"
const LEG_MOVE_ANIMATION := "leg_move"

func update_leg_animation(is_moving: bool) -> void:
	if leg_anim_player == null:
		return
	var animation_name := LEG_MOVE_ANIMATION if is_moving else LEG_IDLE_ANIMATION
	if not leg_anim_player.has_animation(animation_name):
		return
	if leg_anim_player.current_animation == animation_name and leg_anim_player.is_playing():
		return
	leg_anim_player.play(animation_name)
