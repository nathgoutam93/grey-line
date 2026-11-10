extends Resource
class_name PerspectiveProfile

## How a PerspectiveSprite lifts its parent Sprite2D. Adding a new prop type
## is a new profile (data), not new code.

enum Kind {
	## Extrude the sprite's rectangle (minus `inset`) to `height`; the sprite
	## becomes the roof. For crates, containers, doors and other boxes.
	BOX,
	## Repeat the sprite at `layers` heights up to `height`, darker towards the
	## floor: extrudes its silhouette. For rounded shapes such as vehicles.
	STACK,
	## Draw the frames of `slice_strip` (cross-sections side by side, lowest
	## first, each the sprite's size) spread evenly up to `height`. For art
	## rendered from Blender or exported from a voxel editor in slices.
	SLICES,
}

@export var kind := Kind.BOX
## World px above the floor (independent of the sprite's scale).
@export var height := 32.0
## BOX: shrink the footprint by this many sprite px per side (art margins).
@export var inset := Vector2.ZERO
## BOX: side face colour. Fully transparent = average of the sprite's pixels.
@export var side_color := Color(0, 0, 0, 0)
## STACK: number of copies of the sprite.
@export_range(2, 32) var layers := 8
## STACK / SLICES: brightness of the lowest layer (the top one is 1).
@export_range(0.0, 1.0) var base_brightness := 0.45
## SLICES: horizontal strip of cross-sections, lowest first.
@export var slice_strip: Texture2D
@export_range(2, 64) var slice_count := 8
