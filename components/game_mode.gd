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

func is_movement_locked() -> bool:
	return true

func allows_damage() -> bool:
	return true

func uses_round_respawns() -> bool:
	return false

func spawn_pool_for(team: int) -> int:
	return team

func configure_player(player: PlayerController) -> void:
	player.actions_locked = false
