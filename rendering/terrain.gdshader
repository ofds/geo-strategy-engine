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
uniform float hex_line_width = 15.0;
uniform float hex_line_softness = 3.0;
uniform float hex_grid_strength = 0.6;
uniform vec3 hex_line_color = vec3(0.08, 0.10, 0.06);
uniform bool show_hex_grid = true;
instance uniform vec2 chunk_origin_xz = vec2(0.0, 0.0);

varying vec3 v_world_pos;
varying vec2 v_local_xz;
varying vec3 v_view_dir;
varying float v_elevation;
varying vec3 v_world_normal;

// Water (elevation below 5m = sea)
const float WATER_ELEVATION_M = 5.0;

// Elevation colors: data-driven from palette texture (single source of truth with Python pipeline)
uniform sampler2D elevation_palette : source_color, filter_linear, repeat_disable;
uniform float max_elevation_m = 10000.0;
uniform vec3 steep_rock_color = vec3(0.40, 0.35, 0.28);

vec3 terrain_height_color(float elev) {
	float t = clamp(elev / max_elevation_m, 0.0, 1.0);
	return texture(elevation_palette, vec2(t, 0.5)).rgb;
}

vec3 terrain_low_elev_color(float elev) {
	float t = clamp(elev / max_elevation_m, 0.0, 1.0);
	return texture(elevation_palette, vec2(t, 0.5)).rgb;
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

// Hex SDF: signed distance to hex boundary (negative inside, positive outside)
// Pointy-top: vertices at top/bottom (p.y = ±radius), flat edges at left/right (p.x = ±apothem).
// p.x = world X offset, p.y = world Z offset from hex center.
// apothem = center-to-flat-edge distance = hex_size * sqrt(3) / 2 ≈ 500m
float hex_sdf(vec2 p, float apothem) {
	p = abs(p);
	// Pointy-top SDF: boundary at (0, ±radius) and (±apothem, 0)
	return max(dot(p, vec2(0.5, 0.8660254)), p.x) - apothem;
}

// Compute distance to nearest hex boundary in a tiling grid
// Returns abs(signed distance) — always positive, 0 at boundary
float hex_grid_distance(vec2 local_xz, float size) {
	// Find which hex cell this pixel is in
	vec2 axial = world_to_axial(local_xz, size);
	vec3 cube = vec3(axial.x, -axial.x - axial.y, axial.y);
	vec3 rounded = cube_round(cube);
	vec2 center = axial_to_center(vec2(rounded.x, rounded.z), size);

	// Local position relative to hex center
	vec2 p = local_xz - center;

	// Apothem = center to flat edge = size * sqrt(3) / 2
	float apothem = size * 0.8660254;

	// Distance to boundary (0 at edges, positive moving inward or outward)
	return abs(hex_sdf(p, apothem));
}

void vertex() {
	vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_world_pos = world_pos.xyz;
	v_local_xz = world_pos.xz - chunk_origin_xz;
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
		mesh_terrain_color = mix(height_col, steep_rock_color, steep_mix);
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

	// Hex grid: SDF-based boundary distance, chunk-local for precision
	float grid_mix = 0.0;
	if (show_hex_grid) {
		float bd = hex_grid_distance(v_local_xz, hex_size);
		float aa = fwidth(bd) * hex_line_softness;
		float line_mask = 1.0 - smoothstep(hex_line_width - aa, hex_line_width + aa, bd);

		// Fade on steep slopes
		line_mask *= smoothstep(0.35, 0.65, dot(n, vec3(0.0, 1.0, 0.0)));

		grid_mix = min(line_mask * hex_grid_strength, 1.0);
		base_col = mix(base_col, base_col * 0.55, grid_mix);
		base_col = mix(base_col, hex_line_color, grid_mix * 0.7);
	}

	ALBEDO = min(base_col, vec3(1.5));
	EMISSION = vec3(0.0);
	ROUGHNESS = clamp(roughness + grid_mix * 0.3, 0.0, 1.0);
	METALLIC = metallic;
	RIM = rim;
	RIM_TINT = rim_tint;
}
