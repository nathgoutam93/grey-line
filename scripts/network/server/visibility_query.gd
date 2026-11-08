extends RefCounted
class_name VisibilityQuery

## Server-side approximation of the client fog of war, used to decide which
## players each peer is told about (see WorldSnapshotService).
##
## The client draws vision as the LOS PointLight2D in FowMaskView: the
## 110_deg_cone.png texture (3072 px, texture_scale 1 -> 1536 px reach) aimed
## along the player's rotation, shadowed by the map's walls and smoke clouds.
## These checks are deliberately a little looser than that (margins below) so
## the server never hides something the client would draw.

const VISION_RANGE := 1536.0
const VISION_RANGE_MARGIN := 96.0
const VISION_HALF_ANGLE_DEG := 55.0
## Covers the server seeing the viewer's aim slightly later than the client.
const VISION_ANGLE_MARGIN_DEG := 20.0
## Inside this distance facing is ignored (walls/smoke still apply), so fast
## turns toward a nearby enemy never pop in late.
const CLOSE_RANGE := 180.0
## Rays go to the target's centre and both shoulders so partial peeks count.
const BODY_PROBE_OFFSET := 18.0
const ENVIRONMENT_MASK := 1 << 0

static func can_see(viewer: PlayerController, target: PlayerController, smoke_blockers: Array) -> bool:
	var from := viewer.global_position
	var to := target.global_position
	var offset := to - from
	var distance := offset.length()
	if distance > VISION_RANGE + VISION_RANGE_MARGIN:
		return false
	if distance > CLOSE_RANGE:
		var facing := Vector2.RIGHT.rotated(viewer.rotation)
		if absf(rad_to_deg(facing.angle_to(offset))) > VISION_HALF_ANGLE_DEG + VISION_ANGLE_MARGIN_DEG:
			return false
	var space := viewer.get_world_2d().direct_space_state
	var side := Vector2.ZERO
	if distance > 0.001:
		side = offset.orthogonal().normalized() * BODY_PROBE_OFFSET
	var exclude: Array[RID] = [viewer.get_rid(), target.get_rid()]
	for probe in [to, to + side, to - side]:
		if _segment_clear(space, from, probe, exclude, smoke_blockers):
			return true
	return false

## True when `source` is currently making a sound that reaches `listener`.
static func can_hear(listener: PlayerController, source: PlayerController) -> bool:
	var radius := source.get_noise_radius()
	if radius <= 0.0:
		return false
	return listener.global_position.distance_squared_to(source.global_position) <= radius * radius

## Active smoke clouds as [center: Vector2, radius: float] pairs.
static func collect_smoke_blockers(tree: SceneTree) -> Array:
	var blockers: Array = []
	for node in tree.get_nodes_in_group(SmokeCloud.VISION_BLOCKER_GROUP):
		var cloud := node as SmokeCloud
		if cloud == null or not cloud.is_inside_tree():
			continue
		var radius := cloud.get_vision_block_radius()
		if radius > 0.0:
			blockers.append([cloud.global_position, radius])
	return blockers

static func _segment_clear(space: PhysicsDirectSpaceState2D, from: Vector2, to: Vector2, exclude: Array[RID], smoke_blockers: Array) -> bool:
	for blocker in smoke_blockers:
		var center: Vector2 = blocker[0]
		var radius: float = blocker[1]
		if Geometry2D.get_closest_point_to_segment(center, from, to).distance_to(center) < radius:
			return false
	var query := PhysicsRayQueryParameters2D.create(from, to, ENVIRONMENT_MASK, exclude)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return space.intersect_ray(query).is_empty()
