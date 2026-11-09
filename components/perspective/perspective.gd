extends RefCounted
class_name Perspective

## Shared settings for the fake top-down perspective (shaders/perspective.gdshader).
## Every lifted visual (PerspectiveWalls, PerspectiveSprite) uses one shared
## material and reads the camera centre from a global shader uniform, so the
## camera is set once per frame no matter how many props are on screen.
## Purely visual: gameplay, sight, hearing and the fog mirror stay flat.

const SHADER := preload("res://shaders/perspective.gdshader")
const CAMERA_GLOBAL := &"perspective_camera"
const EYE_HEIGHT_GLOBAL := &"perspective_eye_height"
## World px. A point at height h leans h / (EYE_HEIGHT - h) of its distance
## from the screen centre. Also the default in project.godot [shader_globals].
const EYE_HEIGHT := 700.0
const WALL_HEIGHT := 40.0
## Draw lifted visuals above players (a face can hide someone behind it);
## taller things draw over shorter ones they lean across.
const Z_BASE := 20
const Z_PER_HEIGHT := 1.0 / 8.0
## Light from the top-left: faces turned towards it are brighter.
const LIGHT_DIR := Vector2(-0.6, -0.8)
const SHADE_LIT := 0.88
const SHADE_DARK := 0.5
## Side faces darken towards the floor (fake ambient occlusion).
const FLOOR_SHADE := 0.55

static var _material: ShaderMaterial
static var _synced_frame := -1

static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
	return _material

static func z_for_height(height: float) -> int:
	return Z_BASE + int(round(height * Z_PER_HEIGHT))

## Brightness of a side face with this outward normal.
static func face_shade(normal: Vector2) -> float:
	var facing := normal.normalized().dot(LIGHT_DIR.normalized()) * 0.5 + 0.5
	return lerpf(SHADE_DARK, SHADE_LIT, facing)

static func is_enabled() -> bool:
	return DisplayServer.get_name() != "headless"

## Publishes the active camera's screen centre (world space) once per frame.
static func sync_camera(node: Node) -> void:
	var frame := Engine.get_process_frames()
	if frame == _synced_frame or not node.is_inside_tree():
		return
	var camera := node.get_viewport().get_camera_2d()
	if camera == null:
		return
	_synced_frame = frame
	RenderingServer.global_shader_parameter_set(CAMERA_GLOBAL, camera.get_screen_center_position())
