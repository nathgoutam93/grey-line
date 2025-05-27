shader_type canvas_item;

uniform sampler2D mask_tex;
uniform bool      enable_fow = true;

// tweak these to control how soft your fog edge is
const float EDGE_INNER = 0.45;
const float EDGE_OUTER = 0.55;

void fragment() {
    // sample the object’s texture first
    vec4 base_col = texture(TEXTURE, UV);

    if (enable_fow) {
        // 1) straight from your viewport mask: white=visible, black=hidden
        float vis = 1.0 - texture(mask_tex, SCREEN_UV).r;

        // 2) smooth out the boundary (optional)
        float alpha = smoothstep(EDGE_INNER, EDGE_OUTER, vis);

        // 3) hard discard outside LoS
        if (alpha < 0.01) {
            discard;
        }

        // 4) fade the edges if you like (comment out if you want hard edges)
        base_col.rgb *= alpha;
        // or fade only the transparency channel:
        // base_col.a *= alpha;
    }

    COLOR = base_col;
}
