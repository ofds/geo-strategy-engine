shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

// --- Uniforms ---
uniform vec4 grid_color : source_color = vec4(0.0, 0.0, 0.0, 0.5); // Dark gray, 50% opacity
uniform vec4 highlight_color : source_color = vec4(1.0, 1.0, 1.0, 0.2); // White, 20% opacity
uniform float hex_size = 1000.0; 
uniform float line_width = 30.0; // World space width
uniform float altitude = 1000.0; // Camera altitude
uniform float fade_start = 5000.0;
uniform float fade_end = 20000.0;
uniform vec2 hovered_hex_center = vec2(0.0, 0.0); // World XZ center of hovered hex
uniform bool show_grid = true;

// --- Varyings ---
varying vec3 v_world_pos;

// --- Constants ---
const float SQRT_3 = 1.73205080757;

// --- Functions ---

// Convert world position to axial coordinates (q, r) for flat-top hexes
// Size is the distance from center to corner.
// Input 'width' is flat-to-flat distance = sqrt(3) * size
vec2 world_to_axial(vec2 pos, float width) {
    float size = width / SQRT_3;
    float q = (2.0/3.0 * pos.x) / size;
    float r = (-1.0/3.0 * pos.x + SQRT_3/3.0 * pos.y) / size;
    return vec2(q, r);
}

// Round axial coordinates to nearest hex
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

// Convert axial coordinates to world position (center of hex)
vec2 axial_to_world(vec2 axial, float width) {
    float size = width / SQRT_3;
    float x = size * (3.0/2.0 * axial.x);
    float y = size * (SQRT_3/2.0 * axial.x + SQRT_3 * axial.y);
    return vec2(x, y);
}

// Distance from point p to line segment ab
float dist_to_segment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

float hex_dist(vec2 p, float width) {
    // Size (center to corner)
    float size = width / SQRT_3;
    
    vec2 q = world_to_axial(p, width);
    vec2 center_axial = axial_round(q);
    vec2 center_world = axial_to_world(center_axial, width);
    
    // Vector from center to point
    vec2 d = p - center_world;
    
    float r = width * 0.5; // Apothem
    
    // Fold symmetry to first quadrant
    d = abs(d);
    
    float d1 = d.y;
    float d2 = abs(dot(d, vec2(SQRT_3/2.0, 0.5)));
    
    float dist_from_center = max(d1, d2);
    
    return r - dist_from_center; // Positive inside, negative outside
}


void vertex() {
    // Get world position
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    
    // Offset along normal to prevent z-fighting with the base terrain material
    // 5cm offset should be enough to float above without being noticeable key-art
    VERTEX += NORMAL * 0.05;
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
    // Current hex width is hex_size (uniform).
    
    // We need "distance to nearest edge".
    // Since hexes tile perfectly, we can just find which hex we are in,
    // calculate distance to its edge.
    // If that distance is < line_width / 2, we draw.
    
    // Wait, simpler: if we are near the edge of our current hex.
    float dist_inside = hex_dist(v_world_pos.xz, hex_size);
    // dist_inside is positive distance from edge to inside.
    // If dist_inside < line_width/2, we are on the line.
    
    float line_alpha = 0.0;
    float half_width = line_width * 0.5;
    
    // Smoothstep for anti-aliasing
    // 1-pixel feather?
    float feather = 1.0; // In meters, approximate
    // Use fwidth if possible, but terrain can be tricky.
    // Let's use simple smoothstep.
    
    // dist_inside goes from R (center) to 0 (edge) to negative (outside).
    // Actually my hex_dist returns R - dist_from_center.
    // So edge is at 0.
    
    if (dist_inside < half_width) {
       line_alpha = 1.0 - smoothstep(half_width - feather, half_width, dist_inside);
    }
    
    // 2. Highlight
    // Check if we are inside the hovered hex
    // We compare our current hex center with the hovered hex center.
    // But since q,r are discrete, we can just check world distance?
    // No, use axial coordinates.
    
    vec2 current_axial = axial_round(world_to_axial(v_world_pos.xz, hex_size));
    vec2 hovered_axial = axial_round(world_to_axial(hovered_hex_center, hex_size));
    
    float highlight_alpha = 0.0;
    // Check equality with epsilon for float precision
    if (abs(current_axial.x - hovered_axial.x) < 0.1 && abs(current_axial.y - hovered_axial.y) < 0.1) {
        highlight_alpha = 1.0;
    }
    
    // Combine
    vec4 final_color = vec4(0.0);
    
    // Blend line
    if (line_alpha > 0.0) {
        final_color = mix(final_color, grid_color, line_alpha);
    }
    
    // Blend highlight (additive or mix?)
    // Let's mix it in.
    if (highlight_alpha > 0.0) {
        // Overlay highlight on top of whatever is there (including grid lines)
        // Or under grid lines? Usually highlight is the fill.
        // Grid lines are on top.
        
        // Background: transparent
        // Layer 1: Highlight
        vec4 fill = highlight_color;
        
        // Layer 2: Grid
        vec4 grid = grid_color;
        grid.a *= line_alpha;
        
        // Composite: Grid over Fill
        // Result = Grid + Fill * (1 - Grid.a)
        vec3 out_rgb = grid.rgb * grid.a + fill.rgb * fill.a * (1.0 - grid.a);
        float out_a = grid.a + fill.a * (1.0 - grid.a);
        
        final_color = vec4(out_rgb / max(out_a, 0.001), out_a);
    } else {
        final_color = grid_color;
        final_color.a *= line_alpha;
    }

    if (final_color.a <= 0.01) {
        discard;
    }
    
    ALBEDO = final_color.rgb;
    ALPHA = final_color.a * alpha;
}
