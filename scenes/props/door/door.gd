extends StaticBody2D
class_name Door

enum State { CLOSED, OPEN, BROKEN }
const GROUP := &"doors"

@export var max_hp := 60
var state: State = State.CLOSED
var occluder: LightOccluder2D
var _hp := 60
@onready var sprite: Sprite2D = $Sprite2D

func _ready() -> void:
	add_to_group(GROUP)
	_hp = max_hp
	var viewport := MaskViewProvider.viewport
	if is_instance_valid(viewport):
		var level := viewport.get_node_or_null("Level") as Node2D
		if level != null:
			occluder = LightOccluder2D.new()
			occluder.name = "DoorOccluder"
			var polygon := OccluderPolygon2D.new()
			polygon.polygon = PackedVector2Array([Vector2(-32, -4), Vector2(32, -4), Vector2(32, 4), Vector2(-32, 4)])
			occluder.occluder = polygon
			level.add_child(occluder)
			occluder.global_transform = global_transform
	set_state_local(State.CLOSED)

func _exit_tree() -> void:
	if is_instance_valid(occluder):
		occluder.queue_free()

func on_interact(player: PlayerController) -> void:
	if not multiplayer.is_server() or state == State.BROKEN or not is_instance_valid(player) or player.is_dead:
		return
	set_state_local(State.OPEN if state == State.CLOSED else State.CLOSED)
	player.net_sync.report_noise(250.0, 0.4)
	_broadcast_state()

func apply_damage(amount: int, kind: int, source: PlayerController) -> void:
	if not multiplayer.is_server() or state == State.BROKEN or amount <= 0:
		return
	if kind not in [DestructionMaterial.KIND_BULLET, DestructionMaterial.KIND_MELEE, DestructionMaterial.KIND_EXPLOSIVE]:
		return
	_hp -= amount
	if _hp <= 0:
		set_state_local(State.BROKEN)
		if is_instance_valid(source):
			source.net_sync.report_noise(900.0, 1.0)
		_broadcast_state()

func set_state_local(value: State) -> void:
	state = value
	collision_layer = 1 if state == State.CLOSED else 0
	if is_instance_valid(occluder):
		occluder.visible = state == State.CLOSED
	if is_instance_valid(sprite):
		sprite.rotation = PI * 0.5 if state == State.OPEN else 0.0
		sprite.position = Vector2(-28, 28) if state == State.OPEN else Vector2.ZERO
		sprite.scale = Vector2(0.2, 1) if state == State.BROKEN else Vector2.ONE
		sprite.modulate = Color(0.45, 0.45, 0.45) if state == State.BROKEN else Color.WHITE

func restore_all() -> void:
	_hp = max_hp
	set_state_local(State.CLOSED)

func _broadcast_state() -> void:
	if not multiplayer.get_peers().is_empty():
		_state_event.rpc(state)

@rpc("authority", "call_remote", "reliable", 3)
func _state_event(value: int) -> void:
	if value >= State.CLOSED and value <= State.BROKEN:
		set_state_local(value as State)
