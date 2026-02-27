extends Node
class_name HealthComponent

@export var max_health: int = 100

var current_health: int
var is_dead := false

signal die(killer_id: int)
signal die_detailed(killer_id: int, is_headshot: bool)

func _ready():
	current_health = max_health
	is_dead = false

# Call this function to apply damage
func take_damage(amount: int, killer_id: int, is_headshot: bool = false):
	if is_dead:
		return
	if amount <= 0:
		return
	current_health -= amount
	current_health = max(current_health, 0)
	
	print("Took damage:", amount, "Current health:", current_health)
	
	if current_health == 0:
		is_dead = true
		emit_signal("die", killer_id)
		emit_signal("die_detailed", killer_id, is_headshot)
