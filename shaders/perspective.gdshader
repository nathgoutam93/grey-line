shader_type canvas_item;

// Fake top-down perspective for anything built by HeightMeshBuilder (walls,
// doors, crates, vehicles). Each vertex stores its floor position in VERTEX
// and in CUSTOM0:
//   x = height above the floor in world px
//   yz = outward face normal in local space (zero for roofs and layers)
//   w = 1 to sample TEXTURE at UV, 0 for a flat vertex colour
// A point at height h is drawn (p - c) * h / (H - h) further from the camera
// centre c, which is where it projects for an eye at height H. Side faces
// whose outward normal points away from the camera collapse to the floor,
// under the roof. Perspective.sync_camera() sets the globals once per frame.

global uniform vec2 perspective_camera; // world space
global uniform float perspective_eye_height;

varying float textured;
varying vec4 tint; // vertex colour without the default texture multiply

void vertex() {
	float height = CUSTOM0.x;
	vec2 world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	mat2 basis = mat2(MODEL_MATRIX[0].xy, MODEL_MATRIX[1].xy);
	vec2 offset = (world - perspective_camera) * (height / max(perspective_eye_height - height, 1.0));
	mat2 to_local = inverse(basis);
	vec2 normal = transpose(to_local) * CUSTOM0.yz; // world-space normal, also under non-uniform scale
	if (dot(normal, normal) > 0.0 && dot(perspective_camera - world, normal) <= 0.0) {
		offset = vec2(0.0);
	}
	VERTEX += to_local * offset;
	textured = CUSTOM0.w;
	tint = COLOR;
}

void fragment() {
	COLOR = textured > 0.5 ? texture(TEXTURE, UV) * tint : tint;
}
