extends Node
class_name HealthComponent

@export var max_health: int = 100

var current_health: int

signal die(killer_id: int)

func _ready():
    current_health = max_health

# Call this function to apply damage
func take_damage(amount: int, killer_id: int):
    current_health -= amount
    current_health = max(current_health, 0)
    
    print("Took damage:", amount, "Current health:", current_health)
    
    if current_health == 0:
        emit_signal("die", killer_id)
