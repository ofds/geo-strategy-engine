shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, depth_test_disabled;

// --- Uniforms ---
uniform vec4 grid_color : source_color = vec4(0.0, 0.0, 0.0, 0.5); // Dark gray, 50% opacity
uniform vec4 highlight_color : source_color = vec4(1.0, 1.0, 1.0, 0.2); // White, 20% opacity
uniform float hex_size = 1000.0; 
uniform float line_width = 30.0; // World space width
uniform float altitude = 1000.0; // Camera altitude
uniform float fade_start = 5000.0;
uniform float fade_end = 500000.0; // Increased to 500km
uniform vec2 hovered_hex_center = vec2(0.0, 0.0); // World XZ center of hovered hex
uniform vec2 selected_hex_center = vec2(999999.0, 999999.0); // Select hex center
uniform bool show_grid = true;

// --- Varyings ---
varying vec3 v_world_pos;
varying float v_is_selected; // 1.0 if vertex is inside selected hex, 0.0 otherwise

// --- Constants ---
const float SQRT_3 = 1.73205080757;

// --- Functions ---
vec2 world_to_axial(vec2 pos, float width) {
    float size = width / SQRT_3;
    float q = (2.0/3.0 * pos.x) / size;
    float r = (-1.0/3.0 * pos.x + SQRT_3/3.0 * pos.y) / size;
    return vec2(q, r);
}

vec3 cube_round(vec3 cube) {
    float rx = round(cube.x);
    float ry = round(cube.y);
    float rz = round(cube.z);

    float x_diff = abs(rx - cube.x);
    float y_diff = abs(ry - cube.y);
    float z_diff = abs(rz - cube.z);

    if (x_diff > y_diff && x_diff > z_diff) {
        rx = -ry - rz;
    } else if (y_diff > z_diff) {
        ry = -rx - rz;
    } else {
        rz = -rx - ry;
    }
    return vec3(rx, ry, rz);
}

vec2 axial_round(vec2 axial) {
    return cube_round(vec3(axial.x, axial.y, -axial.x - axial.y)).xy;
}

vec2 axial_to_world(vec2 axial, float width) {
    float size = width / SQRT_3;
    float x = size * (3.0/2.0 * axial.x);
    float y = size * (SQRT_3/2.0 * axial.x + SQRT_3 * axial.y);
    return vec2(x, y);
}

float hex_dist(vec2 p, float width) {
    float size = width / SQRT_3;
    vec2 q = world_to_axial(p, width);
    vec2 center_axial = axial_round(q);
    vec2 center_world = axial_to_world(center_axial, width);
    vec2 d = p - center_world;
    float r = width * 0.5; // Apothem
    d = abs(d);
    float d1 = d.y;
    float d2 = abs(dot(d, vec2(SQRT_3/2.0, 0.5)));
    float dist_from_center = max(d1, d2);
    return r - dist_from_center; // Distance from edge (positive inside)
}

void vertex() {
    // Pass world position to fragment shader
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    
    // Check selection
    v_is_selected = 0.0;
    
    vec2 pos_axial = world_to_axial(v_world_pos.xz, hex_size);
    vec2 pos_center_axial = axial_round(pos_axial);
    vec2 sel_center_axial = axial_round(world_to_axial(selected_hex_center, hex_size));
    
    // Check equality
    if (abs(pos_center_axial.x - sel_center_axial.x) < 0.1 && abs(pos_center_axial.y - sel_center_axial.y) < 0.1) {
        v_is_selected = 1.0;
        VERTEX.y += 50.0; 
    }

    // Offset along normal to prevent z-fighting with the base terrain material
    // Increased to 2.0m to ensure visibility over large distances/Z-buffer precision
    VERTEX += NORMAL * 2.0; 
}

void fragment() {
    if (!show_grid) {
        discard;
    }
    
    // Calculate global fade
    float alpha = 1.0;
    if (altitude > fade_end) {
        discard;
    } else if (altitude > fade_start) {
        alpha = 1.0 - (altitude - fade_start) / (fade_end - fade_start);
    }
    
    // 1. Grid Lines
    float dist_from_edge = hex_dist(v_world_pos.xz, hex_size);
    float half_width = line_width * 0.5;
    float line_alpha = 0.0;
    float feather = 1.0;
    
    if (dist_from_edge < half_width) {
       line_alpha = 1.0 - smoothstep(half_width - feather, half_width, dist_from_edge);
    }
    
    // 2. Highlight & Selection
    vec4 fill = vec4(0.0);
    
    // Selection
    if (v_is_selected > 0.5) {
        fill = vec4(1.0, 0.8, 0.2, 0.3); // Golden
    }

    // Hover
    vec2 current_axial = axial_round(world_to_axial(v_world_pos.xz, hex_size));
    vec2 hovered_axial = axial_round(world_to_axial(hovered_hex_center, hex_size));
    bool is_hovered = (abs(current_axial.x - hovered_axial.x) < 0.1 && abs(current_axial.y - hovered_axial.y) < 0.1);
    
    if (is_hovered) {
         vec4 hover_col = highlight_color;
         vec3 out_rgb = hover_col.rgb * hover_col.a + fill.rgb * fill.a * (1.0 - hover_col.a);
         float out_a = hover_col.a + fill.a * (1.0 - hover_col.a);
         fill = vec4(out_rgb / max(out_a, 0.001), out_a);
    }
    
    // Final Composite
    if (fill.a > 0.0 || line_alpha > 0.0) {
        vec4 grid = grid_color;
        grid.a *= line_alpha;
        
        vec3 out_rgb = grid.rgb * grid.a + fill.rgb * fill.a * (1.0 - grid.a);
        float out_a = grid.a + fill.a * (1.0 - grid.a);
        
        ALBEDO = out_rgb;
        ALPHA = out_a * alpha;
    } else {
        discard;
    }
}
