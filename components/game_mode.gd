extends Node
class_name MatchGameMode

## Shared, typed rules for all nodes in the game_mode group.
@export var teams_enabled := true
@export var friendly_fire := false

static func current(tree: SceneTree) -> MatchGameMode:
	return tree.get_first_node_in_group("game_mode") as MatchGameMode

static func is_friendly_fire_enabled(tree: SceneTree) -> bool:
	var mode := current(tree)
	return mode.friendly_fire if mode != null else false
