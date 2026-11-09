extends SceneTree

const OUTPUT := "res://resources/destruction/destructible_walls_tileset.tres"
const ATLAS := "res://resources/destruction/walls_atlas.png"
const TILESET_UID := 7129384501200941

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://resources/destruction")
	var image := Image.create(48, 16, false, Image.FORMAT_RGBA8)
	var colors := [Color("#b8b6ab"), Color("#535c64"), Color("#20252a")]
	for index in range(3):
		image.fill_rect(Rect2i(index * 16, 0, 16, 16), colors[index])
	if image.save_png(ATLAS) != OK:
		quit(1)
		return
	var texture := ImageTexture.create_from_image(image)
	texture.resource_path = ATLAS
	var tiles := TileSet.new()
	tiles.tile_size = Vector2i(16, 16)
	tiles.add_physics_layer()
	tiles.set_physics_layer_collision_layer(0, 1)
	tiles.set_physics_layer_collision_mask(0, 0)
	tiles.add_occlusion_layer()
	tiles.add_custom_data_layer()
	tiles.set_custom_data_layer_name(0, "material")
	tiles.set_custom_data_layer_type(0, TYPE_INT)
	tiles.add_custom_data_layer()
	tiles.set_custom_data_layer_name(1, "max_hp")
	tiles.set_custom_data_layer_type(1, TYPE_INT)
	var atlas := TileSetAtlasSource.new()
	atlas.resource_scene_unique_id = "WallsAtlas"
	atlas.texture = texture
	atlas.texture_region_size = Vector2i(16, 16)
	tiles.add_source(atlas, 0)
	var polygon := PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)])
	for index in range(3):
		var coords := Vector2i(index, 0)
		atlas.create_tile(coords)
		var data := atlas.get_tile_data(coords, 0)
		data.set_collision_polygons_count(0, 1)
		data.set_collision_polygon_points(0, 0, polygon)
		var occluder := OccluderPolygon2D.new()
		occluder.resource_scene_unique_id = "WallOccluder%d" % index
		occluder.polygon = polygon
		data.set_occluder(0, occluder)
		data.set_custom_data("material", index)
		data.set_custom_data("max_hp", [40, 150, 0][index])
	if ResourceSaver.save(tiles, OUTPUT) != OK or ResourceSaver.set_uid(OUTPUT, TILESET_UID) != OK:
		quit(1)
		return
	print("Generated %s and %s" % [OUTPUT, ATLAS])
	quit(0)
