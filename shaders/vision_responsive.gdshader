shader_type canvas_item;

uniform sampler2D fog_mask;
uniform vec2 screen_size;

void fragment() {
    vec2 screen_uv = SCREEN_UV;
    float visibility = texture(fog_mask, screen_uv).r;

    if (visibility > 0.95) {
        discard;
    }

    COLOR = texture(TEXTURE, UV);
}
