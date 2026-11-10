extends Node

## Renders cqc_1 from a few camera positions with flat and perspective walls
## and props. Run with a window (not --headless):
##   godot --path . res://tools/capture_perspective.tscn -- --ephemeral-profile --out=/tmp/walls

const MAP := "res://scenes/maps/cqc_1/cqc_1.tscn"
const CHARACTER := "res://components/skeletal_mesh/character_skeletal.tscn"
const SHOTS := [["west-rooms", Vector2(1000, 760)], ["junction", Vector2(1780, 1080)], ["objective", Vector2(2720, 1060)], ["south-rooms", Vector2(1000, 1500)]]

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var out := "/tmp/perspective-walls"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out)
	var world := (load(MAP) as PackedScene).instantiate() as Node2D
	get_tree().root.add_child(world)
	var fog := world.get_node_or_null("CanvasLayer") as CanvasLayer
	if fog != null:
		fog.visible = false
	var map := world.get_node("Map") as Node2D
	var door := map_door(world)
	if door != null:
		door.set_state_local(Door.State.OPEN) # an open door shows the rotated box
	var hud := world.find_child("RoundHud", true, false) as CanvasItem
	if hud != null:
		hud.hide()
	var camera := Camera2D.new()
	camera.zoom = Vector2(0.75, 0.75)
	map.add_child(camera)
	camera.make_current()
	for shot in SHOTS:
		for offset in [Vector2(-200, -60), Vector2(260, 120)]:
			var character := (load(CHARACTER) as PackedScene).instantiate() as Node2D
			character.position = shot[1] + offset
			character.z_index = 1
			character.scale = Vector2(0.35, 0.35) # as in player.tscn
			var fow := character.material as ShaderMaterial
			if fow != null:
				fow.set_shader_parameter("enable_fow", false) # no fog mask in this capture
			map.add_child(character)
	for shot in SHOTS:
		camera.global_position = shot[1]
		camera.force_update_scroll()
		var images := {}
		for mode in ["3d", "flat"]:
			_set_lifted(map, mode == "3d")
			for _i in range(4):
				await get_tree().process_frame
			RenderingServer.force_draw(false)
			images[mode] = get_tree().root.get_viewport().get_texture().get_image()
		# Side by side: flat walls left, perspective walls right.
		var flat: Image = images["flat"]
		var lifted: Image = images["3d"]
		var compare := Image.create(flat.get_width() * 2 + 8, flat.get_height(), false, flat.get_format())
		compare.fill(Color.WHITE)
		compare.blit_rect(flat, Rect2i(Vector2i.ZERO, flat.get_size()), Vector2i.ZERO)
		compare.blit_rect(lifted, Rect2i(Vector2i.ZERO, lifted.get_size()), Vector2i(flat.get_width() + 8, 0))
		var path := out.path_join("%s-compare.png" % shot[0])
		compare.save_png(path)
		print("saved ", path)
	get_tree().quit()

## Shows the perspective meshes (walls and props) or the flat originals.
func _set_lifted(map: Node, lifted: bool) -> void:
	(map.get_node("DestructibleWalls") as CanvasItem).self_modulate.a = 0.0 if lifted else 1.0
	for node in map.find_children("*", "MeshInstance2D", true, false):
		if node is PerspectiveWalls or node is PerspectiveSprite:
			(node as CanvasItem).visible = lifted
			if node is PerspectiveSprite:
				(node.get_parent() as CanvasItem).self_modulate.a = 0.0 if lifted else 1.0

func map_door(world: Node) -> Door:
	return world.get_node_or_null("Map/Doors/Door1") as Door
