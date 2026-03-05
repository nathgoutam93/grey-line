extends Node
class_name MovementCompoent

const POSITION_EPSILON = 0.1

@export var player: PlayerController
@export var player_input: PlayerInputCollector

@export var is_moving := false
@export var external_velocity_decay: float = 1100.0

var external_velocity := Vector2.ZERO

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

	player.velocity = (move_direction * player.get_speed()) + external_velocity
	player.move_and_slide()
	_decay_external_velocity()
	is_moving = player.position.distance_to(previous_position) > POSITION_EPSILON


func add_external_velocity(added_velocity: Vector2) -> void:
	external_velocity += added_velocity


func _decay_external_velocity() -> void:
	if external_velocity.length_squared() <= 0.001:
		external_velocity = Vector2.ZERO
		return
	var tick_rate := maxi(int(NetworkTick.tick_rate), 1)
	var decay_per_tick := external_velocity_decay / float(tick_rate)
	external_velocity = external_velocity.move_toward(Vector2.ZERO, decay_per_tick)
