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
	var move_input := Vector2.ZERO if player.movement_locked else input_frame.move
	if player.movement_locked:
		external_velocity = Vector2.ZERO
	var aim_dir := input_frame.aim_dir

	if aim_dir.length_squared() > 0.0001:
		player.rotation = aim_dir.angle()

	var forward_input := -move_input.y
	var strafe_input := move_input.x
	var move_direction := (player.transform.x * forward_input) + (player.transform.y * strafe_input)
	if move_direction.length_squared() > 1.0:
		move_direction = move_direction.normalized()

	player.velocity = (move_direction * player.get_speed()) + external_velocity
	_move_one_tick()
	_decay_external_velocity()
	is_moving = player.position.distance_to(previous_position) > POSITION_EPSILON


## move_and_slide() integrates over the physics delta inside a physics frame
## but over the *render* frame delta anywhere else - and reconciliation
## replays run while handling snapshot packets, outside the physics frame.
## Scale velocity so every simulated step covers exactly one network tick
## regardless of where it is called from, the frame rate, or the physics
## tick rate.
func _move_one_tick() -> void:
	var engine_delta := player.get_physics_process_delta_time() if Engine.is_in_physics_frame() else player.get_process_delta_time()
	var tick_delta := NetworkTick.get_tick_delta()
	if engine_delta <= 0.0 or is_equal_approx(engine_delta, tick_delta):
		player.move_and_slide()
		return
	var scale := tick_delta / engine_delta
	player.velocity *= scale
	player.move_and_slide()
	player.velocity /= scale


func add_external_velocity(added_velocity: Vector2) -> void:
	external_velocity += added_velocity


func _decay_external_velocity() -> void:
	if external_velocity.length_squared() <= 0.001:
		external_velocity = Vector2.ZERO
		return
	var tick_rate := maxi(int(NetworkTick.tick_rate), 1)
	var decay_per_tick := external_velocity_decay / float(tick_rate)
	external_velocity = external_velocity.move_toward(Vector2.ZERO, decay_per_tick)
