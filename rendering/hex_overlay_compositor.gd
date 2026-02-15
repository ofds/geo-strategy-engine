class_name HexOverlayCompositor
extends CompositorEffect
## Screen-space hex overlay: single fullscreen pass after opaque geometry.
## Reads depth, reconstructs world XZ, draws grid/hover/selection on frontmost surface only.
## Replaces next_pass hex overlay to fix doubled grid and see-through (see docs/PROGRESS.md).

# --- Uniforms (camera updates these every frame) ---
@export var hex_size: float = 1000.0
@export var show_grid: bool = true
@export var altitude: float = 0.0
var camera_position: Vector3 = Vector3.ZERO
var hovered_hex_center: Vector2 = Vector2(-999999.0, -999999.0)
var selected_hex_center: Vector2 = Vector2(-999999.0, -999999.0)
var selection_time: float = 0.0

# --- Internal ---
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _params_buffer: RID
var _depth_sampler: RID  # For SAMPLER_WITH_TEXTURE (depth texture)
const _PARAMS_SIZE: int = 256  # 64+64+rest, 16-byte aligned
var _params_bytes: PackedByteArray

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	access_resolved_color = true
	_rd = RenderingServer.get_rendering_device()
	_params_bytes = PackedByteArray()
	_params_bytes.resize(_PARAMS_SIZE)
	# Same defaults as config/constants.gd (terrain_loader / hex_grid)
	hex_size = Constants.HEX_SIZE_M
	show_grid = Constants.GRID_DEFAULT_VISIBLE
	_build_shader_and_buffer()

func _build_shader_and_buffer() -> void:
	if not _rd:
		return
	var path := "res://rendering/hex_overlay_screen.glsl"
	if not FileAccess.file_exists(path):
		push_error("HexOverlayCompositor: hex_overlay_screen.glsl not found")
		return
	var src := FileAccess.get_file_as_string(path)
	if src.is_empty():
		push_error("HexOverlayCompositor: empty shader source")
		return
	var rd_src := RDShaderSource.new()
	rd_src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	rd_src.source_compute = src
	var spirv := _rd.shader_compile_spirv_from_source(rd_src)
	if spirv.compile_error_compute != "":
		push_error("HexOverlayCompositor compile: " + spirv.compile_error_compute)
		return
	if _shader.is_valid():
		_rd.free_rid(_shader)
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		push_error("HexOverlayCompositor: shader create failed")
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	# Uniform buffer for Params (reused every frame, updated in _render_callback)
	if _params_buffer.is_valid():
		_rd.free_rid(_params_buffer)
	var buf_bytes := PackedByteArray()
	buf_bytes.resize(_PARAMS_SIZE)
	_params_buffer = _rd.uniform_buffer_create(_PARAMS_SIZE, buf_bytes)
	if not _params_buffer.is_valid():
		push_error("HexOverlayCompositor: params buffer create failed")
	# Sampler for depth texture (used with SAMPLER_WITH_TEXTURE)
	if _depth_sampler.is_valid():
		_rd.free_rid(_depth_sampler)
	var sampler_state := RDSamplerState.new()
	_depth_sampler = _rd.sampler_create(sampler_state)
	if not _depth_sampler.is_valid():
		push_error("HexOverlayCompositor: depth sampler create failed")

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _shader.is_valid():
			_rd.free_rid(_shader)
		if _params_buffer.is_valid():
			_rd.free_rid(_params_buffer)
		if _depth_sampler.is_valid():
			_rd.free_rid(_depth_sampler)

func _render_callback(p_effect_callback_type: int, p_render_data: RenderData) -> void:
	if not _rd or p_effect_callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT:
		return
	if not _pipeline.is_valid() or not _params_buffer.is_valid():
		return
	var buffers: RenderSceneBuffers = p_render_data.get_render_scene_buffers()
	if not buffers:
		return
	var buffers_rd: RenderSceneBuffersRD = buffers as RenderSceneBuffersRD
	if not buffers_rd:
		return
	var size: Vector2i = buffers_rd.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	# Camera matrices (view-to-world and inv projection for depth unprojection)
	var scene_data: RenderSceneData = p_render_data.get_render_scene_data()
	if not scene_data:
		return
	var cam_proj: Projection = scene_data.get_cam_projection()
	var cam_transform: Transform3D = scene_data.get_cam_transform()
	var inv_proj: Projection = cam_proj.inverse()
	# Pack Params: column-major inv_projection (64), column-major inv_view / camera transform (64), then scalars
	var ofs := 0
	# inv_projection (Godot Projection: x,y,z,w are columns) — pack col0, col1, col2, col3
	for col in [inv_proj.x, inv_proj.y, inv_proj.z, inv_proj.w]:
		_params_bytes.encode_float(ofs, col.x); _params_bytes.encode_float(ofs + 4, col.y); _params_bytes.encode_float(ofs + 8, col.z); _params_bytes.encode_float(ofs + 12, col.w)
		ofs += 16
	# inv_view = camera transform (view-to-world). Column-major: basis.x, basis.y, basis.z, origin
	var b := cam_transform.basis
	var o := cam_transform.origin
	_params_bytes.encode_float(ofs, b.x.x); _params_bytes.encode_float(ofs + 4, b.x.y); _params_bytes.encode_float(ofs + 8, b.x.z); _params_bytes.encode_float(ofs + 12, 0.0)
	ofs += 16
	_params_bytes.encode_float(ofs, b.y.x); _params_bytes.encode_float(ofs + 4, b.y.y); _params_bytes.encode_float(ofs + 8, b.y.z); _params_bytes.encode_float(ofs + 12, 0.0)
	ofs += 16
	_params_bytes.encode_float(ofs, b.z.x); _params_bytes.encode_float(ofs + 4, b.z.y); _params_bytes.encode_float(ofs + 8, b.z.z); _params_bytes.encode_float(ofs + 12, 0.0)
	ofs += 16
	_params_bytes.encode_float(ofs, o.x); _params_bytes.encode_float(ofs + 4, o.y); _params_bytes.encode_float(ofs + 8, o.z); _params_bytes.encode_float(ofs + 12, 1.0)
	ofs += 16
	# hex_size, show_grid (1.0=true), altitude, _pad0
	_params_bytes.encode_float(ofs, hex_size); ofs += 4
	_params_bytes.encode_float(ofs, 1.0 if show_grid else 0.0); ofs += 4
	_params_bytes.encode_float(ofs, altitude); ofs += 4
	_params_bytes.encode_float(ofs, 0.0); ofs += 4
	# camera_position (vec3), time (float)
	_params_bytes.encode_float(ofs, camera_position.x); _params_bytes.encode_float(ofs + 4, camera_position.y); _params_bytes.encode_float(ofs + 8, camera_position.z); ofs += 12
	_params_bytes.encode_float(ofs, Time.get_ticks_msec() / 1000.0); ofs += 4
	# hovered_hex_center, selected_hex_center
	_params_bytes.encode_float(ofs, hovered_hex_center.x); _params_bytes.encode_float(ofs + 4, hovered_hex_center.y); ofs += 8
	_params_bytes.encode_float(ofs, selected_hex_center.x); _params_bytes.encode_float(ofs + 4, selected_hex_center.y); ofs += 8
	_params_bytes.encode_float(ofs, selection_time); ofs += 4
	_params_bytes.encode_float(ofs, 0.0); ofs += 4
	_rd.buffer_update(_params_buffer, 0, _PARAMS_SIZE, _params_bytes)
	# Depth texture (resolved if MSAA)
	var depth_tex: RID = buffers_rd.get_depth_texture(false)
	if access_resolved_depth and buffers_rd.get_msaa_3d() != RenderingServer.VIEWPORT_MSAA_DISABLED:
		# When access_resolved_depth is true, use get_texture for resolved depth if API provides it
		if buffers_rd.has_texture(&"render_buffers", &"depth"):
			depth_tex = buffers_rd.get_texture(&"render_buffers", &"depth")
	if not depth_tex.is_valid():
		return
	var view_count := buffers_rd.get_view_count()
	for view in view_count:
		var color_image: RID = buffers_rd.get_color_layer(view)
		if not color_image.is_valid():
			continue
		var depth_for_view: RID = depth_tex
		if view_count > 1 and buffers_rd.has_texture(&"render_buffers", &"depth"):
			depth_for_view = buffers_rd.get_depth_layer(view, false)
		var u0 := RDUniform.new()
		u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u0.binding = 0
		u0.add_id(color_image)
		var u1 := RDUniform.new()
		u1.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u1.binding = 1
		u1.add_id(_depth_sampler)
		u1.add_id(depth_for_view)
		var u2 := RDUniform.new()
		u2.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		u2.binding = 2
		u2.add_id(_params_buffer)
		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [u0, u1, u2])
		var x_groups := int((size.x - 1) / 8) + 1
		var y_groups := int((size.y - 1) / 8) + 1
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		_rd.compute_list_end()
