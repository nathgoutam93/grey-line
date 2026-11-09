extends Area2D
class_name ObjectiveZone

const GROUP := &"objective"

func _ready() -> void:
	add_to_group(GROUP)

## Attackers, defenders; dead bodies never contest capture.
func living_counts(attacking_team: int) -> Vector2i:
	var counts := Vector2i.ZERO
	for body in get_overlapping_bodies():
		var player := body as PlayerController
		if player == null or player.is_dead or player.team == Teams.NONE:
			continue
		if player.team == attacking_team:
			counts.x += 1
		else:
			counts.y += 1
	return counts
