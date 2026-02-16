extends Node3D
## Chunk Manager - Simple, reliable terrain streaming
## Every 0.5s: determine desired chunks, load closest 4, unload unwanted

# LOD/streaming: single source of truth in config/constants.gd
const _Const := preload("res://config/constants.gd")

# References
var terrain_loader: TerrainLoader = null
var camera: Camera3D = null
var chunks_container: Node3D = null
var collision_body: StaticBody3D = null
var loading_screen = null

# Loaded chunks: Key = "lod{L}_x{X}_y{Y}", Value = {node: Node3D, lod: int, x: int, y: int}
var loaded_chunks: Dictionary = {}

# Load queue: chunks to load one per frame (array of {lod, x, y}), sorted by distance closest first
var load_queue: Array = []

# Async: task_id -> { chunk_key, lod, x, y, args }. Base 4; 8 when queue large.
var pending_loads: Dictionary = {}
const MAX_CONCURRENT_ASYNC_LOADS_BASE: int = 4
const MAX_CONCURRENT_ASYNC_LOADS_LARGE: int = 8
const LARGE_QUEUE_THRESHOLD: int = 20
# Chunks currently loading (key -> true) so we don't re-queue them
var loading_chunk_keys: Dictionary = {}
# Desired set from last _update_chunks; used to discard completed loads that are no longer wanted
var last_desired: Dictionary = {}

# Update timer and adaptive frequency
var update_timer: float = 0.0
const UPDATE_INTERVAL_IDLE: float = 0.5
const UPDATE_INTERVAL_LOADING: float = 0.25
var current_update_interval: float = 0.5

# Initial load: when true, we're still loading the first desired set (async from queue)
var initial_load_complete: bool = false
var initial_load_in_progress: bool = false
var initial_desired: Dictionary = {}  # desired set at startup; used for progress and "still wanted"

# LOD/streaming: use _Const (preload of config/constants.gd) so LSP/analyzer resolves members
# Grid size and resolution from metadata (set in _ready from TerrainLoader)
var _lod0_grid: Vector2i = Vector2i(32, 18) # Fallback for Alps; overwritten from metadata
var _resolution_m: float = 90.0 # LOD 0 meters per pixel (from metadata)
const MAX_LOADS_PER_UPDATE: int = 8 # Increased from 4 for faster loading
const DEFERRED_UNLOAD_TIMEOUT_S: float = 5.0 # Normal: unload after 5s
const DEFERRED_UNLOAD_TIMEOUT_LARGE_MOVE_S: float = 1.0 # When camera jumped >200km: unload sooner
const LARGE_MOVE_THRESHOLD_M: float = 200000.0 # >200km in one update = region change / fast zoom-out
const BURST_UNLOAD_SPREAD_FRAMES: int = 3 # Spread >10 unloads across this many frames
const BURST_UNLOAD_THRESHOLD: int = 10
const FRAME_BUDGET_MS: float = 8.0 # Allow terrain to load; 8ms still permits 120+ FPS when idle
const INITIAL_LOAD_BUDGET_MS: float = 16.0 # Larger budget during initial load to avoid one-frame spike

# Pending Phase B work: each entry { computed, chunk_key, lod, x, y, step (0=MESH, 1=SCENE, 2=COLLISION), mesh, mesh_instance }
var _pending_phase_b: Array = []
var _last_phase_b_ms: float = 0.0 # For FPS counter / perf warning

# Hysteresis tracking: Key = "lod0_x_y", Value = current_lod
var lod_hysteresis_state: Dictionary = {}

# Deferred unload tracking: Key = chunk_key, Value = timestamp when deferred
var deferred_unload_times: Dictionary = {}
# Frame start time for budget calculation (set at top of _process)
var _process_frame_start_msec: int = 0
# Set in _exit_tree so we never block on WorkerThreadPool when editor/game stops (avoids freeze)
var _exiting: bool = false

# Set true in Inspector to print [TIME] Desired set / Total cycle (e.g. for Europe scale verification)
@export var DEBUG_STREAMING_TIMING: bool = false

# Set true to print [DIAG] [LOAD] [FRAME] once per second (diagnostic)
@export var DEBUG_DIAGNOSTIC: bool = false
var _diagnostic_timer: float = 0.0
var _diagnostic_phase_b_steps_this_sec: int = 0
var _diagnostic_phase_b_skipped_budget: int = 0
var _diagnostic_frame_times: Array = []

# DIAGNOSTIC: Camera position tracking for stability detection
var diagnostic_last_camera_pos: Vector3 = Vector3.ZERO
var diagnostic_camera_stable_count: int = 0

# DIAGNOSTIC: Desired set tracking for determinism verification
var diagnostic_last_lod0_cells_str: String = ""
var diagnostic_last_desired_camera_pos: Vector3 = Vector3.ZERO
# Cells considered in last desired-set calculation (bounding box size)
var _last_desired_box_cells: int = 0
# Bounding box from last _determine_desired_chunks (for diagnostic gap detection)
var _last_min_cx: int = 0
var _last_max_cx: int = 0
var _last_min_cy: int = 0
var _last_max_cy: int = 0
# Visible radius (altitude-scaled) from last desired set; used for smart unload
var _last_visible_radius: float = 500000.0
# Camera position from previous _update_chunks for large-move detection
var _last_update_camera_pos: Vector3 = Vector3.ZERO
# Deferred unload: spread burst unloads across frames
var _pending_unload_keys: Array = []
# Debug D key: only dump once per press (not every frame while held)
var _debug_d_was_pressed: bool = false
# Last chunk key that completed Phase B (for loading screen label — Fix 3)
var _last_phase_b_completed_chunk_key: String = ""


func _ready() -> void:
	terrain_loader = get_node_or_null("../TerrainLoader")
	if not terrain_loader:
		push_error("ChunkManager: TerrainLoader not found!")
		return
	
	await get_tree().process_frame
	
	# Grid and resolution from terrain metadata (supports Europe 90m and Alps 30m)
	_resolution_m = terrain_loader.resolution_m
	var mw = terrain_loader.terrain_metadata.get("master_heightmap_width", 16384)
	var mh = terrain_loader.terrain_metadata.get("master_heightmap_height", 9216)
	_lod0_grid = Vector2i((mw + 511) / 512, (mh + 511) / 512)
	if OS.is_debug_build():
		print("ChunkManager: LOD0 grid %d×%d, resolution %.1f m/px" % [_lod0_grid.x, _lod0_grid.y, _resolution_m])
	
	# Continental overview plane (instant, gap-free at high zoom) — add first so chunks render on top
	_setup_overview_plane()
	
	chunks_container = Node3D.new()
	chunks_container.name = "TerrainChunks"
	add_child(chunks_container)
	
	collision_body = StaticBody3D.new()
	collision_body.name = "TerrainCollision"
	collision_body.collision_layer = 1
	collision_body.collision_mask = 0
	add_child(collision_body)
	
	camera = get_viewport().get_camera_3d()
	if not camera:
		push_error("ChunkManager: No camera found!")
		return
	
	await get_tree().process_frame
	await get_tree().process_frame
	
	loading_screen = get_node_or_null("/root/TerrainDemo/LoadingScreen")
	if not loading_screen:
		loading_screen = get_node_or_null("/root/Node3D/LoadingScreen")
	if loading_screen:
		await get_tree().process_frame
	
	if OS.is_debug_build():
		print("\n=== ChunkManager: Initial Load (async) ===")
	_initial_load()
	# initial_load_complete set in _process when initial_desired is fully loaded


func _setup_overview_plane() -> void:
	"""If metadata has overview_texture, add a flat quad at Y=-20 aligned with chunk grid: world (0,0) = NW corner.
	Use chunk grid extent (same as chunk positions) so overview and terrain cannot be out of sync."""
	if not terrain_loader:
		return
	var meta = terrain_loader.terrain_metadata
	if not meta.get("overview_texture", ""):
		return
	var terrain_path: String = Constants.TERRAIN_DATA_PATH
	var tex_path: String = terrain_path + meta.overview_texture
	if not FileAccess.file_exists(tex_path):
		push_warning("ChunkManager: Overview texture not found: " + tex_path)
		return
	var img: Image = Image.load_from_file(tex_path)
	if not img or img.is_empty():
		push_warning("ChunkManager: Failed to load overview image")
		return
	var tex = ImageTexture.create_from_image(img)
	# Use same extent as chunk grid (LOD0 grid × 512 × resolution) so macro view aligns with chunks
	const CHUNK_PX: int = 512
	var overview_w: float = float(_lod0_grid.x * CHUNK_PX) * _resolution_m
	var overview_h: float = float(_lod0_grid.y * CHUNK_PX) * _resolution_m
	if overview_w <= 0.0 or overview_h <= 0.0:
		push_warning("ChunkManager: Invalid overview dimensions (grid %dx%d)" % [_lod0_grid.x, _lod0_grid.y])
		return
	# Quad from (0,0) to (overview_w, overview_h) in XZ so overview aligns with chunk grid (chunk 0,0 at world 0,0)
	var verts = PackedVector3Array()
	verts.append(Vector3(0.0, 0.0, 0.0))
	verts.append(Vector3(overview_w, 0.0, 0.0))
	verts.append(Vector3(overview_w, 0.0, overview_h))
	verts.append(Vector3(0.0, 0.0, overview_h))
	var normals = PackedVector3Array()
	for _i in range(4):
		normals.append(Vector3.UP)
	# UV: image row 0 = north (world Z=0). Godot texture v=0 is typically bottom, so flip V so north maps to Z=0
	var uvs = PackedVector2Array()
	uvs.append(Vector2(0.0, 1.0))   # (0,0,0) NW -> texture top-left (north)
	uvs.append(Vector2(1.0, 1.0))   # (W,0,0) NE
	uvs.append(Vector2(1.0, 0.0))   # (W,0,H) SE
	uvs.append(Vector2(0.0, 0.0))   # (0,0,H) SW
	# Winding: front face = top of quad (normal +Y); CCW when viewed from above
	var indices = PackedInt32Array()
	indices.append(0)
	indices.append(3)
	indices.append(2)
	indices.append(0)
	indices.append(2)
	indices.append(1)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var quad_mesh = ArrayMesh.new()
	quad_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = tex
	var overview_instance = MeshInstance3D.new()
	overview_instance.name = "OverviewPlane"
	overview_instance.mesh = quad_mesh
	overview_instance.material_override = mat
	overview_instance.position = Vector3(0.0, -20.0, 0.0)
	overview_instance.add_to_group("overview_plane")
	add_child(overview_instance)
	if OS.is_debug_build():
		print("ChunkManager: Overview plane added (%.0f × %.0f m, Y=-20, corner at world 0,0)" % [overview_w, overview_h])


func _exit_tree() -> void:
	_exiting = true
	# Don't wait for WorkerThreadPool tasks; abandon pending work so stop/close doesn't freeze
	pending_loads.clear()
	loading_chunk_keys.clear()
	_pending_phase_b.clear()
	load_queue.clear()


func _process(delta: float) -> void:
	if _exiting:
		return
	_process_frame_start_msec = Time.get_ticks_msec()
	# During initial load: only drive async load and progress; no streaming yet
	if initial_load_in_progress:
		_process_initial_load()
		return
	
	if not initial_load_complete:
		return
	
	# D key (without Shift): dump state once per key press, not every frame while held
	var d_pressed = Input.is_key_pressed(KEY_D) and not Input.is_key_pressed(KEY_SHIFT)
	if d_pressed and not _debug_d_was_pressed:
		_debug_dump_state()
	_debug_d_was_pressed = d_pressed
	
	update_timer += delta
	if update_timer >= current_update_interval:
		update_timer = 0.0
		_update_chunks()

	# Fix 1 (audit 3.1): Per-frame visibility while streaming so grid never doubles during active load
	if _pending_phase_b.size() > 0 or load_queue.size() > 0:
		_update_chunk_visibility()

	# Process pending unloads (spread burst across frames)
	_process_pending_unloads()

	# Drain completed async tasks into pending Phase B queue (cheap)
	_drain_completed_async_to_phase_b()

	# Frame-budget-aware Phase B: do micro-steps until budget is used; when zoomed in do more steps so LOD 0 appears faster
	var frame_start = Time.get_ticks_msec()
	var time_used = frame_start - _process_frame_start_msec
	var budget_remaining = FRAME_BUDGET_MS - time_used
	_last_phase_b_ms = 0.0
	var steps_done = 0
	var min_steps_this_frame: int = 1
	if _get_camera_altitude() < 15000.0 and _pending_phase_b.size() > 2:
		min_steps_this_frame = 3  # Drain Phase B faster when close to terrain
	while _has_pending_phase_b_work():
		var do_step = (budget_remaining > 1.0) or (steps_done < min_steps_this_frame)
		if not do_step:
			if DEBUG_DIAGNOSTIC:
				_diagnostic_phase_b_skipped_budget += 1
			break
		var budget_at_start = budget_remaining
		var step_start = Time.get_ticks_msec()
		var diag_entry = _pending_phase_b[0] if _pending_phase_b.size() > 0 else null
		var diag_step = diag_entry["step"] if diag_entry else 0
		var diag_key = diag_entry["chunk_key"] if diag_entry else ""
		var diag_verts = 0
		if diag_entry and diag_entry.has("computed"):
			var comp = diag_entry["computed"]
			if comp.get("ultra_lod", false):
				diag_verts = 4
			elif comp.has("vertices"):
				diag_verts = comp["vertices"].size()
		_do_one_phase_b_step()
		var step_time = Time.get_ticks_msec() - step_start
		_last_phase_b_ms += step_time
		budget_remaining -= step_time
		steps_done += 1
		if DEBUG_DIAGNOSTIC and diag_key != "":
			var step_name = "MESH" if diag_step == 0 else "SCENE" if diag_step == 1 else "COLLISION"
			print("[LOAD] %s step=%s time=%dms vertices=%d" % [diag_key, step_name, int(step_time), diag_verts])
		if DEBUG_DIAGNOSTIC:
			_diagnostic_phase_b_steps_this_sec += 1
		if step_time > budget_at_start:
			break

	# Diagnostic: once per second (DEBUG_DIAGNOSTIC)
	if DEBUG_DIAGNOSTIC:
		_diagnostic_timer += delta
		_diagnostic_frame_times.append(delta * 1000.0)
		if _diagnostic_frame_times.size() > 120:
			_diagnostic_frame_times.remove_at(0)
		if _diagnostic_timer >= 1.0:
			_diagnostic_timer = 0.0
			var alt_used = _get_camera_altitude()
			const ALTITUDE_LOD0_MAX_M_DIAG: float = 70000.0
			var above_70km = alt_used > ALTITUDE_LOD0_MAX_M_DIAG
			# Desired set counts by LOD
			var desired_lod_counts = [0, 0, 0, 0, 0]
			for k in last_desired.keys():
				desired_lod_counts[last_desired[k].lod] += 1
			# Loaded LOD counts
			var lod_counts = [0, 0, 0, 0, 0]
			for k in loaded_chunks.keys():
				lod_counts[loaded_chunks[k].lod] += 1
			# Nearest loaded chunk to camera (ground position)
			var cam_ground = _get_camera_ground_position()
			var nearest_key: String = ""
			var nearest_dist_km: float = 999999.0
			for k in loaded_chunks.keys():
				var info = loaded_chunks[k]
				var center = _get_chunk_center_world(info.x, info.y, info.lod)
				var d = Vector2(center.x - cam_ground.x, center.z - cam_ground.z).length() / 1000.0
				if d < nearest_dist_km:
					nearest_dist_km = d
					nearest_key = k
			print("[LOD] Camera alt: %.1fkm | Nearest chunk: %s dist=%.1fkm | Desired LODs in view: L0=%d L1=%d L2=%d L3=%d L4=%d" %
				[alt_used / 1000.0, "none" if nearest_key.is_empty() else nearest_key, nearest_dist_km,
				desired_lod_counts[0], desired_lod_counts[1], desired_lod_counts[2], desired_lod_counts[3], desired_lod_counts[4]])
			# Stage 6: Nearest chunks with LOD and vertex count (verify LOD 0 has ~262k vertices)
			var nearest_list: Array = []
			for k in loaded_chunks.keys():
				var info = loaded_chunks[k]
				var center = _get_chunk_center_world(info.x, info.y, info.lod)
				var d_km: float = Vector2(center.x - cam_ground.x, center.z - cam_ground.z).length() / 1000.0
				nearest_list.append({"key": k, "dist_km": d_km, "lod": info.lod, "node": info.node})
			nearest_list.sort_custom(func(a, b): return a.dist_km < b.dist_km)
			var mesh_line: String = "[MESH] Nearest chunks: "
			for i in range(mini(5, nearest_list.size())):
				var e = nearest_list[i]
				var vert_count: int = 0
				if e.node and e.node is MeshInstance3D:
					var m = (e.node as MeshInstance3D).mesh
					if m is ArrayMesh and m.get_surface_count() > 0:
						var arr = m.surface_get_arrays(0)
						if arr != null and arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null:
							vert_count = arr[Mesh.ARRAY_VERTEX].size()
				mesh_line += "%s (dist=%.1fkm verts=%d)" % [e.key, e.dist_km, vert_count]
				if i < mini(5, nearest_list.size()) - 1:
					mesh_line += ", "
			print(mesh_line)
			var mesh_n = 0
			var scene_n = 0
			var coll_n = 0
			for e in _pending_phase_b:
				if e["step"] == 0: mesh_n += 1
				elif e["step"] == 1: scene_n += 1
				else: coll_n += 1
			var front_str: String = "empty"
			if load_queue.size() > 0:
				var front = load_queue[0]
				front_str = "lod%d_x%d_y%d" % [front.lod, front.x, front.y]
			print("[LOD] Queue: %d items | Front: %s | Pending PhaseB: %d (MESH=%d SCENE=%d COLL=%d)" %
				[load_queue.size(), front_str, _pending_phase_b.size(), mesh_n, scene_n, coll_n])
			var min_lod_allowed: int = 0 if not above_70km else 1
			print("[LOD] Min LOD allowed: %d | Altitude gate: above70km=%s (alt=%.1fkm)" %
				[min_lod_allowed, "Y" if above_70km else "N", alt_used / 1000.0])
			print("[DIAG] Chunks: loaded=%d desired=%d queue=%d pending_async=%d steps_this_sec=%d skipped_budget=%d" %
				[loaded_chunks.size(), last_desired.size(), load_queue.size(), pending_loads.size(), _diagnostic_phase_b_steps_this_sec, _diagnostic_phase_b_skipped_budget])
			if _diagnostic_frame_times.size() > 0:
				var sum_f = 0.0
				var worst_f = 0.0
				for t in _diagnostic_frame_times:
					sum_f += t
					if t > worst_f: worst_f = t
				var avg_f = sum_f / float(_diagnostic_frame_times.size())
				print("[FRAME] avg=%.2fms worst=%.2fms" % [avg_f, worst_f])
			_diagnostic_phase_b_steps_this_sec = 0
			_diagnostic_phase_b_skipped_budget = 0

	# Submit one new async load if queue has work and we have capacity
	if load_queue.size() > 0 and pending_loads.size() < _get_max_concurrent_loads():
		var info = load_queue.pop_front()
		var key = "lod%d_x%d_y%d" % [info.lod, info.x, info.y]
		if not loaded_chunks.has(key) and not loading_chunk_keys.has(key):
			loading_chunk_keys[key] = true
			var async_result = terrain_loader.start_async_load(info.x, info.y, info.lod, DEBUG_DIAGNOSTIC)
			var task_id: int = async_result["task_id"]
			var args: Dictionary = async_result["args"]
			pending_loads[task_id] = {"chunk_key": key, "lod": info.lod, "x": info.x, "y": info.y, "args": args}
			if DEBUG_STREAMING_TIMING:
				print("[LOAD] Loading lod%d_x%d_y%d (queue: %d remaining)" % [info.lod, info.x, info.y, load_queue.size()])
	return


## Run during initial load: drain completed into pending Phase B, do stepped Phase B within budget, submit new loads, detect done.
func _process_initial_load() -> void:
	if _exiting:
		return
	var want_count = initial_desired.size()
	# Drain completed async into _pending_phase_b (same as streaming; use initial_desired for "still wanted")
	var completed_ids: Array = []
	for tid in pending_loads.keys():
		if WorkerThreadPool.is_task_completed(tid):
			completed_ids.append(tid)
	for tid in completed_ids:
		if _exiting:
			return
		var entry = pending_loads[tid]
		pending_loads.erase(tid)
		var chunk_key: String = entry.chunk_key
		loading_chunk_keys.erase(chunk_key)
		WorkerThreadPool.wait_for_task_completion(tid)
		if _exiting:
			return
		var computed = entry.args["result"]
		if not computed.is_empty() and initial_desired.has(chunk_key):
			var path_for_cache: String = computed.get("path_for_cache", "")
			var heights_for_cache = computed.get("heights_for_cache", [])
			if path_for_cache != "" and heights_for_cache.size() > 0:
				terrain_loader._add_to_height_cache(path_for_cache, heights_for_cache)
			_pending_phase_b.append({
				"computed": computed,
				"chunk_key": chunk_key,
				"lod": entry.lod,
				"x": entry.x,
				"y": entry.y,
				"step": 0,
				"mesh": null,
				"mesh_instance": null,
				"initial_load": true
			})
	# Do Phase B steps within initial-load budget; guarantee at least 1 step when work pending
	var time_used = Time.get_ticks_msec() - _process_frame_start_msec
	var budget_remaining = INITIAL_LOAD_BUDGET_MS - time_used
	_last_phase_b_ms = 0.0
	var initial_steps_done = 0
	while _has_pending_phase_b_work():
		var entry = _pending_phase_b[0]
		if entry.get("initial_load") != true:
			break
		var do_step = (budget_remaining > 1.0) or (initial_steps_done == 0)
		if not do_step:
			break
		var budget_at_start = budget_remaining
		var step_start = Time.get_ticks_msec()
		_do_one_phase_b_step()
		var step_time = Time.get_ticks_msec() - step_start
		_last_phase_b_ms += step_time
		budget_remaining -= step_time
		initial_steps_done += 1
		if step_time > budget_at_start:
			break
	# Update loading screen with meaningful chunk label (last completed or current in progress)
	if loading_screen:
		var display_chunk: String = _last_phase_b_completed_chunk_key
		if display_chunk.is_empty() and _pending_phase_b.size() > 0:
			display_chunk = _pending_phase_b[0].chunk_key
		if display_chunk.is_empty():
			display_chunk = "..."
		loading_screen.update_progress(loaded_chunks.size(), want_count, display_chunk)
	# Submit up to cap so we keep tasks in flight
	while load_queue.size() > 0 and pending_loads.size() < _get_max_concurrent_loads():
		var info = load_queue.pop_front()
		var key = "lod%d_x%d_y%d" % [info.lod, info.x, info.y]
		if loaded_chunks.has(key) or loading_chunk_keys.has(key):
			continue
		loading_chunk_keys[key] = true
		var async_result = terrain_loader.start_async_load(info.x, info.y, info.lod, DEBUG_DIAGNOSTIC)
		var task_id: int = async_result["task_id"]
		var args: Dictionary = async_result["args"]
		pending_loads[task_id] = {"chunk_key": key, "lod": info.lod, "x": info.x, "y": info.y, "args": args}
	# Done when we have every chunk from initial_desired
	var have_all = true
	for key in initial_desired.keys():
		if not loaded_chunks.has(key):
			have_all = false
			break
	if have_all:
		initial_load_in_progress = false
		initial_load_complete = true
		if loading_screen:
			loading_screen.hide_loading()
		if OS.is_debug_build():
			var lod_counts = [0, 0, 0, 0, 0]
			for k in loaded_chunks.keys():
				lod_counts[loaded_chunks[k].lod] += 1
			print("=== Initial load complete: %d chunks, FPS: %d ===" % [loaded_chunks.size(), Engine.get_frames_per_second()])
			print("[RESULT] Initial load: %d chunks, LODs: L0=%d L1=%d L2=%d L3=%d L4=%d, FPS after=%d" %
				[loaded_chunks.size(), lod_counts[0], lod_counts[1], lod_counts[2], lod_counts[3], lod_counts[4], Engine.get_frames_per_second()])
		get_tree().create_timer(5.0).timeout.connect(_on_initial_load_delay_done)


func _process_pending_unloads() -> void:
	"""Spread burst unloads across 2-3 frames to avoid visual pop."""
	if _pending_unload_keys.is_empty():
		return
	var n: int = _pending_unload_keys.size()
	var batch_size: int = maxi(1, int(ceil(float(n + BURST_UNLOAD_SPREAD_FRAMES - 1) / float(BURST_UNLOAD_SPREAD_FRAMES))))
	for _i in range(batch_size):
		if _pending_unload_keys.is_empty():
			break
		var key: String = _pending_unload_keys.pop_front()
		_unload_chunk(key)


func _drain_completed_async_to_phase_b() -> void:
	if _exiting:
		return
	var completed_ids: Array = []
	for tid in pending_loads.keys():
		if WorkerThreadPool.is_task_completed(tid):
			completed_ids.append(tid)
	for tid in completed_ids:
		if _exiting:
			return
		var entry = pending_loads[tid]
		pending_loads.erase(tid)
		var chunk_key: String = entry.chunk_key
		loading_chunk_keys.erase(chunk_key)
		WorkerThreadPool.wait_for_task_completion(tid)
		if _exiting:
			return
		var computed = entry.args["result"]
		if computed.is_empty() or not last_desired.has(chunk_key):
			continue
		var path_for_cache: String = computed.get("path_for_cache", "")
		var heights_for_cache = computed.get("heights_for_cache", [])
		if path_for_cache != "" and heights_for_cache.size() > 0:
			terrain_loader._add_to_height_cache(path_for_cache, heights_for_cache)
		_pending_phase_b.append({
			"computed": computed,
			"chunk_key": chunk_key,
			"lod": entry.lod,
			"x": entry.x,
			"y": entry.y,
			"step": 0,
			"mesh": null,
			"mesh_instance": null
		})


func _has_pending_phase_b_work() -> bool:
	return _pending_phase_b.size() > 0


func _do_one_phase_b_step() -> void:
	if _pending_phase_b.is_empty():
		return
	var entry = _pending_phase_b[0]
	var computed = entry["computed"]
	var step: int = entry["step"]
	if step == 0:
		entry["mesh"] = terrain_loader.finish_load_step_mesh(computed)
		entry["step"] = 1
	elif step == 1:
		var mesh = entry["mesh"]
		if mesh != null:
			var mesh_instance = terrain_loader.finish_load_step_scene(computed, mesh, false)
			if mesh_instance:
				mesh_instance.add_to_group("terrain_chunks") # So camera finds shared material without recursive search
				mesh_instance.scale = Vector3(0.97, 0.97, 0.97)
				chunks_container.add_child(mesh_instance)
				entry["mesh_instance"] = mesh_instance
				var tween = mesh_instance.create_tween()
				tween.tween_property(mesh_instance, "scale", Vector3(1.0, 1.0, 1.0), 0.4).set_ease(Tween.EASE_OUT)
		entry["step"] = 2
	else:
		terrain_loader.finish_load_step_collision(computed, collision_body)
		var chunk_key: String = entry["chunk_key"]
		var mesh_instance = entry["mesh_instance"]
		_pending_phase_b.pop_front()
		if mesh_instance:
			loaded_chunks[chunk_key] = {"node": mesh_instance, "lod": entry["lod"], "x": entry["x"], "y": entry["y"]}
			_last_phase_b_completed_chunk_key = chunk_key  # Fix 3: loading screen label
			if DEBUG_STREAMING_TIMING:
				print("[Stream] Loaded %s" % chunk_key)
			# Fix 1 (audit 3.1): Update visibility immediately so coarse parent is hidden as soon as children exist
			_update_chunk_visibility()


func _debug_dump_state() -> void:
	if not OS.is_debug_build():
		return
	print("\n=== CHUNK MANAGER DEBUG ===")
	print("Total chunks loaded: %d" % loaded_chunks.size())
	var lod_counts = [0, 0, 0, 0, 0]
	for key in loaded_chunks.keys():
		var chunk = loaded_chunks[key]
		lod_counts[chunk.lod] += 1
	print("Chunks by LOD:")
	for i in range(5):
		print("  LOD %d: %d" % [i, lod_counts[i]])
	print("Camera position: %s" % _get_camera_ground_position())
	print("===========================\n")


func _on_initial_load_delay_done() -> void:
	if _exiting:
		return
	if OS.is_debug_build():
		print("Dynamic chunk streaming active")


func _initial_load() -> void:
	var camera_pos = _get_camera_ground_position()
	var desired = _determine_desired_chunks(camera_pos)
	initial_desired = desired
	last_desired = desired
	
	# Queue all desired chunks (sorted by distance) for async load
	load_queue.clear()
	for key in desired.keys():
		var info = desired[key]
		load_queue.append({"lod": info.lod, "x": info.x, "y": info.y})
	# Prioritize chunks that cover more screen per distance (LOD 4 when zoomed out)
	load_queue.sort_custom(func(a, b):
		var center_a = _get_chunk_center_world(a.x, a.y, a.lod)
		var center_b = _get_chunk_center_world(b.x, b.y, b.lod)
		var dist_a = Vector2(center_a.x - camera_pos.x, center_a.z - camera_pos.z).length()
		var dist_b = Vector2(center_b.x - camera_pos.x, center_b.z - camera_pos.z).length()
		var prio_a = dist_a / _get_chunk_world_size(a.lod)
		var prio_b = dist_b / _get_chunk_world_size(b.lod)
		return prio_a < prio_b
	)

	initial_load_in_progress = true
	if OS.is_debug_build():
		print("Loading %d chunks (async)..." % desired.size())


func _update_chunks() -> void:
	var cycle_t0 = Time.get_ticks_msec()
	var camera_pos = _get_camera_ground_position()
	var camera_moved_distance: float = camera_pos.distance_to(_last_update_camera_pos)
	var is_large_move: bool = (_last_update_camera_pos != Vector3.ZERO) and (camera_moved_distance > LARGE_MOVE_THRESHOLD_M)
	_last_update_camera_pos = camera_pos

	var t_desired = Time.get_ticks_msec()
	var desired = _determine_desired_chunks(camera_pos)
	var time_desired_ms = Time.get_ticks_msec() - t_desired

	# DIAGNOSTIC: Track camera position changes to detect drift
	if camera_pos.distance_to(diagnostic_last_camera_pos) > 0.1: # Moved more than 10cm
		diagnostic_camera_stable_count = 0
	else:
		diagnostic_camera_stable_count += 1
	
	diagnostic_last_camera_pos = camera_pos
	
	var lod_counts = [0, 0, 0, 0, 0]
	for key in loaded_chunks.keys():
		var chunk = loaded_chunks[key]
		lod_counts[chunk.lod] += 1
	
	# print("\n[DIAGNOSTIC] Update cycle:")
	# print("  Camera XZ: (%.1f, %.1f) - %s" % [camera_pos.x, camera_pos.z, "MOVING" if camera_moved else "STABLE (%d cycles)" % diagnostic_camera_stable_count])
	# print("  Desired LOD 0 chunks: %d" % desired_lod0_count)
	# print("  Loaded LOD 0 chunks: %d" % loaded_lod0_count)
	# print("  Loaded: %d total (LOD0=%d, LOD1=%d, LOD2=%d, LOD3=%d, LOD4=%d)" %
	# 	[loaded_chunks.size(), lod_counts[0], lod_counts[1], lod_counts[2], lod_counts[3], lod_counts[4]])
	
	var to_load: Array = []
	var to_unload_candidates: Array = []
	
	# Find chunks to load (desired but not loaded)
	for key in desired.keys():
		if not loaded_chunks.has(key):
			to_load.append(desired[key])
	
	# Find chunks that might be unloaded (loaded but not desired)
	for key in loaded_chunks.keys():
		if not desired.has(key):
			to_unload_candidates.append(key)
			
			# DIAGNOSTIC: Check if this is a LOD 0 chunk
			var chunk = loaded_chunks[key]
			if chunk.lod == 0 and DEBUG_STREAMING_TIMING:
				var chunk_center = _get_chunk_center_world(chunk.x, chunk.y, chunk.lod)
				var dist_to_camera = Vector2(chunk_center.x - camera_pos.x, chunk_center.z - camera_pos.z).length()
				print("  [WARNING] LOD 0 chunk in unload candidates: %s, distance: %.1fm" % [key, dist_to_camera])
	
	# Deferred unloading: only unload if area is fully covered by LOADED FINER chunks (or timeout / immediate far)
	var to_unload: Array = []
	var current_time = Time.get_ticks_msec() / 1000.0
	var current_deferred_timeout: float = DEFERRED_UNLOAD_TIMEOUT_LARGE_MOVE_S if is_large_move else DEFERRED_UNLOAD_TIMEOUT_S

	# Build once only when we have candidates (avoids work when nothing to unload)
	# Use integer keys (cx<<16|cy) to avoid 10k+ string allocations per cycle
	var cell_min_lod: Dictionary = {}  # key int (cx<<16|cy) -> int (0-4), lower = finer
	const CELL_KEY_SHIFT: int = 16
	if to_unload_candidates.size() > 0:
		for key in loaded_chunks.keys():
			var chunk_info = loaded_chunks[key]
			var lod_scale = int(pow(2, chunk_info.lod))
			var c0_min_x: int = chunk_info.x * lod_scale
			var c0_max_x: int = (chunk_info.x + 1) * lod_scale - 1
			var c0_min_y: int = chunk_info.y * lod_scale
			var c0_max_y: int = (chunk_info.y + 1) * lod_scale - 1
			for cy in range(c0_min_y, c0_max_y + 1):
				for cx in range(c0_min_x, c0_max_x + 1):
					var cell_key: int = (cx << CELL_KEY_SHIFT) | cy
					var existing = cell_min_lod.get(cell_key, 99)
					if chunk_info.lod < existing:
						cell_min_lod[cell_key] = chunk_info.lod

	for key in to_unload_candidates:
		var chunk_info = loaded_chunks[key]
		var chunk_lod = chunk_info.lod
		var chunk_center = _get_chunk_center_world(chunk_info.x, chunk_info.y, chunk_lod)
		var chunk_dist: float = Vector2(chunk_center.x - camera_pos.x, chunk_center.z - camera_pos.z).length()

		# Immediate unload when camera jumped: chunks far beyond visible radius
		if is_large_move and chunk_dist > _last_visible_radius * 1.5:
			to_unload.append(key)
			deferred_unload_times.erase(key)
			if chunk_lod == 0 and DEBUG_STREAMING_TIMING:
				print("  [CRITICAL] Unloading LOD 0 chunk: %s, reason: immediate (far after region jump), distance: %.1fm" % [key, chunk_dist])
			continue

		# Check if this chunk's area is covered by FINER loaded chunks (use precomputed cell_min_lod)
		var cells_covered_by_finer = 0
		var cells_total = 0
		var lod_scale = int(pow(2, chunk_lod))
		var lod0_grid = _lod0_grid

		for dy in range(lod_scale):
			for dx in range(lod_scale):
				var lod0_x = chunk_info.x * lod_scale + dx
				var lod0_y = chunk_info.y * lod_scale + dy

				if lod0_x >= lod0_grid.x or lod0_y >= lod0_grid.y:
					continue

				cells_total += 1
				var cell_key: int = (lod0_x << CELL_KEY_SHIFT) | lod0_y
				if cell_min_lod.get(cell_key, 99) < chunk_lod:
					cells_covered_by_finer += 1

		var should_unload = false
		var unload_reason = ""

		if cells_total == 0:
			# Chunk is outside grid - unload
			should_unload = true
			unload_reason = "out of grid"
		elif cells_covered_by_finer == cells_total:
			# All cells are covered by finer loaded chunks - safe to unload
			should_unload = true
			unload_reason = "fully covered by finer LOD"
		else:
			# Some cells aren't covered by finer chunks - keep this chunk (with timeout)
			if not deferred_unload_times.has(key):
				deferred_unload_times[key] = current_time

			var deferred_duration = current_time - deferred_unload_times[key]
			if deferred_duration > current_deferred_timeout:
				should_unload = true
				unload_reason = "timeout (%.1fs)" % deferred_duration
			else:
				# Keep it for now - only log LOD0 to avoid 50+ prints per cycle (non-LOD0 logged in summary)
				if to_load.size() > 0 and DEBUG_STREAMING_TIMING and chunk_lod == 0:
					print("[Stream] Keeping %s (LOD0): 1/1 cells need finer coverage (%.1fs)" % [key, deferred_duration])

		if should_unload:
			to_unload.append(key)
			deferred_unload_times.erase(key)

			# DIAGNOSTIC: Log LOD 0 chunk unloads with reason
			if chunk_info.lod == 0 and DEBUG_STREAMING_TIMING:
				print("  [CRITICAL] Unloading LOD 0 chunk: %s, reason: %s, distance: %.1fm" % [key, unload_reason, chunk_dist])

	# Unload approved chunks (or defer burst to spread across frames)
	var t_unload: int = Time.get_ticks_msec()
	if to_unload.size() > BURST_UNLOAD_THRESHOLD:
		_pending_unload_keys.append_array(to_unload)
	else:
		for key in to_unload:
			_unload_chunk(key)
	var time_unload_ms = Time.get_ticks_msec() - t_unload
	
	# Sort to_load: when zoomed in prefer finer LOD first (same as load_queue sort)
	var sort_alt = _get_camera_altitude()
	var sort_lod_bias: float = 2.0 if sort_alt < 70000.0 else 0.0
	to_load.sort_custom(func(a, b):
		var center_a = _get_chunk_center_world(a.x, a.y, a.lod)
		var center_b = _get_chunk_center_world(b.x, b.y, b.lod)
		var dist_a = Vector2(center_a.x - camera_pos.x, center_a.z - camera_pos.z).length()
		var dist_b = Vector2(center_b.x - camera_pos.x, center_b.z - camera_pos.z).length()
		var prio_a = dist_a / _get_chunk_world_size(a.lod) + sort_lod_bias * float(a.lod)
		var prio_b = dist_b / _get_chunk_world_size(b.lod) + sort_lod_bias * float(b.lod)
		return prio_a < prio_b
	)

	# Store desired for "still wanted" check when async load completes
	last_desired = desired
	
	# Queue chunks for loading (one per frame in _process); do not load here
	for i in range(to_load.size()):
		var info = to_load[i]
		var key = "lod%d_x%d_y%d" % [info.lod, info.x, info.y]
		if loaded_chunks.has(key) or loading_chunk_keys.has(key):
			continue
		var already_queued = false
		for j in range(load_queue.size()):
			var q = load_queue[j]
			if q.lod == info.lod and q.x == info.x and q.y == info.y:
				already_queued = true
				break
		if not already_queued:
			load_queue.append({"lod": info.lod, "x": info.x, "y": info.y})
	# Sort: when zoomed in (alt < 70km), prefer finer LOD first so LOD 0 loads before coarser chunks
	var alt = _get_camera_altitude()
	const ALT_FOR_LOD_PRIORITY_M: float = 70000.0
	var lod_priority_bias: float = 2.0 if alt < ALT_FOR_LOD_PRIORITY_M else 0.0
	load_queue.sort_custom(func(a, b):
		var center_a = _get_chunk_center_world(a.x, a.y, a.lod)
		var center_b = _get_chunk_center_world(b.x, b.y, b.lod)
		var dist_a = Vector2(center_a.x - camera_pos.x, center_a.z - camera_pos.z).length()
		var dist_b = Vector2(center_b.x - camera_pos.x, center_b.z - camera_pos.z).length()
		var prio_a = dist_a / _get_chunk_world_size(a.lod) + lod_priority_bias * float(a.lod)
		var prio_b = dist_b / _get_chunk_world_size(b.lod) + lod_priority_bias * float(b.lod)
		return prio_a < prio_b
	)

	var total_cycle_ms = Time.get_ticks_msec() - cycle_t0
	if DEBUG_STREAMING_TIMING:
		print("[TIME] Desired set: %dms (%d cells)" % [int(time_desired_ms), _last_desired_box_cells])
		print("[TIME] Total cycle: %dms" % int(total_cycle_ms))
		print("[TIME] Unload phase: %dms (%d chunks)" % [int(time_unload_ms), to_unload.size()])
		print("[TIME] Load queue: %d" % load_queue.size())
	
	# Adjust update frequency based on load queue
	if load_queue.size() > 0:
		current_update_interval = UPDATE_INTERVAL_LOADING
	else:
		current_update_interval = UPDATE_INTERVAL_IDLE
	
	# Log update
	if (load_queue.size() > 0 or to_unload.size() > 0) and DEBUG_STREAMING_TIMING:
		print("[Stream] Update: loaded=%d, -%d unloaded, %d in queue, interval=%.2fs" %
			[loaded_chunks.size(), to_unload.size(), load_queue.size(), current_update_interval])
	
	# Update Visibility (LOD Occlusion)
	_update_chunk_visibility()


func _update_chunk_visibility() -> void:
	# Iterate over all loaded chunks
	# If a chunk is covered by a finer LOD (higher resolution, lower LOD index), hide it.
	for key in loaded_chunks:
		var chunk_info = loaded_chunks[key]
		var chunk_node = chunk_info.node
		var lod = chunk_info.lod
		var cx = chunk_info.x
		var cy = chunk_info.y
		
		# For LOD 0, always show (highest detail)
		if lod == 0:
			chunk_node.visible = true
			continue
			
		# For LOD > 0, check if we are covered by Finer LOD (lod - 1)
		# A chunk at LOD N (cx, cy) corresponds to 4 chunks at LOD N-1
		# We hide ONLY if ALL 4 finer chunks are loaded and visible.
		
		var finer_lod = lod - 1
		# Child coordinates (2x resolution)
		var min_fine_x = cx * 2
		var min_fine_y = cy * 2
		
		var all_finer_loaded = true
		for dy in range(2):
			for dx in range(2):
				var fine_key = "lod%d_x%d_y%d" % [finer_lod, min_fine_x + dx, min_fine_y + dy]
				if not loaded_chunks.has(fine_key):
					all_finer_loaded = false
					break
			if not all_finer_loaded:
				break
		
		# Limit check to grid bounds?
		# Actually, if the fine chunk is out of grid, it won't be in loaded_chunks, so all_finer_loaded will be false.
		# That's correct behavior (we need the coarse chunk).
		# Exception: Edge of world. If fine chunks don't exist because they are outside map?
		# The ChunkManager grid logic usually handles this.
		
		chunk_node.visible = not all_finer_loaded


func _is_cell_covered_by_finer_loaded(lod0_x: int, lod0_y: int, current_lod: int) -> bool:
	"""Check if a LOD 0 cell is covered by a LOADED chunk that is FINER (lower LOD number) than current_lod."""
	for key in loaded_chunks.keys():
		var chunk_info = loaded_chunks[key]
		
		# Only check chunks that are FINER (lower LOD number)
		if chunk_info.lod >= current_lod:
			continue
		
		var lod_scale = int(pow(2, chunk_info.lod))
		var chunk_cells_min_x = chunk_info.x * lod_scale
		var chunk_cells_max_x = (chunk_info.x + 1) * lod_scale - 1
		var chunk_cells_min_y = chunk_info.y * lod_scale
		var chunk_cells_max_y = (chunk_info.y + 1) * lod_scale - 1
		
		if lod0_x >= chunk_cells_min_x and lod0_x <= chunk_cells_max_x and \
		   lod0_y >= chunk_cells_min_y and lod0_y <= chunk_cells_max_y:
			return true
	
	return false


func _is_cell_covered_by_desired(lod0_x: int, lod0_y: int, desired: Dictionary) -> bool:
	"""Check if a LOD 0 cell is covered by any chunk in the desired set."""
	for key in desired.keys():
		var chunk_info = desired[key]
		var lod_scale = int(pow(2, chunk_info.lod))
		var chunk_cells_min_x = chunk_info.x * lod_scale
		var chunk_cells_max_x = (chunk_info.x + 1) * lod_scale - 1
		var chunk_cells_min_y = chunk_info.y * lod_scale
		var chunk_cells_max_y = (chunk_info.y + 1) * lod_scale - 1
		
		if lod0_x >= chunk_cells_min_x and lod0_x <= chunk_cells_max_x and \
		   lod0_y >= chunk_cells_min_y and lod0_y <= chunk_cells_max_y:
			return true
	
	return false


func _is_cell_covered_by_loaded_desired(lod0_x: int, lod0_y: int, desired: Dictionary) -> bool:
	"""Check if a LOD 0 cell is covered by a LOADED chunk that's also in the desired set."""
	for key in desired.keys():
		if not loaded_chunks.has(key):
			continue # Skip chunks that aren't loaded yet
		
		var chunk_info = desired[key]
		var lod_scale = int(pow(2, chunk_info.lod))
		var chunk_cells_min_x = chunk_info.x * lod_scale
		var chunk_cells_max_x = (chunk_info.x + 1) * lod_scale - 1
		var chunk_cells_min_y = chunk_info.y * lod_scale
		var chunk_cells_max_y = (chunk_info.y + 1) * lod_scale - 1
		
		if lod0_x >= chunk_cells_min_x and lod0_x <= chunk_cells_max_x and \
		   lod0_y >= chunk_cells_min_y and lod0_y <= chunk_cells_max_y:
			return true
	
	return false


func _determine_desired_chunks(camera_pos: Vector3) -> Dictionary:
	var altitude = _get_camera_altitude()
	var visible_radius: float = maxf(_Const.INNER_RADIUS_M, altitude * _Const.VISIBLE_RADIUS_ALTITUDE_FACTOR)
	_last_visible_radius = visible_radius

	# Inner ring: LOD 0 cells within 500km (current behavior, ~529 cells max)
	var inner_desired: Dictionary = _determine_inner_chunks(camera_pos, altitude)
	# Outer ring: LOD 4 only from 500km to visible_radius (handful of LOD 4 chunks)
	var outer_desired: Dictionary = _determine_outer_lod4_chunks(camera_pos, visible_radius)

	# Merge: outer keys may overlap inner at edges; inner has finer LOD so keep inner for overlapping cells
	for key in outer_desired.keys():
		if not inner_desired.has(key):
			inner_desired[key] = outer_desired[key]
	var desired: Dictionary = inner_desired

	# Expand LOD 0 to full 2x2 blocks so coarse LOD 1 chunks can be hidden (avoids LOD stacking / "snow" overlay)
	_expand_lod0_to_full_blocks(desired)

	# Diagnostic box: LOD 0 bounding box of all desired chunks (for gap detection)
	_compute_desired_box_from_chunks(desired)
	return desired


func _determine_inner_chunks(camera_pos: Vector3, altitude: float) -> Dictionary:
	"""Inner ring: LOD 0 cells within _Const.INNER_RADIUS_M (500km). Same logic as before — up to ~529 cells."""
	var lod0_grid = _lod0_grid
	var cell_size_m: float = 512.0 * _resolution_m
	var cells_radius: int = int(ceil(_Const.INNER_RADIUS_M / cell_size_m))

	var camera_cell_x: int = int(camera_pos.x / cell_size_m)
	var camera_cell_y: int = int(camera_pos.z / cell_size_m)

	var min_cx: int = maxi(0, camera_cell_x - cells_radius)
	var max_cx: int = mini(lod0_grid.x - 1, camera_cell_x + cells_radius)
	var min_cy: int = maxi(0, camera_cell_y - cells_radius)
	var max_cy: int = mini(lod0_grid.y - 1, camera_cell_y + cells_radius)

	var cell_lods: Dictionary = {}
	for lod0_y in range(min_cy, max_cy + 1):
		for lod0_x in range(min_cx, max_cx + 1):
			var cell_center = _get_chunk_center_world(lod0_x, lod0_y, 0)
			var horiz_dist = Vector2(cell_center.x - camera_pos.x, cell_center.z - camera_pos.z).length()
			var lod0_key = "%d_%d" % [lod0_x, lod0_y]
			cell_lods[lod0_key] = _select_lod_with_hysteresis(lod0_key, horiz_dist, altitude)

	var desired: Dictionary = {}
	var covered_cells: Dictionary = {}
	for lod in range(5):
		for lod0_y in range(min_cy, max_cy + 1):
			for lod0_x in range(min_cx, max_cx + 1):
				var cell_key = "%d_%d" % [lod0_x, lod0_y]
				if not cell_lods.has(cell_key):
					continue
				var chosen_lod = cell_lods[cell_key]
				if chosen_lod != lod:
					continue
				if covered_cells.has(cell_key):
					continue
				var lod_scale = int(pow(2, chosen_lod))
				var chunk_x = int(float(lod0_x) / float(lod_scale))
				var chunk_y = int(float(lod0_y) / float(lod_scale))
				var chunk_key = "lod%d_x%d_y%d" % [chosen_lod, chunk_x, chunk_y]
				if not desired.has(chunk_key):
					desired[chunk_key] = {"lod": chosen_lod, "x": chunk_x, "y": chunk_y}
				for dy in range(lod_scale):
					for dx in range(lod_scale):
						var covered_x = chunk_x * lod_scale + dx
						var covered_y = chunk_y * lod_scale + dy
						if covered_x >= min_cx and covered_x <= max_cx and covered_y >= min_cy and covered_y <= max_cy:
							covered_cells["%d_%d" % [covered_x, covered_y]] = true

	_verify_full_coverage_box(desired, min_cx, max_cx, min_cy, max_cy)
	return desired


func _expand_lod0_to_full_blocks(desired: Dictionary) -> void:
	"""Ensure every LOD 0..3 chunk in desired is part of a complete 2x2 block (same parent at next coarser LOD).
	This allows _update_chunk_visibility to hide the parent when all 4 children are loaded,
	preventing coarse LODs (e.g. LOD 2) from drawing on top of fine LOD 0 (stacking / low-res overlay)."""
	var lod0_grid = _lod0_grid
	var to_add: Array = []  # {lod, x, y}
	for key in desired.keys():
		var info = desired[key]
		var lod: int = info.lod
		if lod > 3:
			continue  # LOD 4 has no finer level to hide
		var cx: int = info.x
		var cy: int = info.y
		var base_x: int = (cx >> 1) << 1
		var base_y: int = (cy >> 1) << 1
		# Grid size at this LOD: LOD 0 = lod0_grid; LOD n = (lod0_grid + (1<<n)-1) >> n
		var grid_w: int = (lod0_grid.x + (1 << lod) - 1) >> lod
		var grid_h: int = (lod0_grid.y + (1 << lod) - 1) >> lod
		for dy in range(2):
			for dx in range(2):
				var sx: int = base_x + dx
				var sy: int = base_y + dy
				if sx < 0 or sx >= grid_w or sy < 0 or sy >= grid_h:
					continue
				var sibling_key: String = "lod%d_x%d_y%d" % [lod, sx, sy]
				if not desired.has(sibling_key):
					to_add.append({"lod": lod, "x": sx, "y": sy})
	for entry in to_add:
		var k: String = "lod%d_x%d_y%d" % [entry.lod, entry.x, entry.y]
		if not desired.has(k):
			desired[k] = entry


func _determine_outer_lod4_chunks(camera_pos: Vector3, visible_radius: float) -> Dictionary:
	"""Outer ring: LOD 4 only, from 500km to visible_radius. Iterate LOD 4 chunk indices only (~20-30 chunks)."""
	if visible_radius <= _Const.INNER_RADIUS_M:
		return {}
	var lod0_grid = _lod0_grid
	# LOD 4 grid size (each LOD 4 chunk = 16x16 LOD 0 cells)
	var lod4_grid_x: int = (lod0_grid.x + 15) / 16
	var lod4_grid_y: int = (lod0_grid.y + 15) / 16
	var desired: Dictionary = {}
	var camera_xz = Vector2(camera_pos.x, camera_pos.z)
	for cy in range(lod4_grid_y):
		for cx in range(lod4_grid_x):
			var center = _get_chunk_center_world(cx, cy, 4)
			var center_xz = Vector2(center.x, center.z)
			var dist: float = camera_xz.distance_to(center_xz)
			if dist > _Const.INNER_RADIUS_M and dist <= visible_radius:
				var chunk_key = "lod%d_x%d_y%d" % [4, cx, cy]
				desired[chunk_key] = {"lod": 4, "x": cx, "y": cy}
	return desired


func _compute_desired_box_from_chunks(desired: Dictionary) -> void:
	"""Set _last_min_cx/max_cx/min_cy/max_cy and _last_desired_box_cells from desired set's LOD 0 coverage."""
	var lod0_grid = _lod0_grid
	var min_cx: int = lod0_grid.x
	var max_cx: int = -1
	var min_cy: int = lod0_grid.y
	var max_cy: int = -1
	for key in desired.keys():
		var info = desired[key]
		var lod_scale = int(pow(2, info.lod))
		var c0_min_x: int = info.x * lod_scale
		var c0_max_x: int = (info.x + 1) * lod_scale - 1
		var c0_min_y: int = info.y * lod_scale
		var c0_max_y: int = (info.y + 1) * lod_scale - 1
		min_cx = mini(min_cx, c0_min_x)
		max_cx = maxi(max_cx, c0_max_x)
		min_cy = mini(min_cy, c0_min_y)
		max_cy = maxi(max_cy, c0_max_y)
	_last_min_cx = maxi(0, min_cx)
	_last_max_cx = mini(lod0_grid.x - 1, max_cx)
	_last_min_cy = maxi(0, min_cy)
	_last_max_cy = mini(lod0_grid.y - 1, max_cy)
	_last_desired_box_cells = (maxi(0, _last_max_cx - _last_min_cx + 1)) * (maxi(0, _last_max_cy - _last_min_cy + 1))


func _verify_full_coverage_box(chunks: Dictionary, min_cx: int, max_cx: int, min_cy: int, max_cy: int) -> void:
	"""Verify that every LOD 0 cell in the bounding box has at least one chunk covering it."""
	var uncovered_cells: Array = []
	for lod0_y in range(min_cy, max_cy + 1):
		for lod0_x in range(min_cx, max_cx + 1):
			var covered = false
			for key in chunks.keys():
				var info = chunks[key]
				var lod_scale = int(pow(2, info.lod))
				var chunk_cells_min_x = info.x * lod_scale
				var chunk_cells_max_x = (info.x + 1) * lod_scale - 1
				var chunk_cells_min_y = info.y * lod_scale
				var chunk_cells_max_y = (info.y + 1) * lod_scale - 1
				if lod0_x >= chunk_cells_min_x and lod0_x <= chunk_cells_max_x and \
				   lod0_y >= chunk_cells_min_y and lod0_y <= chunk_cells_max_y:
					covered = true
					break
			if not covered:
				uncovered_cells.append("(%d,%d)" % [lod0_x, lod0_y])
	if uncovered_cells.size() > 0:
		push_error("CRITICAL: %d box cells have no coverage: %s" % [uncovered_cells.size(), ", ".join(uncovered_cells.slice(0, 10))])


## Debug utility — call manually to verify chunk overlap state. Not used in normal flow.
func _verify_no_overlaps(chunks: Dictionary) -> void:
	"""Verify that no two chunks in the set have overlapping world-space bounds."""
	var chunk_list: Array = []
	for key in chunks.keys():
		var info = chunks[key]
		var lod_scale = int(pow(2, info.lod))
		var chunk_world_size = 512.0 * _resolution_m * float(lod_scale)
		var bounds = {
			"key": key,
			"lod": info.lod,
			"min_x": info.x * chunk_world_size,
			"max_x": (info.x + 1) * chunk_world_size,
			"min_z": info.y * chunk_world_size,
			"max_z": (info.y + 1) * chunk_world_size
		}
		chunk_list.append(bounds)
	
	var overlaps_found = 0
	for i in range(chunk_list.size()):
		for j in range(i + 1, chunk_list.size()):
			var a = chunk_list[i]
			var b = chunk_list[j]
			
			# Check if bounding boxes overlap
			var x_overlap = a.min_x < b.max_x and a.max_x > b.min_x
			var z_overlap = a.min_z < b.max_z and a.max_z > b.min_z
			
			if x_overlap and z_overlap:
				push_error("[OVERLAP] %s (LOD %d) overlaps with %s (LOD %d)" %
					[a.key, a.lod, b.key, b.lod])
				overlaps_found += 1
	
	if overlaps_found > 0:
		push_error("CRITICAL: Found %d chunk overlaps! This will cause visual artifacts." % overlaps_found)


func _select_lod_with_hysteresis(lod0_key: String, dist: float, altitude: float = 0.0) -> int:
	var base_lod: int = 4
	if dist < _Const.LOD_DISTANCES_M[1]:
		base_lod = 0
	elif dist < _Const.LOD_DISTANCES_M[2]:
		base_lod = 1
	elif dist < _Const.LOD_DISTANCES_M[3]:
		base_lod = 2
	elif dist < _Const.LOD_DISTANCES_M[4]:
		base_lod = 3
	# At high altitude never use LOD 0 — avoids load-then-unload flash and keeps view consistent with overview
	const ALTITUDE_LOD0_MAX_M: float = 70000.0
	if altitude > ALTITUDE_LOD0_MAX_M and base_lod == 0:
		base_lod = 1
	
	if lod_hysteresis_state.has(lod0_key):
		var current_lod = lod_hysteresis_state[lod0_key]
		
		# CRITICAL FIX: Hysteresis should ONLY prevent DOWNGRADING (fine → coarse)
		# It should NEVER prevent UPGRADING (coarse → fine)
		# When camera moves closer, always upgrade immediately
		if base_lod < current_lod:
			# Camera moved closer - upgrade to finer LOD immediately (NO hysteresis)
			lod_hysteresis_state[lod0_key] = base_lod
			return base_lod
		elif base_lod > current_lod:
			# Camera moved away - trying to downgrade to coarser LOD
			# Apply hysteresis to prevent rapid downgrading
			var threshold = _Const.LOD_DISTANCES_M[base_lod]
			var buffer = threshold * _Const.LOD_HYSTERESIS
			if dist < (threshold + buffer):
				# Within hysteresis buffer - keep current finer LOD
				return current_lod
	
	lod_hysteresis_state[lod0_key] = base_lod
	return base_lod


func _load_chunk(lod: int, cx: int, cy: int) -> void:
	var key = "lod%d_x%d_y%d" % [lod, cx, cy]
	if loaded_chunks.has(key):
		return
	
	var chunk_node = terrain_loader.load_chunk(cx, cy, lod, collision_body, false)
	if not chunk_node:
		push_error("Failed to load chunk: %s" % key)
		return
	
	chunks_container.add_child(chunk_node)
	loaded_chunks[key] = {"node": chunk_node, "lod": lod, "x": cx, "y": cy}
	if DEBUG_STREAMING_TIMING:
		print("[Stream] Loaded %s" % key)


func _unload_chunk(key: String) -> void:
	if not loaded_chunks.has(key):
		return
	
	var chunk_info = loaded_chunks[key]
	if chunk_info.node:
		chunk_info.node.queue_free()
	
	var collision_name = "HeightMap_LOD%d_%d_%d" % [chunk_info.lod, chunk_info.x, chunk_info.y]
	var collision_shape = collision_body.get_node_or_null(collision_name)
	if collision_shape:
		collision_shape.queue_free()
	
	loaded_chunks.erase(key)
	if DEBUG_STREAMING_TIMING:
		print("[Stream] Unloaded %s" % key)


func _get_camera_ground_position() -> Vector3:
	if not camera:
		return Vector3.ZERO
	if camera.has_method("get_target_ground_position"):
		return camera.get_target_ground_position()
	var cam_pos = camera.global_position
	return Vector3(cam_pos.x, 0, cam_pos.z)


func _get_camera_altitude() -> float:
	"""Camera altitude (distance from target) for visible-radius scaling."""
	if not camera:
		return 0.0
	var d = camera.get("orbit_distance")
	if d != null:
		return float(d)
	return camera.global_position.y


func _get_max_concurrent_loads() -> int:
	if load_queue.size() > LARGE_QUEUE_THRESHOLD:
		return MAX_CONCURRENT_ASYNC_LOADS_LARGE
	return MAX_CONCURRENT_ASYNC_LOADS_BASE


## Returns the LOD of the chunk that contains the given world position (XZ).
## Used to disable hex selection on LOD 3+ terrain. Returns -1 if no loaded chunk contains the point.
func get_lod_at_world_position(world_pos: Vector3) -> int:
	var cell_size_m: float = 512.0 * _resolution_m
	var best_lod: int = -1
	for key in loaded_chunks.keys():
		var info = loaded_chunks[key]
		var lod_scale = int(pow(2, info.lod))
		var chunk_world_size = cell_size_m * float(lod_scale)
		var min_x = info.x * chunk_world_size
		var max_x = (info.x + 1) * chunk_world_size
		var min_z = info.y * chunk_world_size
		var max_z = (info.y + 1) * chunk_world_size
		if world_pos.x >= min_x and world_pos.x < max_x and world_pos.z >= min_z and world_pos.z < max_z:
			if best_lod < 0 or info.lod < best_lod:
				best_lod = info.lod
	return best_lod


## Interpolated terrain height at world XZ (meters). Uses LOD 0 height cache in TerrainLoader.
## Returns -1.0 if chunk not loaded (e.g. hex slice cannot be built).
func get_height_at(world_x: float, world_z: float) -> float:
	if not terrain_loader:
		return -1.0
	return terrain_loader.get_height_at(world_x, world_z)


func _get_chunk_center_world(chunk_x: int, chunk_y: int, lod: int) -> Vector3:
	var lod_scale = int(pow(2, lod))
	var chunk_world_size = 512.0 * _resolution_m * float(lod_scale)
	var corner = Vector3(chunk_x * chunk_world_size, 0, chunk_y * chunk_world_size)
	return corner + Vector3(chunk_world_size / 2.0, 0, chunk_world_size / 2.0)


func _get_chunk_world_size(lod: int) -> float:
	"""World-space size of one chunk at this LOD (meters)."""
	return 512.0 * _resolution_m * pow(2.0, float(lod))


## Diagnostic: return current streaming state for logging (read-only).
func get_diagnostic_snapshot() -> Dictionary:
	var lod_counts = [0, 0, 0, 0, 0]
	for key in loaded_chunks.keys():
		var chunk = loaded_chunks[key]
		lod_counts[chunk.lod] += 1
	var gaps_count = 0
	for lod0_y in range(_last_min_cy, _last_max_cy + 1):
		for lod0_x in range(_last_min_cx, _last_max_cx + 1):
			if not _is_cell_covered_by_loaded_desired(lod0_x, lod0_y, last_desired):
				gaps_count += 1
	return {
		"loaded_total": loaded_chunks.size(),
		"loaded_lod0": lod_counts[0],
		"loaded_lod1": lod_counts[1],
		"loaded_lod2": lod_counts[2],
		"loaded_lod3": lod_counts[3],
		"loaded_lod4": lod_counts[4],
		"queue_size": load_queue.size(),
		"desired_count": last_desired.size(),
		"gaps_count": gaps_count,
		"has_gaps": gaps_count > 0
	}


func has_initial_load_completed() -> bool:
	return initial_load_complete
