// Screen-space hex overlay compute shader (Godot 4.x CompositorEffect)
// Reads depth, reconstructs world XZ, draws grid/hover/selection on frontmost surface only.

#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;

// Params: inv_proj (64), inv_view (64), then scalars (16-byte aligned)
layout(set = 0, binding = 2) uniform Params {
	mat4 inv_projection;
	mat4 inv_view;  // camera transform (view-to-world)
	float hex_size;
	float show_grid;  // 1.0 = true
	float altitude;
	float _pad0;
	vec3 camera_position;
	float time;
	vec2 hovered_hex_center;
	vec2 selected_hex_center;
	float selection_time;
	float _pad1;
} params;

const float SQRT_3 = 1.73205080757;
const float LINE_WIDTH = 30.0;
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

vec3 reconstruct_world_position(vec2 uv, float depth) {
	// NDC: uv (0-1) -> xy (-1 to 1); depth as stored (Godot may use reverse-Z)
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = params.inv_projection * ndc;
	view_pos /= view_pos.w;
	vec4 world = params.inv_view * view_pos;
	return world.xyz;
}

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_image);
	if (uv.x >= size.x || uv.y >= size.y) return;

	vec2 uv_f = (vec2(uv) + 0.5) / vec2(size);
	float depth = textureLod(depth_texture, uv_f, 0.0).r;

	// Sky / no geometry: no overlay (Godot depth: 1.0 = far with reverse-Z, 0 = near; adjust if needed)
	if (depth >= 1.0 || depth <= 0.0) return;

	vec3 world_pos = reconstruct_world_position(uv_f, depth);
	vec2 world_xz = world_pos.xz;

	float dist_from_edge = hex_dist(world_xz, params.hex_size);
	vec2 current_axial = axial_round(world_to_axial(world_xz, params.hex_size));
	vec2 hovered_axial = axial_round(world_to_axial(params.hovered_hex_center, params.hex_size));
	vec2 selected_axial = axial_round(world_to_axial(params.selected_hex_center, params.hex_size));
	const float AXIAL_EPS = 0.01;
	bool is_hovered = (abs(current_axial.x - hovered_axial.x) < AXIAL_EPS && abs(current_axial.y - hovered_axial.y) < AXIAL_EPS);
	bool is_selected = (abs(current_axial.x - selected_axial.x) < AXIAL_EPS && abs(current_axial.y - selected_axial.y) < AXIAL_EPS);
	bool has_selection = (params.selected_hex_center.x < SELECT_SENTINEL);

	float hex_radius = params.hex_size * 0.5;
	float hex_radius_cutout = hex_radius + CUTOUT_MARGIN_M;
	vec2 d_sel = abs(world_xz - params.selected_hex_center);
	float d1_sel = d_sel.y;
	float d2_sel = abs(dot(d_sel, vec2(SQRT_3/2.0, 0.5)));
	float dist_from_sel_center = max(d1_sel, d2_sel);
	float dist_to_sel_edge = abs(hex_radius - dist_from_sel_center);
	bool inside_cutout = (dist_from_sel_center <= hex_radius_cutout);

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

	// 1. Grid lines
	if (params.show_grid > 0.5 && grid_fade_alpha > 0.0) {
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

	// 3. Selection
	if (has_selection) {
		if (inside_cutout) {
			albedo = mix(albedo, vec3(0.02, 0.02, 0.02), 0.95 * tint_fade);
			alpha = max(alpha, 0.95 * tint_fade);
		}
		if (is_selected) {
			vec3 gold = vec3(1.0, 0.9, 0.5);
			albedo = mix(albedo, gold, 0.25 * tint_fade);
			alpha = max(alpha, 0.25 * tint_fade);
			float outline_width = 20.0 * border_scale;
			float outline_smooth = 6.0 * border_scale;
			float outline = 1.0 - smoothstep(outline_width - outline_smooth, outline_width + outline_smooth, dist_to_sel_edge);
			if (dist_from_sel_center <= hex_radius) {
				albedo = mix(albedo, vec3(0.85, 0.75, 0.35), outline * 0.9);
				alpha = max(alpha, 0.8 * outline);
				float glow_width = 25.0 * border_scale;
				float rim_pulse = 0.7 + 0.3 * sin(params.time * 1.5);
				float glow = glow_fade * glow_scale * exp(-pow(dist_to_sel_edge / glow_width, 2.0)) * rim_pulse;
				emission = vec3(1.0, 0.8, 0.3) * glow;
			}
		}
		if (!is_selected) {
			float dist_to_sel = length(world_xz - params.selected_hex_center);
			if (dist_to_sel < params.hex_size * 2.0) {
				alpha = max(alpha, 0.15 * darken_fade);
				albedo = mix(albedo, vec3(0.0, 0.0, 0.0), 0.15 * darken_fade);
			}
		}
	}

	vec4 color = imageLoad(color_image, uv);
	// Blend overlay on top (alpha blend)
	vec3 out_rgb = mix(color.rgb, albedo, alpha) + emission;
	float out_a = color.a;
	imageStore(color_image, uv, vec4(out_rgb, out_a));
}
