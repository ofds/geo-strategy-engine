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
uniform vec4 highlight_color : source_color = vec4(1.0, 1.0, 1.0, 0.08); // Hover: white, 8% opacity
uniform float hex_size = 1000.0;
uniform float line_width = 30.0;
uniform bool show_grid = true;

// Interaction
uniform vec2 hovered_hex_center = vec2(0.0, 0.0);
uniform vec2 selected_hex_center = vec2(999999.0, 999999.0);
uniform float selection_time = 0.0; // Seconds since selection; animates lift/border/tint
uniform float altitude = 1000.0;

// Fade
uniform float fade_start = 5000.0;
uniform float fade_end = 500000.0;

// Fog
uniform vec3 camera_position = vec3(0.0, 0.0, 0.0);

// --- Varyings ---
varying vec3 v_world_pos;
varying float v_is_selected; // 1.0 if inside selection
varying float v_selection_time; // Pass-through for fragment animation
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
    vec2 world_xz = world_pos.xz;
    v_world_pos = world_pos.xyz;
    v_elevation = world_pos.y;
    v_world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
    v_selection_time = selection_time;

    // 2. Hex membership: discrete — vertex is either inside selected hex or not
    vec2 pos_axial = world_to_axial(world_xz, hex_size);
    vec2 pos_rounded = axial_round(pos_axial);
    vec2 sel_axial = world_to_axial(selected_hex_center, hex_size);
    vec2 sel_rounded = axial_round(sel_axial);

    const float EPS = 0.01;
    bool in_selected = (abs(pos_rounded.x - sel_rounded.x) < EPS && abs(pos_rounded.y - sel_rounded.y) < EPS);
    v_is_selected = in_selected ? 1.0 : 0.0;

    if (in_selected) {
        // Flat plateau: full 60m in interior, steep ramp in outer 10% of radius
        vec2 center_world = axial_to_world(sel_rounded, hex_size);
        float dist_to_center = distance(world_xz, center_world);
        float hex_radius = hex_size * 0.5; // apothem (center to flat edge)
        float plateau = 60.0 * smoothstep(hex_radius * 0.9, hex_radius, dist_to_center);
        // Animate lift over 0.25s with ease-out (decelerating rise)
        float lift_raw = min(selection_time / 0.25, 1.0);
        float lift_fade = 1.0 - pow(1.0 - lift_raw, 3.0);
        VERTEX.y += plateau * lift_fade;
        // Subtle floating oscillation (±2m at 1.5Hz)
        VERTEX.y += 2.0 * sin(TIME * 1.5) * lift_fade;
    }
    // Else: zero displacement — neighbors never move
}

void fragment() {
    // 1. Base terrain color from elevation and slope
    vec3 n = normalize(v_world_normal);
    vec3 height_col = terrain_height_color(v_elevation);
    vec3 steep_col = COLOR_STEEP_ROCK;
    float steep_mix = smoothstep(0.7, 0.5, n.y);
    vec3 base_col = mix(height_col, steep_col, steep_mix);

    // 2. Selection state and staggered animation timings
    bool is_selected = (v_is_selected > 0.5);
    bool has_selection = (selected_hex_center.x < 900000.0);
    float glow_fade = has_selection ? min(v_selection_time / 0.1, 1.0) : 0.0;
    float darken_fade = has_selection ? min(v_selection_time / 0.3, 1.0) : 0.0;
    float tint_fade = has_selection ? min(v_selection_time / 0.2, 1.0) : 0.0;

    // 3. Darken surroundings when a hex is selected (before fog, so fog is not double-darkened)
    if (has_selection && !is_selected) {
        float darken = mix(1.0, 0.85, darken_fade);
        base_col *= darken;
    }

    // 4. Distance fog (50km start, 200km full)
    vec3 fog_color = vec3(0.75, 0.82, 0.90);
    float dist = length(v_world_pos - camera_position);
    float fog_factor = smoothstep(50000.0, 200000.0, dist);
    base_col = mix(base_col, fog_color, fog_factor);

    // 5. Selection tint (20% golden) — selected hex is brightest on screen
    vec3 selection_tint = vec3(1.0, 0.9, 0.5);
    if (is_selected) {
        base_col = mix(base_col, selection_tint, 0.20 * tint_fade);
    }

    // 6. Hover: thin white border (30m), 8% tint — only when not selected
    float dist_from_edge = hex_dist(v_world_pos.xz, hex_size);
    vec2 current_axial = axial_round(world_to_axial(v_world_pos.xz, hex_size));
    vec2 hovered_axial = axial_round(world_to_axial(hovered_hex_center, hex_size));
    const float AXIAL_EPS = 0.01;
    bool is_hovered = (abs(current_axial.x - hovered_axial.x) < AXIAL_EPS && abs(current_axial.y - hovered_axial.y) < AXIAL_EPS);
    float hover_line_alpha = 0.0;
    float hover_fill_alpha = 0.08;
    if (is_hovered && !is_selected) {
        float half_width = line_width * 0.5;
        if (dist_from_edge < half_width) {
            hover_line_alpha = (1.0 - smoothstep(half_width - 2.0, half_width, dist_from_edge));
        }
    }

    // 7. Edge glow (emissive golden border at selected hex) — visible with grid off
    vec3 glow_color = vec3(1.0, 0.8, 0.3);
    float dist_to_sel_edge = 0.0;
    if (has_selection) {
        float hex_radius = hex_size * 0.5;
        vec2 d_sel = abs(v_world_pos.xz - selected_hex_center);
        float d1 = d_sel.y;
        float d2 = abs(dot(d_sel, vec2(SQRT_3/2.0, 0.5)));
        float dist_from_sel_center = max(d1, d2);
        dist_to_sel_edge = abs(hex_radius - dist_from_sel_center);
    }
    float glow = glow_fade * exp(-pow(dist_to_sel_edge / 40.0, 2.0)) * (0.85 + 0.15 * sin(TIME * 2.0));

    // 8. Grid lines (only when show_grid)
    float line_alpha = 0.0;
    float grid_fade_alpha = 1.0;
    if (altitude > fade_end) {
        grid_fade_alpha = 0.0;
    } else if (altitude > fade_start) {
        grid_fade_alpha = 1.0 - (altitude - fade_start) / (fade_end - fade_start);
    }
    if (show_grid && grid_fade_alpha > 0.0) {
        float half_width = line_width * 0.5;
        if (dist_from_edge < half_width) {
            line_alpha = (1.0 - smoothstep(half_width - 2.0, half_width, dist_from_edge)) * grid_fade_alpha;
        }
    }

    // 9. Composite
    vec3 final_albedo = base_col;
    if (is_hovered && !is_selected) {
        final_albedo = mix(final_albedo, highlight_color.rgb, hover_fill_alpha);
    }
    if (hover_line_alpha > 0.0) {
        final_albedo = mix(final_albedo, highlight_color.rgb, 0.5 * hover_line_alpha);
    }
    if (line_alpha > 0.0) {
        final_albedo = mix(final_albedo, grid_color.rgb, grid_color.a * line_alpha);
    }

    // Cap albedo to prevent blowout from any additive tint
    final_albedo = min(final_albedo, vec3(1.5));

    ALBEDO = final_albedo;
    EMISSION = glow_color * glow;
    ROUGHNESS = roughness;
    METALLIC = metallic;
    RIM = rim;
    RIM_TINT = rim_tint;
}
