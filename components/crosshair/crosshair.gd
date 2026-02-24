class_name Crosshair
extends Node2D

@export var idle_color : Color = Color(1,0,0,0.5)
@export var error_color : Color = Color(1,0,0,0.15)

@export var max_spread_angle: float = 15.0   # degrees
@export var max_speed: float = 400.0
@export var line_length: float = 150.0
@export var cone_segments: int = 24

var current_spread: float = 0.0   # degrees
var player_velocity: Vector2

@onready var _player := get_parent() as PlayerController

func _process(_delta):
	visible = _should_render_for_local_player()
	if not visible:
		return

	update_spread()
	queue_redraw()

func update_spread():
	var speed = player_velocity.length()
	var t = clamp(speed / max_speed, 0.0, 1.0)
	current_spread = lerp(current_spread, t * max_spread_angle, 8.0 * get_process_delta_time())

func _draw():
	if current_spread <= 0.1:
		draw_idle_line()
	else:
		draw_spread_cone()

func draw_idle_line():
	var forward = Vector2.RIGHT
	draw_line(Vector2.ZERO, forward * line_length, idle_color, 2)

func draw_spread_cone():
	var forward = Vector2.RIGHT
	var half_angle = deg_to_rad(current_spread)

	var points = []
	points.append(Vector2.ZERO)

	for i in range(cone_segments + 1):
		var t = float(i) / cone_segments
		var angle = lerp(-half_angle, half_angle, t)
		var dir = forward.rotated(angle)
		points.append(dir * line_length)

	draw_colored_polygon(points, error_color)
	draw_polyline(points, error_color, 2)

func _should_render_for_local_player() -> bool:
	if not is_instance_valid(_player):
		return false
	if _player.is_local_player:
		return true

	var local_peer_id := _local_peer_id_or_zero()
	if local_peer_id == 0:
		return false

	return _player.owner_peer_id == local_peer_id

func _local_peer_id_or_zero() -> int:
	var peer := multiplayer.multiplayer_peer
	if peer == null:
		return 0
	if peer.has_method("get_connection_status") and peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return 0

	return multiplayer.get_unique_id()
