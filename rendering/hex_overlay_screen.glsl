// Screen-space hex overlay compute shader (Godot 4.x CompositorEffect)
// Reads depth, reconstructs world XZ, draws grid/hover/selection on frontmost surface only.

#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;

// Params: two-step unproject so we get true world space (grid locks when panning)
layout(set = 0, binding = 2) uniform Params {
	mat4 inv_projection;   // clip -> view (column-major)
	mat4 inv_view;         // view -> world (camera transform, column-major)
	float hex_size;
	float show_grid;  // 1.0 = true
	float altitude;
	float depth_ndc_flip;  // 0=use raw depth as NDC z, 1=use (1.0 - raw) as NDC z (if depth is "all dark" try 1)
	vec3 camera_position;
	float time;
	vec2 hovered_hex_center;
	vec2 selected_hex_center;
	float selection_time;
	float debug_visualization;  // 0=off, 1=raw depth, 2=world XZ pattern (camera-relative)
	float debug_depth;  // true = show depth gradient (red=near, blue=far) and skip grid
	float use_resolved_depth;  // 1=resolved texture, 0=raw (passed so we can show which source is active)
	float draw_grid_lines;  // false = only selection/hover (grid from world-space decal)
} params;

const float SQRT_3 = 1.73205080757;
const float LINE_WIDTH = 12.0;  // Grid/hover line thickness (was 30; reduce for subtler borders)
const float CUTOUT_MARGIN_M = 15.0;
const float GRID_FADE_START = 5000.0;
const float GRID_FADE_END = 20000.0;
const float HOVER_SENTINEL = -999990.0;
const float SELECT_SENTINEL = 900000.0;

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

float hex_dist(vec2 p, float width) {
	float size = width / SQRT_3;
	vec2 q = world_to_axial(p, width);
	vec2 center_axial = axial_round(q);
	float size_ax = size;
	float cx = size_ax * (3.0/2.0 * center_axial.x);
	float cy = size_ax * (SQRT_3/2.0 * center_axial.x + SQRT_3 * center_axial.y);
	vec2 center_world = vec2(cx, cy);
	vec2 d = p - center_world;
	float r = width * 0.5;
	d = abs(d);
	float d1 = d.y;
	float d2 = abs(dot(d, vec2(SQRT_3/2.0, 0.5)));
	float dist_from_center = max(d1, d2);
	return r - dist_from_center;
}

vec3 reconstruct_world_position(vec2 uv, float raw_depth) {
	// 1. UV to NDC (0..1 → -1..1)
	vec2 ndc_xy = uv * 2.0 - 1.0;
	// 2. Depth is reverse-Z (1.0 = near, 0.0 = far). Map to NDC z in [-1, 1].
	float depth_linear = params.depth_ndc_flip > 0.5 ? (1.0 - raw_depth) : raw_depth;
	float ndc_z = depth_linear * 2.0 - 1.0;
	// 3. Build clip-space position
	vec4 clip_pos = vec4(ndc_xy, ndc_z, 1.0);
	// 4. Clip -> view space (ensures we're not mixing up view vs world)
	vec4 view_h = params.inv_projection * clip_pos;
	view_h.xyz /= view_h.w;
	// 5. View -> world space (camera transform)
	vec4 world_h = params.inv_view * vec4(view_h.xyz, 1.0);
	return world_h.xyz;
}

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_image);
	if (uv.x >= size.x || uv.y >= size.y) return;

	vec2 uv_f = (vec2(uv) + 0.5) / vec2(size);
	vec4 depth_sample = textureLod(depth_texture, uv_f, 0.0);
	float depth_raw = depth_sample.r;

	// DEBUG: Visualize depth. F4 = this view. F6 = toggle depth source (border: magenta=raw, yellow=resolved).
	// Top-left = R channel (depth) with LOG scale so zoomed-out (far = small depth) stays visible instead of black.
	if (params.debug_depth > 0.5) {
		vec2 px = vec2(uv) / vec2(size);
		float border = 0.0;
		if (px.x < 0.005 || px.x > 0.995 || px.y < 0.005 || px.y > 0.995) border = 1.0;
		vec3 border_color = params.use_resolved_depth > 0.5 ? vec3(1.0, 1.0, 0.0) : vec3(1.0, 0.0, 1.0);

		float r = depth_sample.r, g = depth_sample.g, b = depth_sample.b, a = depth_sample.a;
		float ch = 0.0;
		if (px.x < 0.5 && px.y < 0.5) {
			// R = depth. Power curve so both near (1) and far (0.001) visible: pow(r, 0.2) gives contrast
			float d = max(r, 1e-5);
			ch = clamp(pow(d, 0.2), 0.0, 1.0);
		} else if (px.x >= 0.5 && px.y < 0.5) {
			ch = clamp(g * 50.0, 0.0, 1.0);
		} else if (px.x < 0.5 && px.y >= 0.5) {
			ch = clamp(b * 50.0, 0.0, 1.0);
		} else {
			ch = clamp(a * 50.0, 0.0, 1.0);
		}
		vec3 quad_color = vec3(ch, ch, ch);
		vec3 final_rgb = mix(quad_color, border_color, border);
		imageStore(color_image, uv, vec4(final_rgb, 1.0));
		return;
	}

	// Sky / no geometry: skip (reverse-Z: near=1, far=0). Accept any positive depth so far terrain still gets grid.
	if (depth_raw >= 1.0 || depth_raw < 1e-6) return;

	float depth = depth_raw;
	vec3 world_pos = reconstruct_world_position(uv_f, depth);
	// Work in camera-relative space for precision (avoids floating-point loss at 2M+ meters)
	vec2 camera_xz = vec2(params.camera_position.x, params.camera_position.z);
	vec3 relative_pos = world_pos - vec3(camera_xz.x, 0.0, camera_xz.y);
	vec2 world_xz = relative_pos.xz;

	float dist_from_edge = hex_dist(world_xz, params.hex_size);
	// Selection/hover centers in camera-relative space for consistent axial math
	vec2 hovered_center_relative = params.hovered_hex_center - camera_xz;
	vec2 selected_center_relative = params.selected_hex_center - camera_xz;
	vec2 current_axial = axial_round(world_to_axial(world_xz, params.hex_size));
	vec2 hovered_axial = axial_round(world_to_axial(hovered_center_relative, params.hex_size));
	vec2 selected_axial = axial_round(world_to_axial(selected_center_relative, params.hex_size));
	const float AXIAL_EPS = 0.01;
	bool is_hovered = (abs(current_axial.x - hovered_axial.x) < AXIAL_EPS && abs(current_axial.y - hovered_axial.y) < AXIAL_EPS);
	bool is_selected = (abs(current_axial.x - selected_axial.x) < AXIAL_EPS && abs(current_axial.y - selected_axial.y) < AXIAL_EPS);
	bool has_selection = (params.selected_hex_center.x < SELECT_SENTINEL);

	float hex_radius = params.hex_size * 0.5;
	vec2 d_sel = abs(world_xz - selected_center_relative);
	float d1_sel = d_sel.y;                              // North-South faces
	float d2_sel = abs(dot(d_sel, vec2(SQRT_3/2.0, 0.5)));   // NE-SW faces
	float d3_sel = abs(dot(d_sel, vec2(SQRT_3/2.0, -0.5)));  // NW-SE faces (was missing)
	float dist_from_sel_center = max(max(d1_sel, d2_sel), d3_sel);

	float border_scale = clamp(params.altitude / 5000.0, 1.0, 25.0);
	float glow_scale = 1.0 + params.altitude / 50000.0;
	float glow_fade = has_selection ? min(params.selection_time / 0.1, 1.0) : 0.0;
	float darken_fade = has_selection ? min(params.selection_time / 0.3, 1.0) : 0.0;
	float tint_fade = has_selection ? min(params.selection_time / 0.2, 1.0) : 0.0;

	vec3 albedo = vec3(0.0);
	float alpha = 0.0;
	vec3 emission = vec3(0.0);

	// Grid fade by altitude
	float grid_fade_alpha = 1.0;
	if (params.altitude > GRID_FADE_END) {
		grid_fade_alpha = 0.0;
	} else if (params.altitude > GRID_FADE_START) {
		grid_fade_alpha = 1.0 - (params.altitude - GRID_FADE_START) / (GRID_FADE_END - GRID_FADE_START);
	}

	// 1. Grid lines — DISABLED when using world-space decal (draw_grid_lines = false)
	// Only draw selection/hover in compositor; grid comes from HexGridMesh decal.
	if (params.draw_grid_lines > 0.5 && params.show_grid > 0.5 && grid_fade_alpha > 0.0) {
		float half_width = LINE_WIDTH * 0.5;
		if (dist_from_edge < half_width) {
			float line_alpha = (1.0 - smoothstep(half_width - 2.0, half_width, dist_from_edge)) * grid_fade_alpha;
			albedo = mix(albedo, vec3(0.0, 0.0, 0.0), line_alpha);
			alpha = max(alpha, 0.6 * line_alpha);
		}
	}

	// 2. Hover
	if (params.hovered_hex_center.x > HOVER_SENTINEL && is_hovered && !is_selected) {
		float half_width = LINE_WIDTH * 0.5;
		if (dist_from_edge < half_width) {
			float hover_line = (1.0 - smoothstep(half_width - 2.0, half_width, dist_from_edge));
			albedo = mix(albedo, vec3(1.0, 1.0, 1.0), 0.5 * hover_line);
			alpha = max(alpha, 0.5 * hover_line);
		}
		alpha = max(alpha, 0.08);
		albedo = mix(albedo, vec3(1.0, 1.0, 1.0), 0.08);
	}

	// 3. Selection: subtle hover feel (light gold tint) + golden rim so slice feels lifted
	if (has_selection) {
		// Subtle vignette inside selected hex (keep terrain colors visible)
		if (dist_from_sel_center <= hex_radius) {
			albedo = mix(albedo, albedo * 0.85, tint_fade * 0.3);
		}
		if (is_selected) {
			// Light gold tint on interior
			vec3 gold_tint = vec3(1.0, 0.92, 0.6);
			albedo = mix(albedo, gold_tint, 0.08 * tint_fade);
			alpha = max(alpha, 0.08 * tint_fade);

			// Thick golden rim at hex edge
			float rim_distance = abs(hex_radius - dist_from_sel_center);
			float rim_width = 18.0 * border_scale;  // Selection rim (was 30; slightly thinner)
			if (dist_from_sel_center <= hex_radius && rim_distance < rim_width) {
				vec3 gold_rim = vec3(1.0, 0.8, 0.3);  // Gold (matches decal grid)
				float rim_alpha = smoothstep(rim_width, rim_width * 0.5, rim_distance);
				albedo = mix(albedo, gold_rim, rim_alpha * 0.95);
				alpha = max(alpha, rim_alpha * 0.9);
				float rim_pulse = 0.7 + 0.3 * sin(params.time * 1.5);
				emission = gold_rim * rim_pulse * rim_alpha * glow_scale * glow_fade;
			}
		}
		if (!is_selected) {
			float dist_to_sel = length(world_xz - selected_center_relative);
			if (dist_to_sel < params.hex_size * 2.0) {
				alpha = max(alpha, 0.15 * darken_fade);
				albedo = mix(albedo, vec3(0.0, 0.0, 0.0), 0.15 * darken_fade);
			}
		}
	}

	vec4 color = imageLoad(color_image, uv);
	vec3 out_rgb = mix(color.rgb, albedo, alpha) + emission;
	float out_a = color.a;

	// Debug: inspect depth range and reconstructed world (F2 to cycle)
	if (params.debug_visualization > 0.5) {
		if (params.debug_visualization < 1.5) {
			// Mode 1: raw depth. If "all dark", depth is ~0 (try 1.0-depth in reconstruction).
			// Scale up so tiny values (e.g. 0.001) become visible.
			float d = clamp(depth * 50.0, 0.0, 1.0);
			out_rgb = vec3(d, d, d);
			out_a = 1.0;
		} else {
			// Mode 2: world XZ pattern (camera-relative). If this drifts when you rotate, unproject is wrong.
			float scale = 2000.0;  // 2km repeat
			vec2 f = fract(world_xz / scale);
			out_rgb = vec3(f.x, f.y, 0.5);
			out_a = 1.0;
		}
	}

	imageStore(color_image, uv, vec4(out_rgb, out_a));
}
