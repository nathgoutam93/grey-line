extends StaticBody2D
class_name BreakableProp

## A prop that bullets, melee and explosions can break. Breaking removes its
## collision, sprite and fog occlusion everywhere; the map's DestructionService
## includes it in full-state repair and round reset. Like doors, the server owns
## HP and replicates the state on reliable channel 3.

const GROUP := &"breakable_props"
const RPC_CHANNEL_DESTRUCTION := 3
## Fog occluders inside the prop's collision box (grown by this margin) belong to it.
const FOG_LINK_MARGIN := 4.0

@export var max_hp := 80
@export var break_sound: AudioStream
@export var break_sound_max_distance := 900.0

var broken := false
var _hp := 80
var _collision_layer := 1
var _fog_occluders: Array[LightOccluder2D] = []

func _ready() -> void:
	add_to_group(GROUP)
	_hp = max_hp
	_collision_layer = collision_layer
	# Fog occluders are created by the map's mask view or a PropFogOccluder
	# child; link them once the whole map is in the tree.
	_link_fog_occluders.call_deferred()

func hp() -> int:
	return _hp

func apply_damage(amount: int, kind: int) -> void:
	if not multiplayer.is_server() or broken or amount <= 0 or not DestructionMaterial.is_valid_kind(kind):
		return
	_hp -= amount
	if _hp > 0:
		return
	set_broken_local(true)
	_play_break_sound()
	if not multiplayer.get_peers().is_empty():
		_broken_event.rpc()

func set_broken_local(value: bool) -> void:
	broken = value
	collision_layer = 0 if broken else _collision_layer
	visible = not broken
	for occluder in _fog_occluders:
		if is_instance_valid(occluder):
			occluder.visible = not broken

func restore_all() -> void:
	_hp = max_hp
	set_broken_local(false)

@rpc("authority", "call_remote", "reliable", RPC_CHANNEL_DESTRUCTION)
func _broken_event() -> void:
	if broken:
		return
	set_broken_local(true)
	_play_break_sound()

## Positional break sound at the prop on every peer. It is world audio, not
## player noise, so it never reveals who broke the prop.
func _play_break_sound() -> void:
	if break_sound == null or DisplayServer.get_name() == "headless" or not is_inside_tree():
		return
	var sound := AudioStreamPlayer2D.new()
	sound.stream = break_sound
	sound.max_distance = break_sound_max_distance
	sound.finished.connect(sound.queue_free)
	get_parent().add_child(sound)
	sound.global_position = global_position
	sound.play()

func _link_fog_occluders() -> void:
	_fog_occluders.clear()
	var viewport := MaskViewProvider.viewport
	if not is_instance_valid(viewport):
		return
	var level := viewport.get_node_or_null("Level")
	if level == null:
		return
	var bounds := _collision_bounds().grow(FOG_LINK_MARGIN)
	if not bounds.has_area():
		return
	for node in level.find_children("*", "LightOccluder2D", true, false):
		var occluder := node as LightOccluder2D
		if occluder.occluder == null or occluder.occluder.polygon.is_empty():
			continue
		var inside := true
		for point in occluder.occluder.polygon:
			if not bounds.has_point(occluder.global_transform * point):
				inside = false
				break
		if inside:
			_fog_occluders.append(occluder)
	set_broken_local(broken)

func _collision_bounds() -> Rect2:
	var bounds := Rect2()
	var first := true
	for child in get_children():
		var points := PackedVector2Array()
		if child is CollisionPolygon2D:
			points = (child as CollisionPolygon2D).polygon
		elif child is CollisionShape2D and (child as CollisionShape2D).shape is RectangleShape2D:
			var half: Vector2 = ((child as CollisionShape2D).shape as RectangleShape2D).size * 0.5
			points = PackedVector2Array([-half, Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)])
		for point in points:
			var world := (child as Node2D).global_transform * point
			if first:
				bounds = Rect2(world, Vector2.ZERO)
				first = false
			else:
				bounds = bounds.expand(world)
	return bounds
