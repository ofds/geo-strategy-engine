extends Node3D
## Chunk Manager - Simple, reliable terrain streaming
## Every 0.5s: determine desired chunks, load closest 4, unload unwanted

# References
var terrain_loader: TerrainLoader = null
var camera: Camera3D = null
var chunks_container: Node3D = null
var collision_body: StaticBody3D = null
var loading_screen = null

# Loaded chunks: Key = "lod{L}_x{X}_y{Y}", Value = {node: Node3D, lod: int, x: int, y: int}
var loaded_chunks: Dictionary = {}

# Update timer and adaptive frequency
var update_timer: float = 0.0
const UPDATE_INTERVAL_IDLE: float = 0.5
const UPDATE_INTERVAL_LOADING: float = 0.25
var current_update_interval: float = 0.5

# Initial load flag
var initial_load_complete: bool = false

# Constants
const LOD_DISTANCES_M: Array[float] = [0.0, 25000.0, 50000.0, 100000.0, 200000.0]
const LOD_GRID_SIZES: Array = [
	Vector2i(32, 18), # LOD 0
	Vector2i(16, 9), # LOD 1
	Vector2i(8, 5), # LOD 2
	Vector2i(4, 3), # LOD 3
	Vector2i(2, 2), # LOD 4
]
const LOD_HYSTERESIS: float = 0.10 # 10% buffer at LOD boundaries
const CHUNK_SIZE_M: float = 15360.0 # 512px * 30m = 15.36 km per LOD 0 chunk
const MAX_LOADS_PER_UPDATE: int = 8 # Increased from 4 for faster loading
const DEFERRED_UNLOAD_TIMEOUT_S: float = 5.0 # Unload after 5s regardless

# Hysteresis tracking: Key = "lod0_x_y", Value = current_lod
var lod_hysteresis_state: Dictionary = {}

# Deferred unload tracking: Key = chunk_key, Value = timestamp when deferred
var deferred_unload_times: Dictionary = {}

# DIAGNOSTIC: Camera position tracking for stability detection
var diagnostic_last_camera_pos: Vector3 = Vector3.ZERO
var diagnostic_camera_stable_count: int = 0

# DIAGNOSTIC: Desired set tracking for determinism verification
var diagnostic_last_lod0_cells_str: String = ""
var diagnostic_last_desired_camera_pos: Vector3 = Vector3.ZERO


func _ready() -> void:
	terrain_loader = get_node_or_null("../TerrainLoader")
	if not terrain_loader:
		push_error("ChunkManager: TerrainLoader not found!")
		return
	
	await get_tree().process_frame
	
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
	
	print("\n=== ChunkManager: Initial Load ===")
	await _initial_load()
	
	initial_load_complete = true
	print("=== Initial load complete: %d chunks, FPS: %d ===" % [loaded_chunks.size(), Engine.get_frames_per_second()])
	
	if loading_screen:
		loading_screen.hide_loading()
	
	await get_tree().create_timer(5.0).timeout
	print("Dynamic chunk streaming active")


func _process(delta: float) -> void:
	if not initial_load_complete:
		return
	
	if Input.is_key_pressed(KEY_D) and not Input.is_key_pressed(KEY_SHIFT):
		_debug_dump_state()
	
	update_timer += delta
	if update_timer >= current_update_interval:
		update_timer = 0.0
		_update_chunks()


func _debug_dump_state() -> void:
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


func _initial_load() -> void:
	var camera_pos = _get_camera_ground_position()
	var desired = _determine_desired_chunks(camera_pos)
	
	print("Loading %d chunks synchronously..." % desired.size())
	
	var count = 0
	for key in desired.keys():
		var info = desired[key]
		_load_chunk(info.lod, info.x, info.y)
		count += 1
		if loading_screen and count % 5 == 0:
			loading_screen.update_progress(count, desired.size(), key)
			await get_tree().process_frame


func _update_chunks() -> void:
	var camera_pos = _get_camera_ground_position()
	var desired = _determine_desired_chunks(camera_pos)
	
	# DIAGNOSTIC: Track camera position changes to detect drift
	var camera_moved = false
	
	if camera_pos.distance_to(diagnostic_last_camera_pos) > 0.1: # Moved more than 10cm
		camera_moved = true
		diagnostic_camera_stable_count = 0
	else:
		diagnostic_camera_stable_count += 1
	
	diagnostic_last_camera_pos = camera_pos
	
	# DIAGNOSTIC: Count LOD 0 chunks in desired and loaded sets
	var desired_lod0_count = 0
	var loaded_lod0_count = 0
	var desired_lod0_chunks: Array = []
	
	for key in desired.keys():
		var info = desired[key]
		if info.lod == 0:
			desired_lod0_count += 1
			desired_lod0_chunks.append(key)
	
	# DIAGNOSTIC: Count all loaded chunks by LOD level
	var lod_counts = [0, 0, 0, 0, 0]
	for key in loaded_chunks.keys():
		var chunk = loaded_chunks[key]
		lod_counts[chunk.lod] += 1
	
	loaded_lod0_count = lod_counts[0]
	
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
			if chunk.lod == 0:
				var chunk_center = _get_chunk_center_world(chunk.x, chunk.y, chunk.lod)
				var dist_to_camera = Vector2(chunk_center.x - camera_pos.x, chunk_center.z - camera_pos.z).length()
				print("  [WARNING] LOD 0 chunk in unload candidates: %s, distance: %.1fm" % [key, dist_to_camera])
	
	# Deferred unloading: only unload if area is fully covered by LOADED FINER chunks
	var to_unload: Array = []
	var current_time = Time.get_ticks_msec() / 1000.0
	
	for key in to_unload_candidates:
		var chunk_info = loaded_chunks[key]
		var chunk_lod = chunk_info.lod
		
		# Check if this chunk's area is covered by FINER loaded chunks
		var cells_covered_by_finer = 0
		var cells_total = 0
		var lod_scale = int(pow(2, chunk_lod))
		var lod0_grid = LOD_GRID_SIZES[0]
		
		for dy in range(lod_scale):
			for dx in range(lod_scale):
				var lod0_x = chunk_info.x * lod_scale + dx
				var lod0_y = chunk_info.y * lod_scale + dy
				
				if lod0_x >= lod0_grid.x or lod0_y >= lod0_grid.y:
					continue
				
				cells_total += 1
				
				# Check if this cell is covered by a FINER (lower LOD number) loaded chunk
				if _is_cell_covered_by_finer_loaded(lod0_x, lod0_y, chunk_lod):
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
			if deferred_duration > DEFERRED_UNLOAD_TIMEOUT_S:
				should_unload = true
				unload_reason = "timeout (%.1fs)" % deferred_duration
			else:
				# Keep it for now - only log if pending loads
				if to_load.size() > 0:
					print("[Stream] Keeping %s (LOD%d): %d/%d cells need finer coverage (%.1fs)" %
						[key, chunk_lod, cells_total - cells_covered_by_finer, cells_total, deferred_duration])
		
		if should_unload:
			to_unload.append(key)
			deferred_unload_times.erase(key)
			
			# DIAGNOSTIC: Log LOD 0 chunk unloads with reason
			if chunk_info.lod == 0:
				var chunk_center = _get_chunk_center_world(chunk_info.x, chunk_info.y, chunk_info.lod)
				var dist_to_camera = Vector2(chunk_center.x - camera_pos.x, chunk_center.z - camera_pos.z).length()
				print("  [CRITICAL] Unloading LOD 0 chunk: %s, reason: %s, distance: %.1fm" % [key, unload_reason, dist_to_camera])
	
	# Unload approved chunks
	for key in to_unload:
		_unload_chunk(key)
	
	# Sort to_load by distance from camera (closest first)
	to_load.sort_custom(func(a, b):
		var center_a = _get_chunk_center_world(a.x, a.y, a.lod)
		var center_b = _get_chunk_center_world(b.x, b.y, b.lod)
		var dist_a = Vector2(center_a.x - camera_pos.x, center_a.z - camera_pos.z).length()
		var dist_b = Vector2(center_b.x - camera_pos.x, center_b.z - camera_pos.z).length()
		return dist_a < dist_b
	)
	
	# Load up to MAX_LOADS_PER_UPDATE closest chunks
	var loaded_count = 0
	for i in range(min(MAX_LOADS_PER_UPDATE, to_load.size())):
		_load_chunk(to_load[i].lod, to_load[i].x, to_load[i].y)
		loaded_count += 1
	
	# Adjust update frequency based on load queue
	if to_load.size() > 0:
		current_update_interval = UPDATE_INTERVAL_LOADING
	else:
		current_update_interval = UPDATE_INTERVAL_IDLE
	
	# Log update
	if to_load.size() > 0 or to_unload.size() > 0:
		print("[Stream] Update: loaded=%d, +%d loaded, -%d unloaded, %d pending, interval=%.2fs" %
			[loaded_chunks.size(), loaded_count, to_unload.size(), to_load.size() - loaded_count, current_update_interval])
	
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
	var lod0_grid = LOD_GRID_SIZES[0]
	
	# Step 1: Calculate desired LOD for each LOD 0 cell
	var cell_lods: Array = []
	cell_lods.resize(lod0_grid.x * lod0_grid.y)
	
	# DIAGNOSTIC: Track LOD 0 cell assignments
	var lod0_cells_assigned: Array = []
	
	for lod0_y in range(lod0_grid.y):
		for lod0_x in range(lod0_grid.x):
			var cell_center = _get_chunk_center_world(lod0_x, lod0_y, 0)
			var horiz_dist = Vector2(cell_center.x - camera_pos.x, cell_center.z - camera_pos.z).length()
			var lod0_key = "%d_%d" % [lod0_x, lod0_y]
			var chosen_lod = _select_lod_with_hysteresis(lod0_key, horiz_dist)
			var idx = lod0_y * lod0_grid.x + lod0_x
			cell_lods[idx] = chosen_lod
			
			# Track which cells are assigned LOD 0
			if chosen_lod == 0:
				lod0_cells_assigned.append("(%d,%d)" % [lod0_x, lod0_y])
	
	# DIAGNOSTIC: Print LOD 0 cell assignments and verify determinism
	if lod0_cells_assigned.size() > 0:
		var lod0_cells_str = ", ".join(lod0_cells_assigned)
		print("  LOD 0 cells: %s" % lod0_cells_str)
		
		# Check if desired set changed from last cycle (for determinism verification)
		if camera_pos.distance_to(diagnostic_last_desired_camera_pos) < 0.1: # Camera hasn't moved
			if lod0_cells_str != diagnostic_last_lod0_cells_str and diagnostic_last_lod0_cells_str != "":
				print("  [ERROR] Desired set changed while camera is stationary! Non-deterministic!")
				print("    Previous: %s" % diagnostic_last_lod0_cells_str)
				print("    Current:  %s" % lod0_cells_str)
		
		diagnostic_last_lod0_cells_str = lod0_cells_str
		diagnostic_last_desired_camera_pos = camera_pos
	
	# Step 2: Build desired set with proper deduplication - finest LOD wins, no overlaps
	var desired: Dictionary = {}
	var covered_cells: Dictionary = {} # Key = "x_y", Value = true if covered
	
	# Process cells from finest to coarsest LOD to ensure finest wins
	for lod in range(5): # LOD 0 through 4
		for lod0_y in range(lod0_grid.y):
			for lod0_x in range(lod0_grid.x):
				var idx = lod0_y * lod0_grid.x + lod0_x
				var chosen_lod = cell_lods[idx]
				
				# Only process cells that want this LOD level
				if chosen_lod != lod:
					continue
				
				# Check if this cell is already covered by a finer LOD
				var cell_key = "%d_%d" % [lod0_x, lod0_y]
				if covered_cells.has(cell_key):
					continue # Already covered by finer LOD
				
				# Map this cell to its chunk at the chosen LOD
				var lod_scale = int(pow(2, chosen_lod))
				var chunk_x = int(float(lod0_x) / float(lod_scale))
				var chunk_y = int(float(lod0_y) / float(lod_scale))
				var chunk_key = "lod%d_x%d_y%d" % [chosen_lod, chunk_x, chunk_y]
				
				# Add to desired set
				if not desired.has(chunk_key):
					desired[chunk_key] = {"lod": chosen_lod, "x": chunk_x, "y": chunk_y}
				
				# Mark all cells covered by this chunk as covered
				for dy in range(lod_scale):
					for dx in range(lod_scale):
						var covered_x = chunk_x * lod_scale + dx
						var covered_y = chunk_y * lod_scale + dy
						if covered_x < lod0_grid.x and covered_y < lod0_grid.y:
							var covered_key = "%d_%d" % [covered_x, covered_y]
							covered_cells[covered_key] = true
	
	# Verify full coverage
	_verify_full_coverage(desired, lod0_grid)
	
	return desired


func _verify_full_coverage(chunks: Dictionary, lod0_grid: Vector2i) -> void:
	"""Verify that every LOD 0 cell has at least one chunk covering it."""
	var uncovered_cells: Array = []
	
	for lod0_y in range(lod0_grid.y):
		for lod0_x in range(lod0_grid.x):
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
		push_error("CRITICAL: %d cells have no coverage: %s" % [uncovered_cells.size(), ", ".join(uncovered_cells.slice(0, 10))])


func _verify_no_overlaps(chunks: Dictionary) -> void:
	"""Verify that no two chunks in the set have overlapping world-space bounds."""
	var chunk_list: Array = []
	for key in chunks.keys():
		var info = chunks[key]
		var lod_scale = int(pow(2, info.lod))
		var chunk_world_size = 512 * 30.0 * lod_scale
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


func _select_lod_with_hysteresis(lod0_key: String, dist: float) -> int:
	var base_lod: int = 4
	if dist < LOD_DISTANCES_M[1]:
		base_lod = 0
	elif dist < LOD_DISTANCES_M[2]:
		base_lod = 1
	elif dist < LOD_DISTANCES_M[3]:
		base_lod = 2
	elif dist < LOD_DISTANCES_M[4]:
		base_lod = 3
	
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
			var threshold = LOD_DISTANCES_M[base_lod]
			var buffer = threshold * LOD_HYSTERESIS
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
	print("[Stream] Unloaded %s" % key)


func _get_camera_ground_position() -> Vector3:
	if not camera:
		return Vector3.ZERO
	if camera.has_method("get_target_ground_position"):
		return camera.get_target_ground_position()
	var cam_pos = camera.global_position
	return Vector3(cam_pos.x, 0, cam_pos.z)


func _get_chunk_center_world(chunk_x: int, chunk_y: int, lod: int) -> Vector3:
	var lod_scale = int(pow(2, lod))
	var chunk_world_size = 512 * 30.0 * lod_scale
	var corner = Vector3(chunk_x * chunk_world_size, 0, chunk_y * chunk_world_size)
	return corner + Vector3(chunk_world_size / 2.0, 0, chunk_world_size / 2.0)
