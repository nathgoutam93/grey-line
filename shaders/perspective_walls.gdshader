shader_type canvas_item;

// Fake top-down perspective for flat walls (see PerspectiveWalls).
// Vertices carry UV.y = height (0 at the floor, 1 at the wall top) and
// UV.x = face kind (0 roof, 1..4 side facing +x, -x, +y, -y).
// A top vertex is pushed away from the camera centre by
//   (p - c) * h / (H - h)
// which is where a point at height h projects for an eye at height H.

uniform vec2 camera_center; // in this node's local space
uniform float height_factor = 0.06; // h / (H - h)

const vec2 NORMALS[5] = vec2[](vec2(0.0), vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0));

void vertex() {
	int kind = int(round(UV.x));
	float height = UV.y;
	vec2 offset = (VERTEX - camera_center) * height_factor;
	if (kind > 0) {
		// A side faces the camera only if the camera is on its outward side;
		// back faces collapse to their floor edge, under the roof.
		vec2 normal = NORMALS[kind];
		if (dot(camera_center - VERTEX, normal) <= 0.0) {
			offset = vec2(0.0);
		}
	}
	VERTEX += offset * height;
}
