class_name DistanceFieldGenerator
extends RefCounted
## GPU-based distance field texture generator for hex cells.
## Computes signed distance to nearest hex boundary using compute shader.

# ============================================================================
# CONSTANTS
# ============================================================================

const TEXTURE_SIZE := 512
const WORK_GROUP_SIZE := 16
const DISTANCE_NORMALIZE_M := 500.0

# ============================================================================
# RENDERING DEVICE RESOURCES
# ============================================================================

var rd: RenderingDevice = null
var shader_rid: RID
var pipeline_rid: RID

# ============================================================================
# INITIALIZATION
# ============================================================================

func _init() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		push_error("DistanceFieldGenerator: RenderingDevice not available.")
		return
	_compile_shader()
	_create_pipeline()


func _compile_shader() -> void:
	var path := "res://rendering/distance_field_generator.glsl"
	if not FileAccess.file_exists(path):
		push_error("DistanceFieldGenerator: Shader file not found: " + path)
		return
	var src := FileAccess.get_file_as_string(path)
	if src.is_empty():
		push_error("DistanceFieldGenerator: Empty shader source.")
		return
	var rd_src := RDShaderSource.new()
	rd_src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	rd_src.source_compute = src
	var spirv := rd.shader_compile_spirv_from_source(rd_src)
	if spirv.compile_error_compute != "":
		push_error("DistanceFieldGenerator: Shader compile error: " + spirv.compile_error_compute)
		return
	shader_rid = rd.shader_create_from_spirv(spirv)
	if not shader_rid.is_valid():
		push_error("DistanceFieldGenerator: Failed to create shader from SPIR-V.")


func _create_pipeline() -> void:
	if not rd or not shader_rid.is_valid():
		return
	pipeline_rid = rd.compute_pipeline_create(shader_rid)
	if not pipeline_rid.is_valid():
		push_error("DistanceFieldGenerator: Failed to create compute pipeline.")


# ============================================================================
# GENERATION
# ============================================================================

## Generate distance field texture for one chunk.
func generate(
	cell_texture: Texture2D,
	cell_centers: Array,
	chunk_origin: Vector2,
	chunk_size: float,
	hex_radius: float
) -> Texture2D:
	if not rd or not pipeline_rid.is_valid():
		push_error("DistanceFieldGenerator: Not initialized.")
		return null
	if cell_centers.is_empty():
		push_error("DistanceFieldGenerator: cell_centers is empty.")
		return null

	var cell_texture_rid := _create_cell_texture_gpu(cell_texture)
	if not cell_texture_rid.is_valid():
		return null
	var centers_buffer_rid := _create_centers_buffer_gpu(cell_centers)
	if not centers_buffer_rid.is_valid():
		rd.free_rid(cell_texture_rid)
		return null
	var output_texture_rid := _create_output_texture_gpu()
	if not output_texture_rid.is_valid():
		rd.free_rid(cell_texture_rid)
		rd.free_rid(centers_buffer_rid)
		return null

	var uniform_set_rid := _create_uniform_set(cell_texture_rid, centers_buffer_rid, output_texture_rid)
	if not uniform_set_rid.is_valid():
		rd.free_rid(cell_texture_rid)
		rd.free_rid(centers_buffer_rid)
		rd.free_rid(output_texture_rid)
		return null

	_dispatch_compute(uniform_set_rid, chunk_origin, chunk_size, hex_radius)
	var result_image := _readback_output_texture(output_texture_rid)

	rd.free_rid(cell_texture_rid)
	rd.free_rid(centers_buffer_rid)
	rd.free_rid(output_texture_rid)
	rd.free_rid(uniform_set_rid)

	if result_image:
		return ImageTexture.create_from_image(result_image)
	return null


# ============================================================================
# GPU RESOURCE CREATION
# ============================================================================

func _create_cell_texture_gpu(cell_texture: Texture2D) -> RID:
	var img: Image = cell_texture.get_image()
	if not img:
		push_error("DistanceFieldGenerator: Could not get image from cell texture.")
		return RID()
	var w := img.get_width()
	var h := img.get_height()
	if w != TEXTURE_SIZE or h != TEXTURE_SIZE:
		push_error("DistanceFieldGenerator: Cell texture must be %dx%d, got %dx%d" % [TEXTURE_SIZE, TEXTURE_SIZE, w, h])
		return RID()
	# Use RGBA8 format; shader expects rgba8ui (0-255 per channel)
	var format := RDTextureFormat.new()
	format.width = TEXTURE_SIZE
	format.height = TEXTURE_SIZE
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UINT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var view := RDTextureView.new()
	var data: PackedByteArray = img.get_data()
	return rd.texture_create(format, view, [data])


func _create_centers_buffer_gpu(cell_centers: Array) -> RID:
	var cell_count: int = cell_centers.size()
	# Layout: uint cell_count (4) + struct Cell { uint id; float cx; float cz; } per cell (12 each)
	var buffer_size: int = 4 + cell_count * 12
	var buffer_data := PackedByteArray()
	buffer_data.resize(buffer_size)
	buffer_data.encode_u32(0, cell_count)
	var offset := 4
	for cell in cell_centers:
		var cell_id: int = cell.get("cell_id", 0)
		var center_x: float = cell.get("center_x", 0.0)
		var center_z: float = cell.get("center_z", 0.0)
		buffer_data.encode_u32(offset, cell_id)
		offset += 4
		buffer_data.encode_float(offset, center_x)
		offset += 4
		buffer_data.encode_float(offset, center_z)
		offset += 4
	return rd.storage_buffer_create(buffer_size, buffer_data)


func _create_output_texture_gpu() -> RID:
	var format := RDTextureFormat.new()
	format.width = TEXTURE_SIZE
	format.height = TEXTURE_SIZE
	format.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var view := RDTextureView.new()
	return rd.texture_create(format, view)


func _create_uniform_set(cell_texture_rid: RID, centers_buffer_rid: RID, output_texture_rid: RID) -> RID:
	var uniforms: Array[RDUniform] = []
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u0.binding = 0
	u0.add_id(cell_texture_rid)
	uniforms.append(u0)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(centers_buffer_rid)
	uniforms.append(u1)
	var u2 := RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u2.binding = 2
	u2.add_id(output_texture_rid)
	uniforms.append(u2)
	return rd.uniform_set_create(uniforms, shader_rid, 0)


# ============================================================================
# DISPATCH
# ============================================================================

func _dispatch_compute(uniform_set_rid: RID, chunk_origin: Vector2, chunk_size: float, hex_radius: float) -> void:
	# Push constant: vec2 (8) + float (4) + float (4) + uint (4) = 20 bytes; pad to 32 for alignment
	var push_constant := PackedByteArray()
	push_constant.resize(32)
	push_constant.encode_float(0, chunk_origin.x)
	push_constant.encode_float(4, chunk_origin.y)
	push_constant.encode_float(8, chunk_size)
	push_constant.encode_float(12, hex_radius)
	push_constant.encode_u32(16, TEXTURE_SIZE)

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set_rid, 0)
	rd.compute_list_set_push_constant(compute_list, push_constant, 20)
	var x_groups := int(ceilf(float(TEXTURE_SIZE) / float(WORK_GROUP_SIZE)))
	var y_groups := int(ceilf(float(TEXTURE_SIZE) / float(WORK_GROUP_SIZE)))
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()


# ============================================================================
# READBACK
# ============================================================================

func _readback_output_texture(output_texture_rid: RID) -> Image:
	var data: PackedByteArray = rd.texture_get_data(output_texture_rid, 0)
	if data.is_empty():
		push_error("DistanceFieldGenerator: Failed to read back texture data.")
		return null
	return Image.create_from_data(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_L8, data)


# ============================================================================
# CLEANUP
# ============================================================================

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rd:
			if pipeline_rid.is_valid():
				rd.free_rid(pipeline_rid)
				pipeline_rid = RID()
			if shader_rid.is_valid():
				rd.free_rid(shader_rid)
				shader_rid = RID()
