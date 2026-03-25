extends Node2D

@export var duration: float = 5.0
@export var grow_duration: float = 1.0
@export var fade_in_duration: float = 0.35
@export var fade_out_duration: float = 1.0
@export var start_scale_multiplier: float = 0.2
@export var end_scale_multiplier: float = 1.0
@export_range(1, 8, 1) var layer_count: int = 4
@export var layer_spread: float = 10.0
@export var min_layer_scale: float = 0.85
@export var max_layer_scale: float = 1.2
@export var min_rotation_speed_deg: float = -16.0
@export var max_rotation_speed_deg: float = 16.0
@export var min_pulse_amplitude: float = 0.05
@export var max_pulse_amplitude: float = 0.14
@export var min_pulse_frequency: float = 0.6
@export var max_pulse_frequency: float = 1.8
@export var motion_seed: float = -1.0

@onready var sprite: Sprite2D = get_node_or_null("Sprite2D")

var _base_scale := Vector2.ONE
var _elapsed := 0.0
var _rng := RandomNumberGenerator.new()
var _layers: Array[Sprite2D] = []
var _layer_base_scale: Array[Vector2] = []
var _layer_base_rotation: Array[float] = []
var _layer_rotation_speed: Array[float] = []
var _layer_pulse_amplitude: Array[float] = []
var _layer_pulse_frequency: Array[float] = []
var _layer_pulse_phase: Array[float] = []
var _layer_alpha_multiplier: Array[float] = []

func _ready() -> void:
	_base_scale = scale
	if motion_seed >= 0.0:
		_rng.seed = int(abs(motion_seed) * 1000.0)
	else:
		_rng.randomize()
	_setup_layers()
	set_process(true)


func _process(delta: float) -> void:
	_elapsed += delta
	var life := maxf(duration, 0.1)

	var grow_t := clampf(_elapsed / maxf(grow_duration, 0.01), 0.0, 1.0)
	var eased_grow := 1.0 - pow(1.0 - grow_t, 3.0)
	var scale_multiplier := lerpf(start_scale_multiplier, end_scale_multiplier, eased_grow)
	scale = _base_scale * scale_multiplier

	var alpha := 1.0
	if _elapsed < fade_in_duration:
		alpha = clampf(_elapsed / maxf(fade_in_duration, 0.01), 0.0, 1.0)
	var fade_out_start := maxf(life - fade_out_duration, 0.0)
	if _elapsed > fade_out_start:
		var out_t := clampf((_elapsed - fade_out_start) / maxf(fade_out_duration, 0.01), 0.0, 1.0)
		alpha *= (1.0 - out_t)
	_animate_layers(alpha)

	if _elapsed >= life:
		queue_free()


func _setup_layers() -> void:
	if sprite == null:
		return

	_layers.clear()
	_layer_base_scale.clear()
	_layer_base_rotation.clear()
	_layer_rotation_speed.clear()
	_layer_pulse_amplitude.clear()
	_layer_pulse_frequency.clear()
	_layer_pulse_phase.clear()
	_layer_alpha_multiplier.clear()

	var count := maxi(layer_count, 1)
	var source_texture := sprite.texture
	var source_centered := sprite.centered
	var source_modulate := sprite.modulate

	for index in range(count):
		var layer: Sprite2D
		if index == 0:
			layer = sprite
		else:
			layer = Sprite2D.new()
			layer.texture = source_texture
			layer.centered = source_centered
			add_child(layer)

		var offset_angle := _rng.randf_range(0.0, TAU)
		var offset_radius := _rng.randf_range(0.0, layer_spread)
		layer.position = Vector2.RIGHT.rotated(offset_angle) * offset_radius
		layer.rotation = _rng.randf_range(0.0, TAU)

		var base_scale_factor := _rng.randf_range(min_layer_scale, max_layer_scale)
		var base_scale := Vector2.ONE * base_scale_factor
		layer.scale = base_scale

		layer.modulate = source_modulate
		layer.modulate.a = 0.0

		_layers.append(layer)
		_layer_base_scale.append(base_scale)
		_layer_base_rotation.append(layer.rotation)
		_layer_rotation_speed.append(deg_to_rad(_rng.randf_range(min_rotation_speed_deg, max_rotation_speed_deg)))
		_layer_pulse_amplitude.append(_rng.randf_range(min_pulse_amplitude, max_pulse_amplitude))
		_layer_pulse_frequency.append(_rng.randf_range(min_pulse_frequency, max_pulse_frequency))
		_layer_pulse_phase.append(_rng.randf_range(0.0, TAU))
		_layer_alpha_multiplier.append(_rng.randf_range(0.72, 1.0))


func _animate_layers(alpha: float) -> void:
	for index in range(_layers.size()):
		var layer := _layers[index]
		if layer == null:
			continue
		layer.rotation = _layer_base_rotation[index] + (_layer_rotation_speed[index] * _elapsed)
		var pulse := 1.0 + (sin((_elapsed * _layer_pulse_frequency[index]) + _layer_pulse_phase[index]) * _layer_pulse_amplitude[index])
		layer.scale = _layer_base_scale[index] * pulse
		layer.modulate.a = alpha * _layer_alpha_multiplier[index]
