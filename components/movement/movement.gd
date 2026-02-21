extends MultiplayerSynchronizer
class_name MovementCompoent

const POSITION_EPSILON = 0.1

@export var player: PlayerController
@export var player_input: PlayerInput

@export var is_moving := false

func _ready():
	if not player:
		push_error("MovementComponet must be a child of PlayerController")

	set_physics_process(multiplayer.is_server())

func _physics_process(_delta: float):
	if player == null or player_input == null:
		is_moving = false
		return

	var previous_position := player.position

	var to_aim := player_input.mouse_pos - player.global_position
	if to_aim.length_squared() > 0.0001:
		player.rotation = to_aim.angle()

	var forward_input := -player_input.input_vector.y
	var strafe_input := player_input.input_vector.x
	var move_direction := (player.transform.x * forward_input) + (player.transform.y * strafe_input)
	if move_direction.length_squared() > 1.0:
		move_direction = move_direction.normalized()

	player.velocity = move_direction * player.get_speed()
	player.move_and_slide()

	is_moving = player.position.distance_to(previous_position) > POSITION_EPSILON
