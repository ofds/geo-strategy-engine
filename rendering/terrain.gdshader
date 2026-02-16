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

// Hex grid: texture-based cell boundaries (Phase 1B). No analytical hex math.
uniform float hex_size = 577.35; // Kept for camera/selection parity; not used for grid (texture-based).
uniform float hex_line_width = 15.0;
uniform float hex_line_softness = 3.0;
uniform float hex_grid_strength = 0.6;
uniform vec3 hex_line_color = vec3(0.08, 0.10, 0.06);
uniform bool show_hex_grid = true;
// Per-chunk cell ID texture (RGBA → 32-bit id). NEAREST filter set by loader.
// filter_nearest required so boundary detection gets exact cell IDs (no blending)
uniform sampler2D cell_id_texture : hint_default_black, filter_nearest;
instance uniform vec2 chunk_origin_xz = vec2(0.0, 0.0);

varying vec3 v_world_pos;
varying vec2 v_uv;
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

// Decode RGBA to 32-bit cell ID (Phase 1A encoding: R*16777216 + G*65536 + B*256 + A)
uint decode_cell_id(vec4 rgba) {
	return uint(floor(rgba.r * 255.0 + 0.5)) * 16777216u +
	       uint(floor(rgba.g * 255.0 + 0.5)) * 65536u +
	       uint(floor(rgba.b * 255.0 + 0.5)) * 256u +
	       uint(floor(rgba.a * 255.0 + 0.5));
}

void vertex() {
	vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_world_pos = world_pos.xyz;
	v_uv = UV;
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

	// Hex grid: texture-based cell boundaries (Phase 1B). Boundary = pixel differs from neighbor.
	float grid_mix = 0.0;
	if (show_hex_grid) {
		vec4 cell_rgba = texture(cell_id_texture, v_uv);
		uint cell_id = decode_cell_id(cell_rgba);
		ivec2 tex_size = textureSize(cell_id_texture, 0);
		vec2 duv = vec2(1.0 / float(max(tex_size.x, 1)), 1.0 / float(max(tex_size.y, 1)));
		uint n0 = decode_cell_id(texture(cell_id_texture, v_uv + vec2(duv.x, 0.0)));
		uint n1 = decode_cell_id(texture(cell_id_texture, v_uv - vec2(duv.x, 0.0)));
		uint n2 = decode_cell_id(texture(cell_id_texture, v_uv + vec2(0.0, duv.y)));
		uint n3 = decode_cell_id(texture(cell_id_texture, v_uv - vec2(0.0, duv.y)));
		bool on_boundary = (cell_id != n0) || (cell_id != n1) || (cell_id != n2) || (cell_id != n3);
		float line_mask = on_boundary ? 1.0 : 0.0;

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
