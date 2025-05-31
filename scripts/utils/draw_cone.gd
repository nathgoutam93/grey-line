extends Node

@export var size_in_pixel := 1024 * 3
@export var angle_in_deg := 110
@export var color = Color(1, 1, 1, 1) # Solid white

func _ready():
	var width = size_in_pixel
	var height = size_in_pixel
	var image = Image.create(width, height, false, Image.FORMAT_RGBA8)

	var center = Vector2(width / 2, height / 2)
	var radius = min(width, height) / 2 - 2
	var start_angle = deg_to_rad(round(angle_in_deg / 2) * -1)
	var end_angle = deg_to_rad(round(angle_in_deg / 2))

	for y in range(height):
		for x in range(width):
			var pos = Vector2(x, y)
			var dir = pos - center
			var dist = dir.length()
			if dist > radius or dist == 0:
				continue

			var angle = atan2(dir.y, dir.x)
			if angle >= start_angle and angle <= end_angle:
				image.set_pixel(x, y, color)

	# Save as PNG
	image.save_png("res://cone_image.png")

	# Optional: Convert to ImageTexture if needed
	var texture = ImageTexture.create_from_image(image)
	print("Saved to res://cone_image.png")
