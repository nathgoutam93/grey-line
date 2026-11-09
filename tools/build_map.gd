extends SceneTree

func _initialize() -> void:
	_build.call_deferred()

func _build() -> void:
	var builder: Script = load("res://tools/map_builder.gd")
	var layout := ""
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--layout="):
			layout = arg.trim_prefix("--layout=")
		elif arg.begins_with("--out="):
			output = arg.trim_prefix("--out=")
	if layout.is_empty() or output.is_empty() or not FileAccess.file_exists(layout):
		printerr("Usage: --layout=<existing layout.txt> --out=<map.tscn>")
		quit(1)
		return
	var data: Dictionary = builder.parse(FileAccess.get_file_as_string(layout))
	if not String(data.error).is_empty():
		printerr("Map generation failed: " + data.error)
		quit(1)
		return
	for warning in data.warnings:
		push_warning(warning)
	var world: Node2D = builder.build(data, layout)
	var error: Error = builder.save(world, output)
	world.free()
	if error != OK:
		printerr("Could not save map: " + error_string(error))
		quit(1)
		return
	print("Generated %s (%dx%d cells, %d walls, %d doors)" % [output, data.size.x, data.size.y, data.walls.size(), data.doors.size()])
	quit(0)
