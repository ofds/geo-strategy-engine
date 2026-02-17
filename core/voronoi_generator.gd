class_name VoronoiGenerator
extends RefCounted
## GPU Voronoi cell texture via Jump Flooding Algorithm (JFA).

const TEXTURE_SIZE := 512
const WORK_GROUP_SIZE := 16
const JFA_PASSES := 9

var rd: RenderingDevice = null
var shader_rid: RID
var pipeline_rid: RID

func _init() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		push_error("VoronoiGenerator: RenderingDevice not available.")
		return
	_compile_shader()
	_create_pipeline()


func _compile_shader() -> void:
	var path := "res://rendering/voronoi_jfa.glsl"
	if not FileAccess.file_exists(path):
		push_error("VoronoiGenerator: Shader file not found: " + path)
		return
	var src := FileAccess.get_file_as_string(path)
	if src.is_empty():
		push_error("VoronoiGenerator: Empty shader source.")
		return
	var rd_src := RDShaderSource.new()
	rd_src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	rd_src.source_compute = src
	var spirv := rd.shader_compile_spirv_from_source(rd_src)
	if spirv.compile_error_compute != "":
		push_error("VoronoiGenerator: Shader compile error: " + spirv.compile_error_compute)
		return
	shader_rid = rd.shader_create_from_spirv(spirv)
	if not shader_rid.is_valid():
		push_error("VoronoiGenerator: Failed to create shader from SPIR-V.")


func _create_pipeline() -> void:
	if not rd or not shader_rid.is_valid():
		return
	pipeline_rid = rd.compute_pipeline_create(shader_rid)
	if not pipeline_rid.is_valid():
		push_error("VoronoiGenerator: Failed to create compute pipeline.")


## Generate Voronoi cell texture using JFA.
## seeds: Array of Vector2 (world XZ).
## Returns ImageTexture RGBA8 (32-bit cell ID in RGBA), or null if no seeds.
func generate_voronoi_cells(seeds: Array, chunk_origin: Vector2, chunk_size: float) -> Texture2D:
	if seeds.is_empty():
		return null
	if not rd or not pipeline_rid.is_valid():
		push_error("VoronoiGenerator: Not initialized.")
		return null

	var seeds_buffer_rid := _create_seeds_buffer(seeds)
	if not seeds_buffer_rid.is_valid():
		return null
	var texture_a_rid := _create_voronoi_texture()
	var texture_b_rid := _create_voronoi_texture()
	if not texture_a_rid.is_valid() or not texture_b_rid.is_valid():
		rd.free_rid(seeds_buffer_rid)
		if texture_a_rid.is_valid(): rd.free_rid(texture_a_rid)
		if texture_b_rid.is_valid(): rd.free_rid(texture_b_rid)
		return null

	# Pass 0: init (write to texture_b)
	_dispatch_jfa_pass(seeds_buffer_rid, texture_a_rid, texture_b_rid, chunk_origin, chunk_size, 0, 0)
	var read_tex := texture_b_rid
	var write_tex := texture_a_rid

	for pass_idx in range(1, JFA_PASSES + 1):
		var jump_dist := 1 << (JFA_PASSES - pass_idx)
		_dispatch_jfa_pass(seeds_buffer_rid, read_tex, write_tex, chunk_origin, chunk_size, jump_dist, pass_idx)
		var temp := read_tex
		read_tex = write_tex
		write_tex = temp

	var result_image := _readback_texture(read_tex)
	rd.free_rid(seeds_buffer_rid)
	rd.free_rid(texture_a_rid)
	rd.free_rid(texture_b_rid)

	if result_image:
		return ImageTexture.create_from_image(result_image)
	return null


func _create_seeds_buffer(seeds: Array) -> RID:
	var n := seeds.size()
	var buffer_size := 4 + n * 8
	var buffer_data := PackedByteArray()
	buffer_data.resize(buffer_size)
	buffer_data.encode_u32(0, n)
	var offset := 4
	for s in seeds:
		var v: Vector2 = s
		buffer_data.encode_float(offset, v.x)
		buffer_data.encode_float(offset + 4, v.y)
		offset += 8
	return rd.storage_buffer_create(buffer_size, buffer_data)


func _create_voronoi_texture() -> RID:
	var format := RDTextureFormat.new()
	format.width = TEXTURE_SIZE
	format.height = TEXTURE_SIZE
	format.format = RenderingDevice.DATA_FORMAT_R32_UINT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return rd.texture_create(format, RDTextureView.new())


func _dispatch_jfa_pass(
	seeds_buffer_rid: RID,
	read_tex_rid: RID,
	write_tex_rid: RID,
	chunk_origin: Vector2,
	chunk_size: float,
	jump_distance: int,
	pass_index: int
) -> void:
	var uniforms: Array[RDUniform] = []
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(seeds_buffer_rid)
	uniforms.append(u0)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u1.binding = 1
	u1.add_id(read_tex_rid)
	uniforms.append(u1)
	var u2 := RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u2.binding = 2
	u2.add_id(write_tex_rid)
	uniforms.append(u2)
	var uniform_set_rid := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set_rid.is_valid():
		return
	# Push constant: vec2(8) + float(4) + uint(4) + int(4) + uint(4) = 24; pipeline expects 32 (alignment)
	var push_constant := PackedByteArray()
	push_constant.resize(32)
	push_constant.encode_float(0, chunk_origin.x)
	push_constant.encode_float(4, chunk_origin.y)
	push_constant.encode_float(8, chunk_size)
	push_constant.encode_u32(12, TEXTURE_SIZE)
	push_constant.encode_s32(16, jump_distance)
	push_constant.encode_u32(20, pass_index)

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set_rid, 0)
	rd.compute_list_set_push_constant(compute_list, push_constant, 32)
	var groups := int(ceilf(float(TEXTURE_SIZE) / float(WORK_GROUP_SIZE)))
	rd.compute_list_dispatch(compute_list, groups, groups, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	rd.free_rid(uniform_set_rid)


func _readback_texture(texture_rid: RID) -> Image:
	var data: PackedByteArray = rd.texture_get_data(texture_rid, 0)
	if data.is_empty():
		return null
	var rgba8 := PackedByteArray()
	rgba8.resize(TEXTURE_SIZE * TEXTURE_SIZE * 4)
	for i in range(TEXTURE_SIZE * TEXTURE_SIZE):
		var seed_id: int = data.decode_u32(i * 4)
		rgba8[i * 4 + 0] = (seed_id >> 24) & 0xFF
		rgba8[i * 4 + 1] = (seed_id >> 16) & 0xFF
		rgba8[i * 4 + 2] = (seed_id >> 8) & 0xFF
		rgba8[i * 4 + 3] = seed_id & 0xFF
	return Image.create_from_data(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8, rgba8)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rd:
			if pipeline_rid.is_valid():
				rd.free_rid(pipeline_rid)
				pipeline_rid = RID()
			if shader_rid.is_valid():
				rd.free_rid(shader_rid)
				shader_rid = RID()
