extends MeshInstance2D
class_name PerspectiveSprite

## Child of a Sprite2D that draws it as a fake-3D object (see PerspectiveProfile
## and shaders/perspective.gdshader). The sprite stops drawing itself
## (self_modulate) but keeps its transform and modulate, so rotating, scaling,
## tinting or hiding the sprite or its owner (an opening door, a broken crate)
## carries over. Purely visual: collision, sight and fog stay flat.

@export var profile: PerspectiveProfile

var _sprite: Sprite2D

func _ready() -> void:
	_sprite = get_parent() as Sprite2D
	if profile == null or _sprite == null or _sprite.texture == null:
		push_warning("PerspectiveSprite needs a profile and a textured Sprite2D parent: %s" % get_path())
		return
	if not Perspective.is_enabled():
		return
	material = Perspective.material()
	z_index = Perspective.z_for_height(profile.height)
	texture = profile.slice_strip if profile.kind == PerspectiveProfile.Kind.SLICES else _sprite.texture
	if texture == null:
		push_warning("PerspectiveSprite: SLICES profile without slice_strip: %s" % get_path())
		return
	mesh = build_mesh(_sprite, profile)
	_sprite.self_modulate.a = 0.0

func _process(_delta: float) -> void:
	Perspective.sync_camera(self)

static func build_mesh(sprite: Sprite2D, profile: PerspectiveProfile) -> ArrayMesh:
	var builder := HeightMeshBuilder.new()
	var rect := sprite.get_rect()
	var uv_rect := _uv_rect(sprite)
	match profile.kind:
		PerspectiveProfile.Kind.BOX:
			var footprint := rect.grow_individual(-profile.inset.x, -profile.inset.y, -profile.inset.x, -profile.inset.y)
			var corners := PackedVector2Array([footprint.position, Vector2(footprint.end.x, footprint.position.y), footprint.end, Vector2(footprint.position.x, footprint.end.y)])
			var side := profile.side_color if profile.side_color.a > 0.0 else average_color(sprite.texture)
			builder.add_prism_sides(corners, profile.height, side)
			builder.add_layer(rect, profile.height, Color.WHITE, uv_rect)
		PerspectiveProfile.Kind.STACK:
			for i in profile.layers:
				var t := float(i) / float(profile.layers - 1)
				builder.add_layer(rect, profile.height * t, _layer_tint(profile, t), uv_rect)
		PerspectiveProfile.Kind.SLICES:
			var frame := 1.0 / float(profile.slice_count)
			for i in profile.slice_count:
				var t := float(i) / float(profile.slice_count - 1)
				builder.add_layer(rect, profile.height * t, _layer_tint(profile, t), Rect2(frame * i, 0.0, frame, 1.0))
	return builder.build()

static func _layer_tint(profile: PerspectiveProfile, t: float) -> Color:
	var brightness := lerpf(profile.base_brightness, 1.0, t)
	return Color(brightness, brightness, brightness, 1.0)

static func _uv_rect(sprite: Sprite2D) -> Rect2:
	var size := sprite.texture.get_size()
	var region := sprite.region_rect if sprite.region_enabled else Rect2(Vector2.ZERO, size)
	var frame_size := region.size / Vector2(sprite.hframes, sprite.vframes)
	var frame_origin := region.position + frame_size * Vector2(sprite.frame_coords)
	var uv := Rect2(frame_origin / size, frame_size / size)
	if sprite.flip_h:
		uv = Rect2(uv.position.x + uv.size.x, uv.position.y, -uv.size.x, uv.size.y)
	if sprite.flip_v:
		uv = Rect2(uv.position.x, uv.position.y + uv.size.y, uv.size.x, -uv.size.y)
	return uv

## Mean colour of the opaque pixels (sampled on a coarse grid).
static func average_color(texture: Texture2D) -> Color:
	var image := texture.get_image()
	if image == null:
		return Color(0.5, 0.5, 0.5)
	if image.is_compressed():
		image.decompress()
	var sum := Color(0, 0, 0, 0)
	var count := 0
	var step := maxi(1, mini(image.get_width(), image.get_height()) / 24)
	for y in range(0, image.get_height(), step):
		for x in range(0, image.get_width(), step):
			var pixel := image.get_pixel(x, y)
			if pixel.a > 0.5:
				sum += pixel
				count += 1
	if count == 0:
		return Color(0.5, 0.5, 0.5)
	var mean := sum / float(count)
	return Color(mean.r, mean.g, mean.b, 1.0)
