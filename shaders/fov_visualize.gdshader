shader_type canvas_item;

void fragment() {
    float brightness = (COLOR.r + COLOR.g + COLOR.b) / 3.0;

    if (brightness < 0.5) {
		discard;
    } else {
        COLOR =  vec4(0, 0, 0, 0.4);
	}
}
