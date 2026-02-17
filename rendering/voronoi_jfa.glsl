// Voronoi cell texture via Jump Flooding Algorithm (JFA)
// Pass 0: brute-force nearest seed. Passes 1-9: flood at 2^k.

#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer Seeds {
	uint seed_count;
	vec2 seed_positions[];
};

layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D voronoi_read;
layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D voronoi_write;

layout(push_constant) uniform Params {
	vec2 chunk_origin;
	float chunk_size;
	uint texture_size;
	int jump_distance;
	uint pass_index;
} params;

vec2 pixel_to_world(ivec2 pixel) {
	vec2 uv = vec2(pixel) / max(float(params.texture_size - 1u), 1.0);
	return params.chunk_origin + uv * params.chunk_size;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(params.texture_size) || pixel.y >= int(params.texture_size)) {
		return;
	}
	vec2 world_pos = pixel_to_world(pixel);

	if (params.pass_index == 0u) {
		uint nearest_seed_id = 0u;
		float min_dist = 1e10;
		for (uint i = 0u; i < seed_count; i++) {
			float d = distance(world_pos, seed_positions[i]);
			if (d < min_dist) {
				min_dist = d;
				nearest_seed_id = i;
			}
		}
		imageStore(voronoi_write, pixel, uvec4(nearest_seed_id, 0u, 0u, 0u));
		return;
	}

	uint my_seed_id = imageLoad(voronoi_read, pixel).r;
	vec2 my_seed_pos = seed_positions[my_seed_id];
	float my_dist = distance(world_pos, my_seed_pos);
	uint best_seed_id = my_seed_id;
	float best_dist = my_dist;

	const ivec2 offsets[8] = ivec2[8](
		ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
		ivec2(-1,  0),                ivec2(1,  0),
		ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
	);
	for (int i = 0; i < 8; i++) {
		ivec2 neighbor_pixel = pixel + offsets[i] * params.jump_distance;
		if (neighbor_pixel.x < 0 || neighbor_pixel.x >= int(params.texture_size) ||
			neighbor_pixel.y < 0 || neighbor_pixel.y >= int(params.texture_size)) {
			continue;
		}
		uint neighbor_seed_id = imageLoad(voronoi_read, neighbor_pixel).r;
		vec2 neighbor_seed_pos = seed_positions[neighbor_seed_id];
		float neighbor_dist = distance(world_pos, neighbor_seed_pos);
		if (neighbor_dist < best_dist) {
			best_dist = neighbor_dist;
			best_seed_id = neighbor_seed_id;
		}
	}
	imageStore(voronoi_write, pixel, uvec4(best_seed_id, 0u, 0u, 0u));
}
