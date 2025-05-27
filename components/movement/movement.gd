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
	var previous_position = player.position
	
	player.look_at(player_input.mouse_pos)
	
	player.velocity = player_input.input_vector * player.get_speed()
	player.move_and_slide()
	
	is_moving = player.position.distance_to(previous_position) > POSITION_EPSILON
