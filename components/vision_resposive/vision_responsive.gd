extends Node2D

func _ready():
	var viewport = MaskViewProvider.viewport
		
	if not viewport:
		return

	var mask_tex = viewport.get_texture()
	var mask_size = viewport.size

	var mat = get_parent().material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("mask_tex", mask_tex)
		mat.set_shader_parameter("mask_size", mask_size)
