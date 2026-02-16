shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Terrain only: elevation coloring, slope, fog, overview blend, water. No hex logic.

uniform vec3 albedo : source_color = vec3(0.3, 0.5, 0.2);
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float rim : hint_range(0.0, 1.0) = 0.2;
uniform float rim_tint : hint_range(0.0, 1.0) = 0.5;

uniform vec3 camera_position = vec3(0.0, 0.0, 0.0);
uniform float altitude = 1000.0;
uniform vec2 terrain_center_xz = vec2(0.0, 0.0);
uniform float terrain_radius_m = 2000000.0;

uniform sampler2D overview_texture : source_color;
uniform vec2 overview_origin = vec2(0.0, 0.0);
uniform vec2 overview_size = vec2(1.0, 1.0);
uniform bool use_overview = false;

// Hex grid: same lens as selection (basic_camera.gd). hex_size = pointy-top radius = HEX_SIZE_M/sqrt(3).
uniform float hex_size = 577.35;
uniform float hex_line_width = 30.0;
uniform float hex_line_softness = 5.0;
uniform float hex_grid_strength = 10;
uniform vec3 hex_line_color = vec3(0.07, 0.09, 0.05);
uniform bool show_hex_grid = true;

varying vec3 v_world_pos;
varying vec3 v_view_dir;
varying float v_elevation;
varying vec3 v_world_normal;

// Water (elevation below 5m = sea)
const float WATER_ELEVATION_M = 5.0;

// Height-based terrain colors
const float TRANSITION_M = 200.0;
const vec3 COLOR_LOWLAND = vec3(0.18, 0.32, 0.12);
const vec3 COLOR_FOOTHILLS = vec3(0.25, 0.42, 0.15);
const vec3 COLOR_ALPINE = vec3(0.35, 0.48, 0.18);
const vec3 COLOR_ROCK = vec3(0.45, 0.38, 0.30);
const vec3 COLOR_HIGH_ROCK = vec3(0.62, 0.60, 0.58);
const vec3 COLOR_SNOW = vec3(0.92, 0.93, 0.95);
const vec3 COLOR_STEEP_ROCK = vec3(0.40, 0.35, 0.28);

const vec3 COLOR_COASTAL_LOW = vec3(0.16, 0.29, 0.11);
const vec3 COLOR_PLAINS = vec3(0.18, 0.32, 0.12);
const vec3 COLOR_LOW_HILLS = vec3(0.20, 0.34, 0.13);
const float LOW_ELEV_BLEND_M = 50.0;

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

vec3 terrain_low_elev_color(float elev) {
	float t50 = smoothstep(50.0 - LOW_ELEV_BLEND_M, 50.0 + LOW_ELEV_BLEND_M, elev);
	float t150 = smoothstep(150.0 - LOW_ELEV_BLEND_M, 150.0 + LOW_ELEV_BLEND_M, elev);
	vec3 c = mix(COLOR_COASTAL_LOW, COLOR_PLAINS, t50);
	c = mix(c, COLOR_LOW_HILLS, t150);
	return c;
}

// --- Same lens as selection: formulas match basic_camera.gd (world_to_axial, axial_to_world, hex shape). ---
vec2 world_to_axial(vec2 xz, float size) {
	return vec2((2.0/3.0 * xz.x) / size, (-1.0/3.0 * xz.x + sqrt(3.0)/3.0 * xz.y) / size);
}
vec2 axial_to_center(vec2 axial, float size) {
	return vec2(size * (1.5 * axial.x), size * (sqrt(3.0)/2.0 * axial.x + sqrt(3.0) * axial.y));
}
vec3 cube_round(vec3 c) {
	vec3 r = round(c);
	vec3 d = abs(r - c);
	if (d.x > d.y && d.x > d.z) r.x = -r.y - r.z;
	else if (d.y > d.z) r.y = -r.x - r.z;
	else r.z = -r.x - r.y;
	return r;
}
float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}
// Inward side of edge a->b; inside hex when all six >= 0.
float edge_side(vec2 p, vec2 a, vec2 b) {
	vec2 e = b - a;
	return (p.x - a.x) * e.y - (p.y - a.y) * e.x;
}
// Same cell as selection. Returns (distance to edge, 1 if inside cell else 0). One pass, no gap triangles.
vec2 hex_edge_and_inside(vec2 world_xz, float size) {
	vec2 axial = world_to_axial(world_xz, size);
	vec3 r = cube_round(vec3(axial.x, -axial.x - axial.y, axial.y));
	vec2 center = axial_to_center(vec2(r.x, r.z), size);
	vec2 p = world_xz - center;
	float k = size;
	float c = 0.866025, s = 0.5;
	vec2 v0 = k * vec2(0.0, 1.0), v1 = k * vec2(-c, s), v2 = k * vec2(-c, -s);
	vec2 v3 = k * vec2(0.0, -1.0), v4 = k * vec2(c, -s), v5 = k * vec2(c, s);
	float d0 = seg_dist(p, v0, v1), d1 = seg_dist(p, v1, v2), d2 = seg_dist(p, v2, v3);
	float d3 = seg_dist(p, v3, v4), d4 = seg_dist(p, v4, v5), d5 = seg_dist(p, v5, v0);
	float edge_d = min(min(min(d0, d1), min(d2, d3)), min(d4, d5));
	float in0 = edge_side(p, v0, v1), in1 = edge_side(p, v1, v2), in2 = edge_side(p, v2, v3);
	float in3 = edge_side(p, v3, v4), in4 = edge_side(p, v4, v5), in5 = edge_side(p, v5, v0);
	float inside = (in0 >= 0.0 && in1 >= 0.0 && in2 >= 0.0 && in3 >= 0.0 && in4 >= 0.0 && in5 >= 0.0) ? 1.0 : 0.0;
	return vec2(edge_d, inside);
}

void vertex() {
	vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_world_pos = world_pos.xyz;
	v_elevation = world_pos.y;
	v_world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	vec3 n = normalize(v_world_normal);
	vec3 mesh_terrain_color;
	if (v_elevation < WATER_ELEVATION_M) {
		vec3 water_low = vec3(0.15, 0.25, 0.45);
		vec3 water_high = vec3(0.08, 0.15, 0.35);
		mesh_terrain_color = mix(water_low, water_high, smoothstep(100000.0, 1000000.0, length(camera_position)));
	} else {
		vec3 height_col = terrain_height_color(v_elevation);
		if (v_elevation < 300.0) {
			vec3 low_col = terrain_low_elev_color(v_elevation);
			float blend = smoothstep(200.0, 400.0, v_elevation);
			height_col = mix(low_col, height_col, blend);
		}
		float steep_mix = smoothstep(0.7, 0.5, n.y);
		mesh_terrain_color = mix(height_col, COLOR_STEEP_ROCK, steep_mix);
	}

	float overview_blend = use_overview ? smoothstep(15000.0, 180000.0, altitude) : 0.0;
	vec3 overview_col = mesh_terrain_color;
	if (use_overview && overview_size.x > 0.0 && overview_size.y > 0.0) {
		vec2 world_xz = v_world_pos.xz;
		vec2 overview_uv = (world_xz - overview_origin) / overview_size;
		overview_uv = clamp(overview_uv, 0.0, 1.0);
		overview_col = texture(overview_texture, overview_uv).rgb;
	}
	vec3 base_col = mix(mesh_terrain_color, overview_col, overview_blend);

	vec3 lum = vec3(0.299, 0.587, 0.114);
	float desat = 0.3 * smoothstep(100000.0, 500000.0, altitude);
	base_col = mix(base_col, vec3(dot(base_col, lum)), desat);
	base_col *= mix(1.0, 0.8, smoothstep(500000.0, 2000000.0, altitude));

	float dist_from_center = length(v_world_pos.xz - terrain_center_xz);
	float edge_fade_width = 80000.0;
	vec3 ground_fog_color = vec3(0.75, 0.82, 0.90);
	vec3 space_color = vec3(0.08, 0.10, 0.18);
	vec3 fog_color = mix(ground_fog_color, space_color, smoothstep(200000.0, 1200000.0, altitude));
	float edge_fade = smoothstep(terrain_radius_m - edge_fade_width, terrain_radius_m, dist_from_center);
	base_col = mix(base_col, fog_color, edge_fade);

	float fog_end_actual = (altitude < 100000.0) ? 800000.0 : max(1200000.0, altitude * 4.0);
	float dist = length(v_world_pos - camera_position);
	float fog_start = mix(50000.0, 250000.0, smoothstep(100000.0, 600000.0, altitude));
	float fog_factor = smoothstep(fog_start, fog_end_actual, dist);
	base_col = mix(base_col, fog_color, fog_factor);

	// TEMP: Unconditional red tint to verify this shader is on the visible terrain
	base_col = mix(base_col, vec3(1.0, 0.0, 0.0), 0.3);

	// === HEX GRID DIAGNOSTIC — TEMPORARY ===
	float hex_line_mask = 0.0;
	float grid_mix = 0.0;
	int hex_test = 1; // <-- CHANGE THIS NUMBER TO RUN DIFFERENT TESTS

	if (show_hex_grid) {
		vec2 edge_inside = hex_edge_and_inside(v_world_pos.xz, hex_size);
		float d = edge_inside.x;
		float inside = edge_inside.y;
		float aa = fwidth(d) * hex_line_softness;

		if (hex_test == 1) {
			// TEST 1: Inside mask — red where inside==1, normal terrain where inside==0
			if (inside > 0.5) {
				base_col = vec3(1.0, 0.0, 0.0);
			}
		} else if (hex_test == 2) {
			// TEST 2: Edge distance gradient — bright near edges, dark at cell centers
			float d_viz = 1.0 - clamp(d / (hex_size * 0.5), 0.0, 1.0);
			base_col = vec3(d_viz);
		} else if (hex_test == 3) {
			// TEST 3: Line mask — white lines where the smoothstep produces nonzero
			hex_line_mask = (1.0 - smoothstep(hex_line_width - aa, hex_line_width + aa, d)) * inside;
			base_col = vec3(hex_line_mask);
		} else if (hex_test == 4) {
			// TEST 4: fwidth — bright means fwidth(d) is large (bad), dark means small (good)
			float fw = fwidth(d);
			base_col = vec3(clamp(fw / 100.0, 0.0, 1.0));
		} else if (hex_test == 5) {
			// TEST 5: hex_size value — should be ~0.577 red if hex_size is correct (577.35/1000)
			base_col = vec3(clamp(hex_size / 1000.0, 0.0, 1.0), 0.0, 0.0);
		}
	}
	// === END DIAGNOSTIC ===

	ALBEDO = min(base_col, vec3(1.5));
	EMISSION = vec3(0.0);
	ROUGHNESS = clamp(roughness + grid_mix * 0.3, 0.0, 1.0);
	METALLIC = metallic;
	RIM = rim;
	RIM_TINT = rim_tint;
}
