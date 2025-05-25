extends Node2D


@onready var mask_viewport := get_tree().get_current_scene().get_node_or_null("MaskView")

func _ready():
	if mask_viewport:
		var mask_tex = mask_viewport.get_texture()
		var mask_size = mask_viewport.size

		var mat = get_parent().material as ShaderMaterial
		if mat:
			mat.set_shader_parameter("mask_tex", mask_tex)
			mat.set_shader_parameter("mask_size", mask_size)
