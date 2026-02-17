class_name VoronoiDistanceFieldGenerator
extends RefCounted
## GPU distance-to-boundary for Voronoi cell texture (neighbor sampling, no hex SDF).

const TEXTURE_SIZE := 512
const WORK_GROUP_SIZE := 16

var rd: RenderingDevice = null
var shader_rid: RID
var pipeline_rid: RID

func _init() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		push_error("VoronoiDistanceFieldGenerator: RenderingDevice not available.")
		return
	_compile_shader()
	_create_pipeline()


func _compile_shader() -> void:
	var path := "res://rendering/voronoi_distance_field.glsl"
	if not FileAccess.file_exists(path):
		push_error("VoronoiDistanceFieldGenerator: Shader file not found: " + path)
		return
	var src := FileAccess.get_file_as_string(path)
	if src.is_empty():
		push_error("VoronoiDistanceFieldGenerator: Empty shader source.")
		return
	var rd_src := RDShaderSource.new()
	rd_src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	rd_src.source_compute = src
	var spirv := rd.shader_compile_spirv_from_source(rd_src)
	if spirv.compile_error_compute != "":
		push_error("VoronoiDistanceFieldGenerator: " + spirv.compile_error_compute)
		return
	shader_rid = rd.shader_create_from_spirv(spirv)
	if not shader_rid.is_valid():
		push_error("VoronoiDistanceFieldGenerator: Failed to create shader.")


func _create_pipeline() -> void:
	if not rd or not shader_rid.is_valid():
		return
	pipeline_rid = rd.compute_pipeline_create(shader_rid)
	if not pipeline_rid.is_valid():
		push_error("VoronoiDistanceFieldGenerator: Failed to create pipeline.")


## Generate distance field from Voronoi cell texture.
## cell_texture: Texture2D RGBA8 (cell IDs). Returns R8 ImageTexture (0-1 = 0-500m).
func generate(cell_texture: Texture2D, chunk_origin: Vector2, chunk_size: float) -> Texture2D:
	if not rd or not pipeline_rid.is_valid():
		return null
	var img: Image = cell_texture.get_image()
	if not img or img.get_width() != TEXTURE_SIZE or img.get_height() != TEXTURE_SIZE:
		push_error("VoronoiDistanceFieldGenerator: Cell texture must be %dx%d." % [TEXTURE_SIZE, TEXTURE_SIZE])
		return null

	var cell_rid := _create_cell_texture_rd(img)
	var output_rid := _create_output_texture_rd()
	if not cell_rid.is_valid() or not output_rid.is_valid():
		if cell_rid.is_valid(): rd.free_rid(cell_rid)
		if output_rid.is_valid(): rd.free_rid(output_rid)
		return null

	var uniform_set_rid := _create_uniform_set(cell_rid, output_rid)
	if not uniform_set_rid.is_valid():
		if cell_rid.is_valid(): rd.free_rid(cell_rid)
		if output_rid.is_valid(): rd.free_rid(output_rid)
		return null

	_dispatch(chunk_origin, chunk_size, uniform_set_rid)
	var result_image := _readback(output_rid)
	if cell_rid.is_valid(): rd.free_rid(cell_rid)
	if output_rid.is_valid(): rd.free_rid(output_rid)
	if uniform_set_rid.is_valid(): rd.free_rid(uniform_set_rid)

	if result_image:
		return ImageTexture.create_from_image(result_image)
	return null


func _create_cell_texture_rd(img: Image) -> RID:
	var format := RDTextureFormat.new()
	format.width = TEXTURE_SIZE
	format.height = TEXTURE_SIZE
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UINT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var data: PackedByteArray = img.get_data()
	return rd.texture_create(format, RDTextureView.new(), [data])


func _create_output_texture_rd() -> RID:
	var format := RDTextureFormat.new()
	format.width = TEXTURE_SIZE
	format.height = TEXTURE_SIZE
	format.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return rd.texture_create(format, RDTextureView.new())


func _create_uniform_set(cell_rid: RID, output_rid: RID) -> RID:
	var uniforms: Array[RDUniform] = []
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u0.binding = 0
	u0.add_id(cell_rid)
	uniforms.append(u0)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u1.binding = 1
	u1.add_id(output_rid)
	uniforms.append(u1)
	return rd.uniform_set_create(uniforms, shader_rid, 0)


func _dispatch(chunk_origin: Vector2, chunk_size: float, uniform_set_rid: RID) -> void:
	# Push constant: vec2(8) + float(4) + uint(4) = 16 bytes (pipeline expects 16)
	var push_constant := PackedByteArray()
	push_constant.resize(16)
	push_constant.encode_float(0, chunk_origin.x)
	push_constant.encode_float(4, chunk_origin.y)
	push_constant.encode_float(8, chunk_size)
	push_constant.encode_u32(12, TEXTURE_SIZE)

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set_rid, 0)
	rd.compute_list_set_push_constant(compute_list, push_constant, 16)
	var groups := int(ceilf(float(TEXTURE_SIZE) / float(WORK_GROUP_SIZE)))
	rd.compute_list_dispatch(compute_list, groups, groups, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()


func _readback(output_rid: RID) -> Image:
	var data: PackedByteArray = rd.texture_get_data(output_rid, 0)
	if data.is_empty():
		return null
	return Image.create_from_data(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_L8, data)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rd:
			if pipeline_rid.is_valid():
				rd.free_rid(pipeline_rid)
				pipeline_rid = RID()
			if shader_rid.is_valid():
				rd.free_rid(shader_rid)
				shader_rid = RID()
