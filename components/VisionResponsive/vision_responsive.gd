extends Node

@export var threshold: float = 0.95

@onready var fog_texture: Texture2D = get_tree().current_scene.get_node("MaskView").get_texture()

func _ready():
    if not fog_texture:
        push_warning("fog_texture not found")


    if get_parent() is CanvasItem:
        var mat = preload("res://materials/vision_responsive.tres").duplicate()
        mat.set_shader_parameter("fog_mask", fog_texture)
        mat.set_shader_parameter("screen_size", get_viewport().size)
        get_parent().material = mat
