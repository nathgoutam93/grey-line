extends RefCounted
class_name LagCompensationService

## Moves every player except `shooter` back to where they were at `tick`.
## The shooter stays put: the shot originates from their current
## authoritative position, only the targets are rewound.
static func rewind_players_to_tick(tree: SceneTree, tick: int, shooter: Node = null) -> Dictionary:
	var saved_transforms := {}
	if tree == null:
		return saved_transforms
	for node in tree.get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player == null:
			continue
		if player == shooter:
			continue
		if player.is_dead:
			continue
		saved_transforms[player] = player.global_transform
		var rewind_transform : Variant = player.net_sync.get_history_transform(tick)
		if rewind_transform != null:
			player.global_transform = rewind_transform
	return saved_transforms

static func restore_players(saved_transforms: Dictionary) -> void:
	for key in saved_transforms.keys():
		var player := key as PlayerController
		if player == null:
			continue
		if not is_instance_valid(player):
			continue
		player.global_transform = saved_transforms[key]
