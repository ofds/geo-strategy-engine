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
## 0=off, 1=raw depth (bright=near), 2=world XZ pattern. Use to debug grid drift.
@export var debug_visualization: float = 0.0
## If true, show depth gradient (red=near, blue=far) and skip grid. Use to verify depth texture.
@export var debug_depth: bool = false
## If depth is "all dark", try true to use (1 - depth) as NDC z.
@export var depth_ndc_flip: bool = false
## If true, use resolved depth texture instead of raw. Try this if debug depth shows solid blue (raw = 0).
@export var use_resolved_depth: bool = false
## If true, compositor draws grid lines; false = grid in terrain shader only (selection/hover here).
@export var draw_grid_lines: bool = false

# --- Internal ---
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _params_buffer: RID
var _depth_sampler: RID  # For SAMPLER_WITH_TEXTURE (depth texture)
const _PARAMS_SIZE: int = 256  # 64+64+rest, 16-byte aligned
var _params_bytes: PackedByteArray
var _matrices_verified: bool = false

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
	# Two-step unproject: clip -> view (inv_projection) then view -> world (inv_view = cam transform)
	var scene_data: RenderSceneData = p_render_data.get_render_scene_data()
	if not scene_data:
		return
	var view_proj: Projection = scene_data.get_view_projection(0)
	var cam_transform: Transform3D = scene_data.get_cam_transform()
	var o := cam_transform.origin
	# P = view_proj * V^-1; V = inverse(cam), so P = view_proj * Projection(cam_transform)
	var proj_cam: Projection = Projection(cam_transform)
	var proj_only: Projection = view_proj * proj_cam
	var inv_proj: Projection = proj_only.inverse()
	# inv_view = camera to world = cam_transform (4x4)
	var basis := cam_transform.basis
	var origin := cam_transform.origin

	# One-time matrix verification
	if not _matrices_verified:
		if OS.is_debug_build():
			print("HexOverlayCompositor inv_proj diagonal: ", inv_proj.x.x, ", ", inv_proj.y.y, ", ", inv_proj.z.z, ", ", inv_proj.w.w)
			print("HexOverlayCompositor inv_view (cam) origin: ", origin.x, ", ", origin.y, ", ", origin.z)
		_matrices_verified = true

	# Pack Params: inv_projection (64) + inv_view as 4 columns (64), then scalars at 128
	var ofs := 0
	for col in [inv_proj.x, inv_proj.y, inv_proj.z, inv_proj.w]:
		_params_bytes.encode_float(ofs, col.x); _params_bytes.encode_float(ofs + 4, col.y); _params_bytes.encode_float(ofs + 8, col.z); _params_bytes.encode_float(ofs + 12, col.w)
		ofs += 16
	# inv_view from Transform3D: columns 0,1,2 = basis (w=0), column 3 = origin (w=1)
	_params_bytes.encode_float(ofs, basis.x.x); _params_bytes.encode_float(ofs + 4, basis.x.y); _params_bytes.encode_float(ofs + 8, basis.x.z); _params_bytes.encode_float(ofs + 12, 0.0); ofs += 16
	_params_bytes.encode_float(ofs, basis.y.x); _params_bytes.encode_float(ofs + 4, basis.y.y); _params_bytes.encode_float(ofs + 8, basis.y.z); _params_bytes.encode_float(ofs + 12, 0.0); ofs += 16
	_params_bytes.encode_float(ofs, basis.z.x); _params_bytes.encode_float(ofs + 4, basis.z.y); _params_bytes.encode_float(ofs + 8, basis.z.z); _params_bytes.encode_float(ofs + 12, 0.0); ofs += 16
	_params_bytes.encode_float(ofs, origin.x); _params_bytes.encode_float(ofs + 4, origin.y); _params_bytes.encode_float(ofs + 8, origin.z); _params_bytes.encode_float(ofs + 12, 1.0); ofs += 16
	# hex_size, show_grid (1.0=true), altitude, _pad0
	_params_bytes.encode_float(ofs, hex_size); ofs += 4
	_params_bytes.encode_float(ofs, 1.0 if show_grid else 0.0); ofs += 4
	_params_bytes.encode_float(ofs, altitude); ofs += 4
	_params_bytes.encode_float(ofs, 1.0 if depth_ndc_flip else 0.0); ofs += 4
	# camera_position (vec3): use render camera origin for camera-relative hex math
	_params_bytes.encode_float(ofs, o.x); _params_bytes.encode_float(ofs + 4, o.y); _params_bytes.encode_float(ofs + 8, o.z); ofs += 12
	_params_bytes.encode_float(ofs, Time.get_ticks_msec() / 1000.0); ofs += 4
	# hovered_hex_center, selected_hex_center
	_params_bytes.encode_float(ofs, hovered_hex_center.x); _params_bytes.encode_float(ofs + 4, hovered_hex_center.y); ofs += 8
	_params_bytes.encode_float(ofs, selected_hex_center.x); _params_bytes.encode_float(ofs + 4, selected_hex_center.y); ofs += 8
	_params_bytes.encode_float(ofs, selection_time); ofs += 4
	_params_bytes.encode_float(ofs, debug_visualization); ofs += 4
	_params_bytes.encode_float(ofs, 1.0 if debug_depth else 0.0); ofs += 4
	_params_bytes.encode_float(ofs, 1.0 if use_resolved_depth else 0.0); ofs += 4
	_params_bytes.encode_float(ofs, 1.0 if draw_grid_lines else 0.0); ofs += 4
	_rd.buffer_update(_params_buffer, 0, _PARAMS_SIZE, _params_bytes)
	# Depth texture: raw (false) or resolved (true). If debug depth is solid blue, try use_resolved_depth = true.
	var depth_tex: RID = buffers_rd.get_depth_texture(use_resolved_depth)
	if not depth_tex.is_valid():
		return
	var view_count := buffers_rd.get_view_count()
	for view in view_count:
		var color_image: RID = buffers_rd.get_color_layer(view)
		if not color_image.is_valid():
			continue
		# Use this view's depth layer so we read the buffer that was actually written for this view
		var depth_for_view: RID = buffers_rd.get_depth_layer(view, use_resolved_depth) if view_count > 0 else depth_tex
		if not depth_for_view.is_valid():
			depth_for_view = depth_tex
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
		var x_groups := ceili(float(size.x - 1) / 8.0)
		var y_groups := ceili(float(size.y - 1) / 8.0)
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		_rd.compute_list_end()
