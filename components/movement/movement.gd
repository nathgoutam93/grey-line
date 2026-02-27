extends Node
class_name MovementCompoent

const POSITION_EPSILON = 0.1

@export var player: PlayerController
@export var player_input: PlayerInputCollector

@export var is_moving := false

func _ready():
	if not player:
		push_error("MovementComponet must be a child of PlayerController")

func simulate(input_frame: PlayerInputFrame) -> void:
	if player == null or input_frame == null:
		is_moving = false
		return

	var previous_position := player.position
	var move_input := input_frame.move
	var aim_dir := input_frame.aim_dir

	if aim_dir.length_squared() > 0.0001:
		player.rotation = aim_dir.angle()

	var forward_input := -move_input.y
	var strafe_input := move_input.x
	var move_direction := (player.transform.x * forward_input) + (player.transform.y * strafe_input)
	if move_direction.length_squared() > 1.0:
		move_direction = move_direction.normalized()

	player.velocity = move_direction * player.get_speed()
	player.move_and_slide()
	is_moving = player.position.distance_to(previous_position) > POSITION_EPSILON
