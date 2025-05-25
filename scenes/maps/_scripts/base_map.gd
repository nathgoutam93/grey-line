extends Node2D


@onready var player_camera = $Player/Camera2D

@onready var fov_viewport := $FieldOfView
@onready var mask_viewport := $MaskView

@onready var fov_render: Sprite2D = $FovRenderView
@onready var fog_render: Sprite2D = $FogOfWar

func _ready() -> void:
	mask_viewport.main_camera = player_camera;
	fov_viewport.main_camera = player_camera;

	# fov_viewport.world_2d = get_world_2d()

	
func _process(_delta: float) -> void:
	fov_render.offset = player_camera.global_position
	fog_render.offset = player_camera.global_position
