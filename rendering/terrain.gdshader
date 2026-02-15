shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// --- Uniforms ---
// Terrain
uniform vec3 albedo : source_color = vec3(0.3, 0.5, 0.2); // Base green
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float rim : hint_range(0.0, 1.0) = 0.2;
uniform float rim_tint : hint_range(0.0, 1.0) = 0.5;

// Hex Grid
uniform vec4 grid_color : source_color = vec4(0.0, 0.0, 0.0, 0.5);
uniform vec4 highlight_color : source_color = vec4(1.0, 1.0, 1.0, 0.3); // White, 30% opacity
uniform float hex_size = 1000.0;
uniform float line_width = 30.0;
uniform bool show_grid = true;

// Interaction
uniform vec2 hovered_hex_center = vec2(0.0, 0.0);
uniform vec2 selected_hex_center = vec2(999999.0, 999999.0);
uniform float altitude = 1000.0;

// Fade
uniform float fade_start = 5000.0;
uniform float fade_end = 500000.0;

// Fog
uniform vec3 camera_position = vec3(0.0, 0.0, 0.0);

// --- Varyings ---
varying vec3 v_world_pos;
varying float v_is_selected; // 1.0 if inside selection
varying vec3 v_view_dir; // For rim lighting calculation in fragment
varying float v_elevation;
varying vec3 v_world_normal;

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

// Height-based terrain colors (Alps: ~89m to ~4797m)
const float TRANSITION_M = 200.0;
const vec3 COLOR_LOWLAND = vec3(0.18, 0.32, 0.12);   // <300m deep green
const vec3 COLOR_FOOTHILLS = vec3(0.25, 0.42, 0.15); // 300-800m
const vec3 COLOR_ALPINE = vec3(0.35, 0.48, 0.18);    // 800-1500m
const vec3 COLOR_ROCK = vec3(0.45, 0.38, 0.30);      // 1500-2200m
const vec3 COLOR_HIGH_ROCK = vec3(0.62, 0.60, 0.58); // 2200-3000m
const vec3 COLOR_SNOW = vec3(0.92, 0.93, 0.95);      // >3000m
const vec3 COLOR_STEEP_ROCK = vec3(0.40, 0.35, 0.28); // Steep slope override

vec3 terrain_height_color(float elev) {
    float t300 = smoothstep(300.0 - TRANSITION_M, 300.0 + TRANSITION_M, elev);
    float t800 = smoothstep(800.0 - TRANSITION_M, 800.0 + TRANSITION_M, elev);
    float t1500 = smoothstep(1500.0 - TRANSITION_M, 1500.0 + TRANSITION_M, elev);
    float t2200 = smoothstep(2200.0 - TRANSITION_M, 2200.0 + TRANSITION_M, elev);
    float t3000 = smoothstep(3000.0 - TRANSITION_M, 3000.0 + TRANSITION_M, elev);
    vec3 c = mix(COLOR_LOWLAND, COLOR_FOOTHILLS, t300);
    c = mix(c, COLOR_ALPINE, t800);
    c = mix(c, COLOR_ROCK, t1500);
    c = mix(c, COLOR_HIGH_ROCK, t2200);
    c = mix(c, COLOR_SNOW, t3000);
    return c;
}

void vertex() {
    // 1. Calculate World Position (before selection lift - for elevation coloring)
    vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
    v_world_pos = world_pos.xyz;
    v_elevation = world_pos.y;
    v_world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
    
    // 2. Determine Selection
    v_is_selected = 0.0;
    
    vec2 pos_axial = world_to_axial(v_world_pos.xz, hex_size);
    vec2 pos_center_axial = axial_round(pos_axial);
    vec2 sel_center_axial = axial_round(world_to_axial(selected_hex_center, hex_size));
    
    // Check if this vertex belongs to the selected hex
    if (abs(pos_center_axial.x - sel_center_axial.x) < 0.1 && abs(pos_center_axial.y - sel_center_axial.y) < 0.1) {
        v_is_selected = 1.0;
        
        // --- ABDUCTION EFFECT ---
        // Lift the vertex using a sine wave animation or smooth curve
        // For now, simple lift
        VERTEX.y += 300.0; // Raise 300m
        
        // Optional: Add some noise to the lift based on position to make it look like tearing?
        // VERTEX.y += sin(VERTEX.x * 0.05) * 20.0;
    }
}

void fragment() {
    // 1. Base terrain color from elevation and slope
    vec3 n = normalize(v_world_normal);
    float slope = 1.0 - n.y; // 0 = flat, 1 = vertical
    vec3 height_col = terrain_height_color(v_elevation);
    vec3 steep_col = COLOR_STEEP_ROCK;
    // Steep override: normal.y < 0.7 (~45°), blend over 200m transition in slope
    float steep_mix = smoothstep(0.7, 0.5, n.y);
    vec3 base_col = mix(height_col, steep_col, steep_mix);
    
    // 2. Distance fog (50km start, 200km full)
    vec3 fog_color = vec3(0.75, 0.82, 0.90);
    float dist = length(v_world_pos - camera_position);
    float fog_factor = smoothstep(50000.0, 200000.0, dist);
    base_col = mix(base_col, fog_color, fog_factor);
    
    // 3. Grid Logic
    float line_alpha = 0.0;
    vec4 highlight_fill = vec4(0.0);
    
    // Calculate global fade based on altitude
    float grid_fade_alpha = 1.0;
    if (altitude > fade_end) {
        grid_fade_alpha = 0.0;
    } else if (altitude > fade_start) {
        grid_fade_alpha = 1.0 - (altitude - fade_start) / (fade_end - fade_start);
    }
    
    if (show_grid && grid_fade_alpha > 0.0) {
        float dist_from_edge = hex_dist(v_world_pos.xz, hex_size);
        float half_width = line_width * 0.5;
        
        // Grid Lines
        if (dist_from_edge < half_width) {
            line_alpha = (1.0 - smoothstep(half_width - 2.0, half_width, dist_from_edge)) * grid_fade_alpha;
        }
        
        // Selection Glow
        if (v_is_selected > 0.5) {
             // Golden glow for selected lifted hex
             highlight_fill = vec4(1.0, 0.8, 0.2, 0.4);
             
             // Add rim effect to the lifted hex edges
             float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
             highlight_fill.rgb += vec3(0.5, 0.4, 0.1) * fresnel;
        }
        
        // Hover Highlight
        vec2 current_axial = axial_round(world_to_axial(v_world_pos.xz, hex_size));
        vec2 hovered_axial = axial_round(world_to_axial(hovered_hex_center, hex_size));
        if (abs(current_axial.x - hovered_axial.x) < 0.1 && abs(current_axial.y - hovered_axial.y) < 0.1) {
             // Blend hover color
             vec4 hover_col = highlight_color;
             vec3 out_rgb = hover_col.rgb * hover_col.a + highlight_fill.rgb * highlight_fill.a * (1.0 - hover_col.a);
             float out_a = hover_col.a + highlight_fill.a * (1.0 - hover_col.a);
             highlight_fill = vec4(out_rgb / max(out_a, 0.001), out_a);
        }
    }
    
    // 4. Composite
    // Start with base terrain (already colored + fogged)
    vec3 final_albedo = base_col;
    
    // Apply Grid Lines
    if (line_alpha > 0.0) {
        final_albedo = mix(final_albedo, grid_color.rgb, grid_color.a * line_alpha);
    }
    
    // Apply Highlights (Selection / Hover)
    if (highlight_fill.a > 0.0) {
        final_albedo = mix(final_albedo, highlight_fill.rgb, highlight_fill.a);
    }
    
    ALBEDO = final_albedo;
    ROUGHNESS = roughness;
    METALLIC = metallic;
    RIM = rim;
    RIM_TINT = rim_tint;
}
