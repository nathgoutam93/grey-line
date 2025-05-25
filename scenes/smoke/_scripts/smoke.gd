extends Node2D

@export var duration := 5.0

func _ready():
	await get_tree().create_timer(duration).timeout
	queue_free()
