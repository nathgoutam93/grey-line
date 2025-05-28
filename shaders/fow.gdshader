shader_type canvas_item;

uniform sampler2D mask_tex;
uniform bool enable_fow = true;
uniform bool enable_outline = false;

uniform vec4 outline_color = vec4(1.0, 0.0, 0.0, 1.0);
const float EDGE_INNER = 0.45;
const float EDGE_OUTER = 0.55;
const float OUTLINE_WIDTH = 4.0 / 512.0;
const float OUTLINE_THRESHOLD = 0.05; // more sensitive

const float shimmer_speed = 2.0;   // how fast it pulses
const float shimmer_strength = 0.3; // how strong the shimmer is (0 = none, 1 = strong)

void fragment() {
    vec4 base_col = texture(TEXTURE, UV);

    float vis = 1.0;
    float alpha = 1.0;

    if (enable_fow) {
        vis = 1.0 - texture(mask_tex, SCREEN_UV).r;
        alpha = smoothstep(EDGE_INNER, EDGE_OUTER, vis);
        if (alpha < 0.01) discard;
    }

    vec4 final_color = base_col;

    if (enable_outline && alpha > 0.01) {
        // Sample neighboring alpha values from the object texture
        float center_alpha = texture(TEXTURE, UV).a;
        float left_alpha   = texture(TEXTURE, UV + vec2(-OUTLINE_WIDTH, 0.0)).a;
        float right_alpha  = texture(TEXTURE, UV + vec2( OUTLINE_WIDTH, 0.0)).a;
        float up_alpha     = texture(TEXTURE, UV + vec2(0.0, -OUTLINE_WIDTH)).a;
        float down_alpha   = texture(TEXTURE, UV + vec2(0.0,  OUTLINE_WIDTH)).a;

		float shimmer = 1.0 - shimmer_strength * 0.5 + sin(TIME * shimmer_speed) * (shimmer_strength * 0.5);

        float edge = 0.0;
        edge += step(OUTLINE_THRESHOLD, center_alpha - left_alpha);
        edge += step(OUTLINE_THRESHOLD, center_alpha - right_alpha);
        edge += step(OUTLINE_THRESHOLD, center_alpha - up_alpha);
        edge += step(OUTLINE_THRESHOLD, center_alpha - down_alpha);
        edge = clamp(edge, 0.0, 1.0);

        final_color.rgb += outline_color.rgb * edge * outline_color.a * shimmer;
    }

    // apply fog alpha at the end
    final_color.rgb *= alpha;
    COLOR = final_color;
}
