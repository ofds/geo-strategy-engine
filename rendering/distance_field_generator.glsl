// GPU distance field generator — single chunk, pointy-top hex SDF
// Matches Python: generate_cell_textures.py hex_sdf_pointy_top, DISTANCE_NORMALIZE_M = 500

#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// ============================================================================
// INPUTS
// ============================================================================

layout(set = 0, binding = 0, rgba8ui) uniform readonly uimage2D cell_id_texture;

struct Cell {
	uint id;
	float cx;
	float cz;
};

layout(set = 0, binding = 1, std430) readonly buffer CellCenters {
	uint cell_count;
	Cell cells[];
};

layout(set = 0, binding = 2, r8) uniform writeonly image2D distance_field_output;

// ============================================================================
// PUSH CONSTANTS
// ============================================================================

layout(push_constant) uniform Params {
	vec2 chunk_origin;
	float chunk_size;
	float hex_radius;
	uint texture_size;
} params;

// ============================================================================
// HEX SDF (pointy-top, matches Python)
// ============================================================================

const float HEX_SDF_K = 0.866025404;

float hex_sdf_pointy_top(vec2 point, vec2 center, float radius) {
	vec2 p = abs(point - center);
	float d1 = HEX_SDF_K * p.x + 0.5 * p.y - radius;
	float d2 = p.y - radius;
	return max(d1, d2);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(params.texture_size) || pixel.y >= int(params.texture_size)) {
		return;
	}

	vec2 uv = vec2(pixel) / max(float(params.texture_size - 1u), 1.0);
	vec2 world_pos = params.chunk_origin + uv * params.chunk_size;

	uvec4 cell_rgba = imageLoad(cell_id_texture, pixel);
	uint cell_id = cell_rgba.r * 16777216u + cell_rgba.g * 65536u
		+ cell_rgba.b * 256u + cell_rgba.a;

	if (cell_id == 0u) {
		imageStore(distance_field_output, pixel, vec4(1.0, 0.0, 0.0, 1.0));
		return;
	}

	vec2 cell_center = vec2(0.0);
	bool found = false;
	for (uint i = 0u; i < cell_count; i++) {
		if (cells[i].id == cell_id) {
			cell_center.x = cells[i].cx;
			cell_center.y = cells[i].cz;
			found = true;
			break;
		}
	}

	if (!found) {
		imageStore(distance_field_output, pixel, vec4(1.0, 0.0, 0.0, 1.0));
		return;
	}

	float sdf = hex_sdf_pointy_top(world_pos, cell_center, params.hex_radius);
	float distance_m = abs(sdf);
	float normalized = min(distance_m / 500.0, 1.0);
	imageStore(distance_field_output, pixel, vec4(normalized, 0.0, 0.0, 1.0));
}
