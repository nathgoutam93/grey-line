extends Node
class_name DestructionService

const GROUP := &"destruction_service"
const RPC_CHANNEL_DESTRUCTION := 3

signal cells_destroyed(cells: Array[Vector2i])

func _ready() -> void:
	add_to_group(GROUP)

static func current(tree: SceneTree) -> DestructionService:
	return tree.get_first_node_in_group(GROUP) as DestructionService
