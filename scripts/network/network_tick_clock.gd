extends Node

signal tick_started(tick: int)

@export_range(20, 240, 1) var tick_rate := 60

var tick := 0
var _accumulator := 0.0

func _physics_process(delta: float) -> void:
	var step := 1.0 / float(tick_rate)
	_accumulator += delta
	while _accumulator >= step:
		_accumulator -= step
		tick += 1
		tick_started.emit(tick)

func get_tick_delta() -> float:
	return 1.0 / float(tick_rate)
