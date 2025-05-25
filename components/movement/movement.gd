extends Node
class_name MovementCompoent

const POSITION_EPSILON = 0.1

@onready var _player: PlayerController = get_parent()

var input_vector: Vector2 = Vector2.ZERO
var mouse_pos: Vector2 = Vector2.ZERO
var is_moving = false;

func _ready():
    if not _player:
        push_error("MovementComponet must be a child of PlayerController")

func _process(_delta: float) -> void:
    mouse_pos = owner.get_global_mouse_position()

    input_vector = Vector2(
        Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
        Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
    ).normalized()

func _physics_process(_delta: float):
    var previous_position = _player.position
    
    _player.look_at(mouse_pos)
    
    _player.velocity = input_vector * _player.get_speed()
    _player.move_and_slide()
    
    is_moving = _player.position.distance_to(previous_position) > POSITION_EPSILON
