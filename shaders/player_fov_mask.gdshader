shader_type canvas_item;

uniform sampler2D visibility_mask;

void fragment() {
    vec4 mask = texture(visibility_mask, UV);
    if (mask.r > 0.5) {
        discard;
    }
    COLOR = texture(TEXTURE, UV);
}
