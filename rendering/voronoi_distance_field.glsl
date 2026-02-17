// Distance to nearest Voronoi cell boundary (shape-agnostic neighbor sampling).
// Input: cell ID texture (RGBA8). Output: R8 normalized distance (0-1 = 0-500m).

#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8ui) uniform readonly uimage2D cell_id_texture;
layout(set = 0, binding = 1, r8) uniform writeonly image2D distance_field_output;

layout(push_constant) uniform Params {
	vec2 chunk_origin;
	float chunk_size;
	uint texture_size;
} params;

const int RADIUS = 3;
const float DISTANCE_NORMALIZE_M = 500.0;

uint decode_cell_id(uvec4 rgba) {
	return rgba.r * 16777216u + rgba.g * 65536u + rgba.b * 256u + rgba.a;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(params.texture_size) || pixel.y >= int(params.texture_size)) {
		return;
	}
	uint my_cell_id = decode_cell_id(imageLoad(cell_id_texture, pixel));

	float pixel_world_size = params.chunk_size / float(params.texture_size);
	float min_dist = 1e10;

	for (int dy = -RADIUS; dy <= RADIUS; dy++) {
		for (int dx = -RADIUS; dx <= RADIUS; dx++) {
			if (dx == 0 && dy == 0) {
				continue;
			}
			ivec2 neighbor_pixel = pixel + ivec2(dx, dy);
			if (neighbor_pixel.x < 0 || neighbor_pixel.x >= int(params.texture_size) ||
				neighbor_pixel.y < 0 || neighbor_pixel.y >= int(params.texture_size)) {
				continue;
			}
			uint neighbor_id = decode_cell_id(imageLoad(cell_id_texture, neighbor_pixel));
			if (neighbor_id != my_cell_id) {
				float dist_px = length(vec2(float(dx), float(dy)));
				float dist_m = dist_px * pixel_world_size;
				min_dist = min(min_dist, dist_m);
			}
		}
	}

	float normalized = min(min_dist / DISTANCE_NORMALIZE_M, 1.0);
	imageStore(distance_field_output, pixel, vec4(normalized, 0.0, 0.0, 1.0));
}
