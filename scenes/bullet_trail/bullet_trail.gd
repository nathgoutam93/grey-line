extends Node2D

var speed := 4000.0
var start_point: Vector2
var end_point: Vector2
var normal: Vector2

@export var impact_spawner: ImpactSpawner2D

func _ready():
    position = start_point
    rotation = (end_point - start_point).angle()
    var distance = start_point.distance_to(end_point)
    var duration = distance / speed
    var tween = create_tween()
    tween.tween_property(self, "position", end_point, duration).set_trans(Tween.TRANS_LINEAR)
    tween.tween_callback(Callable(self, "_on_hit"))


func _on_hit():
    impact_spawner.spawn_impact_effect(end_point, normal)
    queue_free()