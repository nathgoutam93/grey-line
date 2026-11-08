extends Node
class_name HealthComponent

@export var max_health: int = 100
const RPC_CHANNEL_WORLD := 1

var current_health: int
var is_dead := false

signal die(killer_id: int)
signal die_detailed(killer_id: int, is_headshot: bool)

func _ready():
	current_health = max_health
	is_dead = false

# Call this function to apply damage
func take_damage(amount: int, killer_id: int, is_headshot: bool = false):
	if not _is_damage_authority():
		return
	if is_dead:
		return
	if amount <= 0:
		return
	current_health -= amount
	current_health = maxi(current_health, 0)

	if current_health == 0:
		is_dead = true
		emit_signal("die", killer_id)
		emit_signal("die_detailed", killer_id, is_headshot)

	_remote_sync_health.rpc(current_health, is_dead)

func _is_damage_authority() -> bool:
	return multiplayer.multiplayer_peer == null or multiplayer.is_server()

@rpc("authority", "call_remote", "reliable", RPC_CHANNEL_WORLD)
func _remote_sync_health(new_health: int, dead: bool) -> void:
	current_health = clampi(new_health, 0, max_health)
	is_dead = dead
