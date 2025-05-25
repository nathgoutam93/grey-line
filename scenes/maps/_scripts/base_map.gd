extends Node2D

@onready var player_camera = $Player/Camera2D

@onready var mask_viewport := $MaskView
# @onready var fov_viewport := $FieldOfView

func _ready() -> void:
# 	# var root_world = get_viewport().world_2d
# 	# fov_viewport.world_2d = root_world
	mask_viewport.main_camera = player_camera
# 	fov_viewport.main_camera = player_camera
	
# func _process(_delta: float) -> void:
# 	pass
