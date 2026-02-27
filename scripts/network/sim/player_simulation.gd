extends RefCounted
class_name PlayerSimulation

static func simulate(player: PlayerController, movement_component: MovementCompoent, input_frame: PlayerInputFrame) -> void:
	if player == null or movement_component == null or input_frame == null:
		return
	movement_component.simulate(input_frame)
