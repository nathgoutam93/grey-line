extends Node2D


func _ready() -> void:
    await get_tree().create_timer(10).timeout
    queue_free()