extends Node
class_name StateMachine

var states: Dictionary = {}
var current_state: State = null
var prv_state: String

func _ready() -> void:
	owner = get_owner()
	_setup_states()
	if states.has("Idle"):
		transition_to("Idle")

func _setup_states() -> void:
	for child in get_children():
		if child is State:
			states[child.name] = child
			child.state_machine = self
			child.owner = owner

func transition_to(state_name: String, params = {}):
	if current_state:
		prv_state = current_state.name
		current_state.exit()

	current_state = states.get(state_name, null)

	if current_state:
		current_state.enter(params)


func _physics_process(delta: float) -> void:
	if current_state:
		current_state.physics_update(delta)
