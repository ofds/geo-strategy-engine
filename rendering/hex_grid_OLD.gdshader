shader_type spatial;
// --- HEX OVERLAY DEPTH (see docs/PROGRESS.md "Hex overlay depth") ---
// depth_test_default + vertex offset hides the grid in Godot 4.5 (next_pass depth buffer). So we use
// depth_test_disabled: grid visible, but can show through where chunks overlap. Proper fix: screen-space overlay (backlog).
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_back, unshaded;

// Hex overlay only: grid lines, hover, selection (cutout + border + glow + darken). No terrain logic.

uniform float hex_size = 1000.0;
uniform bool show_grid = true;
uniform float grid_fade_start = 5000.0;
uniform float grid_fade_end = 20000.0;
uniform float altitude = 1000.0;
uniform vec3 camera_position = vec3(0.0, 0.0, 0.0);
uniform vec2 hovered_hex_center = vec2(0.0, 0.0);
uniform vec2 selected_hex_center = vec2(999999.0, 999999.0);
uniform float selection_time = 0.0;
// Cutout drawn slightly larger than slice so a thin dark "cut line" is visible between slice edge and cutout
const float CUTOUT_MARGIN_M = 15.0;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

const float SQRT_3 = 1.73205080757;
const float LINE_WIDTH = 30.0;

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
	float r = width * 0.5;
	d = abs(d);
	float d1 = d.y;
	float d2 = abs(dot(d, vec2(SQRT_3/2.0, 0.5)));
	float dist_from_center = max(d1, d2);
	return r - dist_from_center;
}

void vertex() {
	vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_world_pos = world_pos.xyz;
	v_world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	// Fix 6 (audit): Explicit transparent default; only override where grid/hover/selection apply
	ALPHA = 0.0;
	ALBEDO = vec3(0.0);

	// Fade overlay on back-facing surfaces (e.g. far side of mountains) to reduce "grid through terrain" look
	// (No 'return' in fragment — Godot disallows it; we multiply alpha by view_fade at the end.)
	vec3 view_dir = normalize(camera_position - v_world_pos);
	float facing = dot(normalize(v_world_normal), view_dir);
	float view_fade = smoothstep(-0.5, 0.0, facing);

	vec2 world_xz = v_world_pos.xz;
	float dist_from_edge = hex_dist(world_xz, hex_size);
	vec2 current_axial = axial_round(world_to_axial(world_xz, hex_size));
	vec2 hovered_axial = axial_round(world_to_axial(hovered_hex_center, hex_size));
	vec2 selected_axial = axial_round(world_to_axial(selected_hex_center, hex_size));
	const float AXIAL_EPS = 0.01;
	bool is_hovered = (abs(current_axial.x - hovered_axial.x) < AXIAL_EPS && abs(current_axial.y - hovered_axial.y) < AXIAL_EPS);
	bool is_selected = (abs(current_axial.x - selected_axial.x) < AXIAL_EPS && abs(current_axial.y - selected_axial.y) < AXIAL_EPS);
	bool has_selection = (selected_hex_center.x < 900000.0);

	float hex_radius = hex_size * 0.5;
	float hex_radius_cutout = hex_radius + CUTOUT_MARGIN_M;
	vec2 d_sel = abs(world_xz - selected_hex_center);
	float d1 = d_sel.y;
	float d2 = abs(dot(d_sel, vec2(SQRT_3/2.0, 0.5)));
	float dist_from_sel_center = max(d1, d2);
	float dist_to_sel_edge = abs(hex_radius - dist_from_sel_center);
	float signed_dist_sel_edge = hex_radius - dist_from_sel_center;
	bool inside_cutout = (dist_from_sel_center <= hex_radius_cutout);

	float border_scale = clamp(altitude / 5000.0, 1.0, 25.0);
	float glow_scale = 1.0 + altitude / 50000.0;
	float glow_fade = has_selection ? min(selection_time / 0.1, 1.0) : 0.0;
	float darken_fade = has_selection ? min(selection_time / 0.3, 1.0) : 0.0;
	float tint_fade = has_selection ? min(selection_time / 0.2, 1.0) : 0.0;

	vec3 albedo = vec3(0.0);
	float alpha = 0.0;
	vec3 emission = vec3(0.0);

	// Grid fade by altitude
	float grid_fade_alpha = 1.0;
	if (altitude > grid_fade_end) {
		grid_fade_alpha = 0.0;
	} else if (altitude > grid_fade_start) {
		grid_fade_alpha = 1.0 - (altitude - grid_fade_start) / (grid_fade_end - grid_fade_start);
	}

	// 1. Grid lines (only when show_grid) — draw first so they can be visible
	if (show_grid && grid_fade_alpha > 0.0) {
		float half_width = LINE_WIDTH * 0.5;
		if (dist_from_edge < half_width) {
			float line_alpha = (1.0 - smoothstep(half_width - 2.0, half_width, dist_from_edge)) * grid_fade_alpha;
			albedo = mix(albedo, vec3(0.0, 0.0, 0.0), line_alpha);
			alpha = max(alpha, 0.6 * line_alpha);
		}
	}

	// 2. Hover: thin white border + faint tint (when not selected)
	if (is_hovered && !is_selected) {
		float half_width = LINE_WIDTH * 0.5;
		if (dist_from_edge < half_width) {
			float hover_line = (1.0 - smoothstep(half_width - 2.0, half_width, dist_from_edge));
			albedo = mix(albedo, vec3(1.0, 1.0, 1.0), 0.5 * hover_line);
			alpha = max(alpha, 0.5 * hover_line);
		}
		alpha = max(alpha, 0.08);
		albedo = mix(albedo, vec3(1.0, 1.0, 1.0), 0.08);
	}

	// 3. Selection: dark cutout (shadow beneath lifted slice, slightly larger than slice for cut line) + thick golden border + golden tint + glow + surrounding darken
	if (has_selection) {
		if (inside_cutout) {
			// Dark cutout (hole): near-black so it reads as a gap, not a gray shadow
			albedo = mix(albedo, vec3(0.02, 0.02, 0.02), 0.95 * tint_fade);
			alpha = max(alpha, 0.95 * tint_fade);
		}
		if (is_selected) {
			// Golden tint overlay (on slice only)
			vec3 gold = vec3(1.0, 0.9, 0.5);
			albedo = mix(albedo, gold, 0.25 * tint_fade);
			alpha = max(alpha, 0.25 * tint_fade);
			// Thick golden border inside hex only (no bleed outside)
			float outline_width = 20.0 * border_scale;
			float outline_smooth = 6.0 * border_scale;
			float outline = 1.0 - smoothstep(outline_width - outline_smooth, outline_width + outline_smooth, dist_to_sel_edge);
			// Only draw border/glow when inside the selected hex (dist_from_sel_center <= hex_radius)
			if (dist_from_sel_center <= hex_radius) {
				albedo = mix(albedo, vec3(0.85, 0.75, 0.35), outline * 0.9);
				alpha = max(alpha, 0.8 * outline);
				// Emissive glow at edge only inside hex volume
				float glow_width = 25.0 * border_scale;
				float rim_pulse = 0.7 + 0.3 * sin(TIME * 1.5);
				float glow = glow_fade * glow_scale * exp(-pow(dist_to_sel_edge / glow_width, 2.0)) * rim_pulse;
				emission = vec3(1.0, 0.8, 0.3) * glow;
			}
		}
		if (!is_selected) {
			// Surrounding darken: only for hexes near the selected one (avoid dimming whole terrain)
			float dist_to_sel = length(world_xz - selected_hex_center);
			if (dist_to_sel < hex_size * 2.0) {
				alpha = max(alpha, 0.15 * darken_fade);
				albedo = mix(albedo, vec3(0.0, 0.0, 0.0), 0.15 * darken_fade);
			}
		}
	}

	ALBEDO = albedo;
	ALPHA = alpha * view_fade;
	EMISSION = emission;
}
