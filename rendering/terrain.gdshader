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
// Per-chunk cell ID texture (RGBA → 32-bit id). Phase 1B fix: texelFetch for exact texel sampling.
uniform sampler2D cell_id_texture : filter_nearest, repeat_disable, hint_default_black;
instance uniform vec2 chunk_origin_xz = vec2(0.0, 0.0);

// Optional: set true to visualize UV→pixel mapping (red=X, green=Y). Use for Test 1 verification.
uniform bool show_debug_texel_coords = false;

// === DIAGNOSTIC (temporary — remove after investigation) ===
// Set one to true from Inspector or GDScript to run diagnostics.
uniform bool debug_show_elevation = false;   // Part 1: terrain color — grayscale + red bands every 1000m
uniform bool debug_show_cell_texture = false; // Part 2: grid — RED=texture missing, colored patches=bound

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

// Clamp integer pixel coords to texture bounds (for texelFetch).
ivec2 clamp_texel_coord(ivec2 p, ivec2 size) {
	return clamp(p, ivec2(0, 0), size - ivec2(1, 1));
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

	// Outputs: set in one place at the end (Godot fragment() does not allow return).
	vec3 out_albedo = vec3(0.0);
	vec3 out_emission = vec3(0.0);
	float out_roughness = roughness;
	float out_metallic = metallic;
	float out_rim = rim;
	float out_rim_tint = rim_tint;

	// === DEBUG ELEVATION COLOR (Part 1 diagnostic) — F10 ===
	if (debug_show_elevation) {
		float debug_elev = clamp(v_elevation / 5000.0, 0.0, 1.0);
		out_albedo = vec3(debug_elev, debug_elev, debug_elev);
		float band = mod(v_elevation, 1000.0);
		if (band < 50.0) {
			out_albedo = vec3(1.0, 0.0, 0.0);
		}
	} else if (debug_show_cell_texture) {
		// === DEBUG CELL TEXTURE BINDING (Part 2 diagnostic) — F11 ===
		ivec2 tex_size = textureSize(cell_id_texture, 0);
		if (tex_size.x <= 1 || tex_size.y <= 1) {
			out_albedo = vec3(1.0, 0.0, 0.0); // RED = texture not bound
		} else {
			ivec2 pixel_coord = ivec2(floor(v_uv * vec2(tex_size - ivec2(1, 1)) + vec2(0.5, 0.5)));
			pixel_coord = clamp(pixel_coord, ivec2(0, 0), tex_size - ivec2(1, 1));
			vec4 cell_rgba = texelFetch(cell_id_texture, pixel_coord, 0);
			uint cell_id = decode_cell_id(cell_rgba);
			float hue = mod(float(cell_id) * 0.618033988749895, 1.0);
			float r = clamp(abs(hue * 6.0 - 3.0) - 1.0, 0.0, 1.0);
			float g = clamp(2.0 - abs(hue * 6.0 - 2.0), 0.0, 1.0);
			float b = clamp(2.0 - abs(hue * 6.0 - 4.0), 0.0, 1.0);
			out_albedo = vec3(r, g, b);
		}
	} else {
	// === NORMAL TERRAIN PIPELINE ===
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

	// Hex grid: texelFetch-based cell boundaries (Phase 1B fix). Exact texel sampling, 511-based convention.
	float grid_mix = 0.0;
	if (show_hex_grid) {
		ivec2 tex_size = textureSize(cell_id_texture, 0);
		// Skip grid when texture is missing or 1x1 (avoids undefined clamp; no boundaries to draw)
		if (tex_size.x > 1 && tex_size.y > 1) {
			// Map UV (0..1) to integer pixel index (0..tex_size-1) matching Python: local_x = (i/(res-1))*chunk_size
			ivec2 pixel_coord = ivec2(floor(v_uv * vec2(tex_size - ivec2(1, 1)) + vec2(0.5, 0.5)));

			// Debug: visualize pixel coordinate (Test 1 — gradient: NW=black, SE=yellow)
			if (show_debug_texel_coords) {
				vec2 debug_coord = vec2(pixel_coord) / max(vec2(float(tex_size.x - 1), float(tex_size.y - 1)), vec2(1.0, 1.0));
				base_col = vec3(debug_coord.x, debug_coord.y, 0.0);
				grid_mix = 0.0;
			} else {

			// Sample center and four neighbors with texelFetch (exact texel, no filtering)
			vec4 cell_rgba = texelFetch(cell_id_texture, clamp_texel_coord(pixel_coord, tex_size), 0);
			uint cell_id = decode_cell_id(cell_rgba);
			uint id_north = decode_cell_id(texelFetch(cell_id_texture, clamp_texel_coord(pixel_coord + ivec2(0, 1), tex_size), 0));
			uint id_south = decode_cell_id(texelFetch(cell_id_texture, clamp_texel_coord(pixel_coord + ivec2(0, -1), tex_size), 0));
			uint id_east = decode_cell_id(texelFetch(cell_id_texture, clamp_texel_coord(pixel_coord + ivec2(1, 0), tex_size), 0));
			uint id_west = decode_cell_id(texelFetch(cell_id_texture, clamp_texel_coord(pixel_coord + ivec2(-1, 0), tex_size), 0));
			bool on_boundary = (id_north != cell_id) || (id_south != cell_id) || (id_east != cell_id) || (id_west != cell_id);

			// Disable boundary at texture edges (chunk boundary artifact mitigation)
			float max_side = max(float(tex_size.x), float(tex_size.y));
			float edge_threshold = (max_side > 0.0) ? (1.5 / max_side) : 0.01;
			bool near_edge = (v_uv.x < edge_threshold || v_uv.x > 1.0 - edge_threshold || v_uv.y < edge_threshold || v_uv.y > 1.0 - edge_threshold);
			if (near_edge) {
				on_boundary = false;
			}
			float line_mask = on_boundary ? 1.0 : 0.0;

			// Fade on steep slopes
			line_mask *= smoothstep(0.35, 0.65, dot(n, vec3(0.0, 1.0, 0.0)));

			grid_mix = min(line_mask * hex_grid_strength, 1.0);
			// Darken and draw line; use stronger contrast on light terrain so grid is visible on snow
			base_col = mix(base_col, base_col * 0.5, grid_mix);
			base_col = mix(base_col, hex_line_color, grid_mix * 0.85);
			}
		}
	}

		out_albedo = min(base_col, vec3(1.5));
		out_roughness = clamp(roughness + grid_mix * 0.3, 0.0, 1.0);
	} // end normal pipeline else

	ALBEDO = out_albedo;
	EMISSION = out_emission;
	ROUGHNESS = out_roughness;
	METALLIC = out_metallic;
	RIM = out_rim;
	RIM_TINT = out_rim_tint;
}
