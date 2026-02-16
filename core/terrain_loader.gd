class_name TerrainLoader
extends Node
## Terrain Loader - Stateless utility for loading single terrain chunks
## CRITICAL: Properly handles 16-bit PNG elevation data
## Called by ChunkManager to generate individual chunk meshes

const _TerrainWorkerScript = preload("res://core/terrain_worker.gd")

# Metadata from terrain_metadata.json
var terrain_metadata: Dictionary = {}
var max_elevation_m: float = 4810.0
var resolution_m: float = 30.0 # Base resolution at LOD 0
var chunk_size_px: int = 512

# Mesh resolution per LOD level (vertex grid size)
const LOD_MESH_RESOLUTION: Array[int] = [
	512, # LOD 0: Full detail (512×512 = 262k vertices)
	256, # LOD 1: Quarter detail (256×256 = 65k vertices)
	128, # LOD 2: 1/16 detail (128×128 = 16k vertices)
	64, # LOD 3: 1/64 detail (64×64 = 4k vertices)
	32, # LOD 4: 1/256 detail (32×32 = 1k vertices)
]

# SHARED MATERIALS: LOD 0-1 use overlay (hex grid); LOD 2+ use same terrain without overlay to reduce doubling.
var shared_terrain_material: Material = null
var shared_terrain_material_lod2plus: Material = null

# Height data cache: path -> heights array. FIFO, max 100 entries.
const HEIGHT_CACHE_MAX: int = 100
var _height_cache: Dictionary = {}
var _height_cache_order: Array = []

# Phase B micro-steps: MESH -> SCENE -> COLLISION (each step can run on a different frame)
enum PhaseBStep { MESH, SCENE, COLLISION }

# Timing instrumentation: set true in Inspector (or here) for [TIME] per-chunk breakdown
@export var DEBUG_CHUNK_TIMING: bool = false
# Hex overlay diagnostics: when true, print [HEX] shader/material/next_pass and initial uniforms at startup
@export var DEBUG_HEX_GRID: bool = false
var _timing_png_read_parse_ms: float = 0.0
var _timing_decompress_ms: float = 0.0
var _timing_filter_ms: float = 0.0
var _timing_mesh_ms: float = 0.0
var _timing_normals_ms: float = 0.0
var _timing_collision_ms: float = 0.0


func _ready() -> void:
	# Load metadata
	if not _load_metadata():
		push_error("TerrainLoader: Failed to load terrain metadata!")
		return
	
	# Create SHARED material for allchunks using the UNIFIED shader
	var shader = load("res://rendering/terrain.gdshader")
	if not shader:
		push_error("TerrainLoader: Failed to load unified terrain shader!")
		return
		
	var shader_material = ShaderMaterial.new()
	shader_material.shader = shader
	
	# Set default params (terrain only; hex overlay is screen-space compositor, not next_pass)
	shader_material.set_shader_parameter("albedo", Color(0.3, 0.5, 0.2)) # Base green
	shader_material.set_shader_parameter("roughness", 0.9)
	shader_material.next_pass = null

	# Overview texture: same world extent as chunk grid (origin 0,0); used for continental color at high altitude
	var overview_path: String = terrain_metadata.get("overview_texture", "")
	var overview_origin_vec := Vector2.ZERO
	var overview_size_vec := Vector2.ZERO
	if overview_path:
		var tex_path: String = Constants.TERRAIN_DATA_PATH + overview_path
		if FileAccess.file_exists(tex_path):
			var img := Image.load_from_file(tex_path)
			if img and not img.is_empty():
				var tex := ImageTexture.create_from_image(img)
				shader_material.set_shader_parameter("overview_texture", tex)
				overview_origin_vec = Vector2.ZERO
				# Always use chunk grid extent (same as ChunkManager overview plane) so macro view aligns
				var mw: int = terrain_metadata.get("master_heightmap_width", 0)
				var mh: int = terrain_metadata.get("master_heightmap_height", 0)
				var grid_w: int = (mw + chunk_size_px - 1) / chunk_size_px
				var grid_h: int = (mh + chunk_size_px - 1) / chunk_size_px
				var ow: float = float(grid_w) * float(chunk_size_px) * resolution_m
				var oh: float = float(grid_h) * float(chunk_size_px) * resolution_m
				overview_size_vec = Vector2(ow, oh)
				shader_material.set_shader_parameter("overview_origin", overview_origin_vec)
				shader_material.set_shader_parameter("overview_size", overview_size_vec)
				shader_material.set_shader_parameter("use_overview", true)
				if OS.is_debug_build():
					print("TerrainLoader: Overview texture loaded (%.0f x %.0f m, grid %dx%d)" % [ow, oh, grid_w, grid_h])
	if overview_size_vec == Vector2.ZERO:
		shader_material.set_shader_parameter("use_overview", false)

	shared_terrain_material = shader_material
	print("[MAT-TRACE] shared_terrain_material shader path: ", shared_terrain_material.shader.resource_path if shared_terrain_material.shader else "NO SHADER")
	print("[MAT-TRACE] shared_terrain_material instance ID: ", shared_terrain_material.get_instance_id())
	# LOD 2+ material: same terrain, no next_pass (hex overlay is screen-space compositor for all LODs).
	var mat_lod2plus: ShaderMaterial = shader_material.duplicate(true) as ShaderMaterial
	mat_lod2plus.next_pass = null
	shared_terrain_material_lod2plus = mat_lod2plus
	print("[MAT-TRACE] shared_terrain_material_lod2plus shader: ", shared_terrain_material_lod2plus.shader.resource_path if shared_terrain_material_lod2plus and shared_terrain_material_lod2plus is ShaderMaterial and shared_terrain_material_lod2plus.shader else "NONE")
	add_to_group("terrain_loader")
	if OS.is_debug_build():
		print("TerrainLoader: Unified terrain shader loaded (hex overlay via screen-space compositor).")


## Load a single chunk and return a complete Node3D with mesh and collision
## Returns null on failure
## chunk_x, chunk_y: Grid coordinates at the specified LOD level
## lod: LOD level (0-4)
## collision_body: StaticBody3D to attach collision shapes to
## debug_colors: If true, color-codes chunks by LOD for visual debugging
func load_chunk(chunk_x: int, chunk_y: int, lod: int, collision_body: StaticBody3D, debug_colors: bool = false) -> Node3D:
	var chunk_path: String = "res://data/terrain/chunks/lod%d/chunk_%d_%d.png" % [lod, chunk_x, chunk_y]
	var total_t0 = Time.get_ticks_msec()
	_timing_png_read_parse_ms = 0.0
	_timing_decompress_ms = 0.0
	_timing_filter_ms = 0.0
	_timing_mesh_ms = 0.0
	_timing_normals_ms = 0.0
	_timing_collision_ms = 0.0
	
	# Check if file exists
	if not FileAccess.file_exists(chunk_path):
		push_error("TerrainLoader: Chunk file not found: " + chunk_path)
		return null
	
	# Read 16-bit heightmap data
	var heights = _load_16bit_heightmap(chunk_path)
	if heights.is_empty():
		push_error("TerrainLoader: Failed to load heightmap from: " + chunk_path)
		return null
	
	# LOD scale factor: 1x for LOD 0, 2x for LOD 1, 4x for LOD 2, etc.
	var lod_scale = int(pow(2, lod))
	var vertex_spacing = resolution_m * lod_scale
	
	# Generate mesh with LOD-scaled vertex spacing and decimated resolution (verbose=false to avoid per-chunk prints)
	var mesh = _generate_mesh_lod(heights, vertex_spacing, lod, false)
	
	# Create MeshInstance3D
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "Chunk_LOD%d_%d_%d" % [lod, chunk_x, chunk_y]
	mesh_instance.mesh = mesh
	
	# Use SHARED material (enables draw call batching)
	# Or use debug colors to visualize LOD levels
	if debug_colors:
		var debug_material = StandardMaterial3D.new()
		# Color by LOD: LOD0=green, LOD1=yellow, LOD2=orange, LOD3=red, LOD4=purple
		var colors = [
			Color(0.0, 1.0, 0.0), # LOD 0: Bright green
			Color(1.0, 1.0, 0.0), # LOD 1: Yellow
			Color(1.0, 0.5, 0.0), # LOD 2: Orange
			Color(1.0, 0.0, 0.0), # LOD 3: Red
			Color(1.0, 0.0, 1.0), # LOD 4: Magenta
		]
		debug_material.albedo_color = colors[lod]
		debug_material.roughness = 0.9
		debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh_instance.set_surface_override_material(0, debug_material)
	else:
		# Hex overlay only on LOD 0-1 so grid is visible where it matters; LOD 2+ no overlay to reduce doubling.
		if lod <= 1:
			mesh_instance.set_surface_override_material(0, shared_terrain_material)
		else:
			mesh_instance.set_surface_override_material(0, shared_terrain_material_lod2plus)
	
	# Position chunk in world space using LOD-aware positioning
	var world_pos = _chunk_to_world_position(chunk_x, chunk_y, lod)
	mesh_instance.position = world_pos
	
	# Add optimized HeightMapShape3D collision for this chunk
	var t_coll_start = Time.get_ticks_msec()
	var collision_shape = _create_heightmap_collision_lod(heights, chunk_x, chunk_y, lod, world_pos.x, world_pos.z, vertex_spacing)
	_timing_collision_ms = Time.get_ticks_msec() - t_coll_start
	if collision_shape and collision_body:
		collision_body.add_child(collision_shape)
	
	if DEBUG_CHUNK_TIMING and OS.is_debug_build():
		var total_ms = Time.get_ticks_msec() - total_t0
		print("[TIME] PNG read + parse: %dms" % int(_timing_png_read_parse_ms))
		print("[TIME] Decompression: %dms" % int(_timing_decompress_ms))
		print("[TIME] Filter reconstruction: %dms" % int(_timing_filter_ms))
		print("[TIME] Mesh generation: %dms" % int(_timing_mesh_ms))
		print("[TIME] Normal computation: %dms" % int(_timing_normals_ms))
		print("[TIME] Collision shape creation: %dms" % int(_timing_collision_ms))
		print("[TIME] Total chunk load: %dms (lod%d_x%d_y%d)" % [total_ms, lod, chunk_x, chunk_y])
	
	return mesh_instance


func _chunk_to_world_position(chunk_x: int, chunk_y: int, lod: int) -> Vector3:
	"""
	Convert chunk grid coordinates to world position.
	Each LOD level has different chunk sizes in world space.
	"""
	var lod_scale = int(pow(2, lod)) # LOD 0 = 1x, LOD 1 = 2x, LOD 2 = 4x, etc.
	var world_chunk_size = chunk_size_px * resolution_m * lod_scale
	
	return Vector3(
		chunk_x * world_chunk_size,
		0,
		chunk_y * world_chunk_size
	)


func _load_metadata() -> bool:
	var metadata_path = "res://data/terrain/terrain_metadata.json"
	
	if not FileAccess.file_exists(metadata_path):
		push_error("Metadata file not found: " + metadata_path)
		return false
	
	var file = FileAccess.open(metadata_path, FileAccess.READ)
	if not file:
		push_error("Failed to open metadata file: " + metadata_path)
		return false
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_text)
	
	if parse_result != OK:
		push_error("Failed to parse metadata JSON: " + json.get_error_message())
		return false
	
	terrain_metadata = json.data
	
	# Extract key values
	max_elevation_m = terrain_metadata.get("max_elevation_m", 4810.0)
	resolution_m = terrain_metadata.get("resolution_m", 30.0) # Base resolution (LOD 0)
	chunk_size_px = terrain_metadata.get("chunk_size_px", 512)
	
	if OS.is_debug_build():
		print("Terrain metadata loaded:")
		print("  Max elevation: %.1f m" % max_elevation_m)
		print("  Base resolution (LOD 0): %.1f m/pixel" % resolution_m)
		print("  Chunk size: %d px" % chunk_size_px)
	
	return true


func _load_16bit_heightmap(path: String) -> Array[float]:
	"""
	Load 16-bit PNG heightmap. Bypasses Godot's Image.load() which downcasts to 8-bit.
	Reads raw PNG bytes and extracts true 16-bit grayscale values.
	Uses a FIFO cache (max 100 entries) to skip decode on re-load.
	"""
	var heights: Array[float] = []
	if _height_cache.has(path):
		if DEBUG_CHUNK_TIMING and OS.is_debug_build():
			print("[CACHE] Hit: %s (skipped decode)" % path.get_file())
		return _height_cache[path]
	if DEBUG_CHUNK_TIMING and OS.is_debug_build():
		print("[CACHE] Miss: %s" % path.get_file())
	if not FileAccess.file_exists(path):
		push_error("Heightmap file not found: " + path)
		return heights
	heights = _parse_16bit_png_raw(path)
	if heights.is_empty():
		# Fallback: try Image and 8-bit (degraded)
		var image = Image.new()
		if image.load(path) == OK and image.get_format() == Image.FORMAT_L8:
			push_error("CRITICAL: 16-bit PNG parse failed! Using degraded 8-bit data.")
			heights = _extract_heights_from_8bit(image)
	var expected_pixels = chunk_size_px * chunk_size_px
	if heights.size() != expected_pixels:
		push_error("Pixel count mismatch! Expected %d, got %d" % [expected_pixels, heights.size()])
		return []
	_add_to_height_cache(path, heights)
	return heights


## Return interpolated height at world XZ (meters). Uses LOD 0 chunk from height cache.
## Returns -1.0 if chunk not in cache (caller cannot build slice).
func get_height_at(world_x: float, world_z: float) -> float:
	var chunk_world_size: float = float(chunk_size_px) * resolution_m
	var chunk_x: int = int(floor(world_x / chunk_world_size))
	var chunk_y: int = int(floor(world_z / chunk_world_size))
	var path: String = "res://data/terrain/chunks/lod0/chunk_%d_%d.png" % [chunk_x, chunk_y]
	if not _height_cache.has(path):
		return -1.0
	var heights: Array = _height_cache[path]
	var lx: float = world_x - float(chunk_x) * chunk_world_size
	var lz: float = world_z - float(chunk_y) * chunk_world_size
	var px: float = lx / resolution_m
	var pz: float = lz / resolution_m
	var w: int = chunk_size_px
	if px < 0.0 or px >= float(w) or pz < 0.0 or pz >= float(w):
		return -1.0
	var i0: int = clampi(int(floor(px)), 0, w - 1)
	var j0: int = clampi(int(floor(pz)), 0, w - 1)
	var i1: int = mini(i0 + 1, w - 1)
	var j1: int = mini(j0 + 1, w - 1)
	var fx: float = clampf(px - float(i0), 0.0, 1.0)
	var fz: float = clampf(pz - float(j0), 0.0, 1.0)
	var h00: float = float(heights[j0 * w + i0])
	var h10: float = float(heights[j0 * w + i1])
	var h01: float = float(heights[j1 * w + i0])
	var h11: float = float(heights[j1 * w + i1])
	var h0: float = lerp(h00, h10, fx)
	var h1: float = lerp(h01, h11, fx)
	return lerp(h0, h1, fz)


## Call from main thread to cache heights decoded on worker (async path).
## Accepts untyped Array so worker result can be passed; converts to Array[float] for cache.
func _add_to_height_cache(path: String, heights: Array) -> void:
	if path.is_empty() or heights.is_empty():
		return
	var typed: Array[float] = []
	for i in range(heights.size()):
		typed.append(float(heights[i]))
	if _height_cache.size() >= HEIGHT_CACHE_MAX and _height_cache_order.size() > 0:
		var oldest = _height_cache_order.pop_front()
		_height_cache.erase(oldest)
	_height_cache[path] = typed
	_height_cache_order.append(path)


## Decode PNG to heights without touching timing (safe for background thread).
func _decode_png_to_heights(path: String, max_elev: float) -> Array[float]:
	var heights: Array[float] = []
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Cannot open file for raw reading: " + path)
		return heights
	var file_bytes = file.get_buffer(file.get_length())
	file.close()
	# PNG signature
	if file_bytes.size() < 8:
		push_error("File too small to be PNG")
		return heights
	var png_sig = PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
	for i in range(8):
		if file_bytes[i] != png_sig[i]:
			push_error("Invalid PNG signature")
			return heights
	var width: int = 0
	var height: int = 0
	var bit_depth: int = 0
	var color_type: int = 0
	var idat_data = PackedByteArray()
	var pos: int = 8
	while pos + 12 <= file_bytes.size():
		var chunk_len = (file_bytes[pos] << 24) | (file_bytes[pos + 1] << 16) | (file_bytes[pos + 2] << 8) | file_bytes[pos + 3]
		var chunk_type = file_bytes.slice(pos + 4, pos + 8)
		pos += 8
		if pos + chunk_len + 4 > file_bytes.size():
			push_error("PNG chunk extends past end of file")
			return []
		if chunk_type[0] == 0x49 and chunk_type[1] == 0x48 and chunk_type[2] == 0x44 and chunk_type[3] == 0x52:
			# IHDR
			if chunk_len != 13:
				push_error("IHDR length != 13")
				return []
			width = (file_bytes[pos] << 24) | (file_bytes[pos + 1] << 16) | (file_bytes[pos + 2] << 8) | file_bytes[pos + 3]
			height = (file_bytes[pos + 4] << 24) | (file_bytes[pos + 5] << 16) | (file_bytes[pos + 6] << 8) | file_bytes[pos + 7]
			bit_depth = file_bytes[pos + 8]
			color_type = file_bytes[pos + 9]
		elif chunk_type[0] == 0x49 and chunk_type[1] == 0x44 and chunk_type[2] == 0x41 and chunk_type[3] == 0x54:
			# IDAT
			idat_data.append_array(file_bytes.slice(pos, pos + chunk_len))
		pos += chunk_len + 4
	if width <= 0 or height <= 0:
		push_error("PNG IHDR missing or invalid width/height")
		return []
	if bit_depth != 16 or color_type != 0:
		push_error("PNG is not 16-bit grayscale: bit_depth=%d color_type=%d" % [bit_depth, color_type])
		return []
	if idat_data.is_empty():
		push_error("No IDAT chunk found")
		return []
	if idat_data.size() < 6:
		push_error("IDAT data too short")
		return []
	var row_bytes = 1 + width * 2
	var expected_size = height * row_bytes
	var decompressed: PackedByteArray
	decompressed = idat_data.decompress_dynamic(expected_size * 2, FileAccess.COMPRESSION_DEFLATE)
	var raw_deflate: PackedByteArray
	if decompressed.size() != expected_size:
		raw_deflate = idat_data.slice(2, idat_data.size() - 4)
		decompressed = raw_deflate.decompress(expected_size, FileAccess.COMPRESSION_DEFLATE)
	if decompressed.size() != expected_size:
		decompressed = raw_deflate.decompress_dynamic(expected_size * 2, FileAccess.COMPRESSION_DEFLATE)
	if decompressed.size() != expected_size:
		push_error("Decompress failed: got %d, expected %d" % [decompressed.size(), expected_size])
		return []
	var bpp: int = 2
	var prev_row = PackedByteArray()
	prev_row.resize(width * 2)
	for i in range(width * 2):
		prev_row[i] = 0
	for y in range(height):
		var row_start = y * row_bytes
		var filter_type = decompressed[row_start]
		var row_data = decompressed.slice(row_start + 1, row_start + row_bytes)
		var recon = _png_reconstruct_row(filter_type, row_data, prev_row, bpp)
		prev_row = recon
		for x in range(width):
			var hi = recon[x * 2]
			var lo = recon[x * 2 + 1]
			var value_16 = (hi << 8) | lo
			# Sea level is stored as SEA_LEVEL_UINT16 in PNG; map back to 0m
			var height_m = (float(value_16) - float(Constants.SEA_LEVEL_UINT16)) / (65535.0 - float(Constants.SEA_LEVEL_UINT16)) * max_elev
			height_m = clampf(height_m, 0.0, max_elev)
			heights.append(height_m)
	return heights


func _parse_16bit_png_raw(path: String) -> Array[float]:
	"""
	Parse PNG file via FileAccess: read raw bytes, find IHDR/IDAT, decompress,
	apply PNG row filters, and extract 16-bit big-endian grayscale values.
	"""
	var t0 = Time.get_ticks_msec()
	var heights = _decode_png_to_heights(path, max_elevation_m)
	_timing_png_read_parse_ms = Time.get_ticks_msec() - t0
	# Decompress/filter time not split out; total attributed to read+parse for sync path
	return heights


func _png_reconstruct_row(filter_type: int, row: PackedByteArray, prev_row: PackedByteArray, bpp: int) -> PackedByteArray:
	"""PNG filter reconstruction. row = raw bytes for this row (excl. filter byte). Returns reconstructed row."""
	var recon = PackedByteArray()
	recon.resize(row.size())
	for i in range(row.size()):
		var x = row[i]
		var a = recon[i - bpp] if i >= bpp else 0
		var b = prev_row[i] if i < prev_row.size() else 0
		var c = prev_row[i - bpp] if (i >= bpp and i < prev_row.size()) else 0
		if filter_type == 0:
			recon[i] = x
		elif filter_type == 1:
			recon[i] = (x + a) & 0xFF
		elif filter_type == 2:
			recon[i] = (x + b) & 0xFF
		elif filter_type == 3:
			recon[i] = (x + ((a + b) >> 1)) & 0xFF
		elif filter_type == 4:
			var p = _paeth(a, b, c)
			recon[i] = (x + p) & 0xFF
		else:
			recon[i] = x
	return recon


func _paeth(a: int, b: int, c: int) -> int:
	var p = a + b - c
	var pa = abs(p - a)
	var pb = abs(p - b)
	var pc = abs(p - c)
	if pa <= pb and pa <= pc:
		return a
	if pb <= pc:
		return b
	return c


func _extract_heights_from_image(image: Image) -> Array[float]:
	"""Extract height values from an Image, regardless of format."""
	
	var heights: Array[float] = []
	
	for y in range(chunk_size_px):
		for x in range(chunk_size_px):
			var pixel = image.get_pixel(x, y)
			
			# Get grayscale value (should be in R channel for grayscale formats)
			var gray_value = pixel.r
			
			# If format is half-float (RH), pixel.r is already in 0-1 range
			# If format is 8-bit, pixel.r is in 0-1 range
			# We need to convert back to 16-bit equivalent
			
			var pixel_value = gray_value * 65535.0
			var height_m = (pixel_value - float(Constants.SEA_LEVEL_UINT16)) / (65535.0 - float(Constants.SEA_LEVEL_UINT16)) * max_elevation_m
			height_m = clampf(height_m, 0.0, max_elevation_m)
			heights.append(height_m)
	
	return heights


func _extract_heights_from_8bit(image: Image) -> Array[float]:
	"""Extract heights from 8-bit image (degraded quality)."""
	
	var heights: Array[float] = []
	
	push_warning("Using 8-bit degraded data - terrain will have ~256 discrete height levels")
	
	for y in range(chunk_size_px):
		for x in range(chunk_size_px):
			var pixel = image.get_pixel(x, y)
			var gray_8bit = pixel.r # 0.0 to 1.0
			var height_m = gray_8bit * max_elevation_m
			heights.append(height_m)
	
	return heights


func _generate_mesh_lod(heights: Array[float], vertex_spacing: float, lod: int, verbose: bool = true) -> ArrayMesh:
	"""
	Generate a terrain mesh from height values with LOD-aware vertex spacing and decimation.
	Higher LODs use fewer vertices (sample every Nth pixel).
	vertex_spacing determines how far apart vertices are in meters.
	lod determines mesh resolution (LOD 0 = 512×512, LOD 4 = 32×32).
	"""
	
	var t0 = Time.get_ticks_msec()
	var mesh_res = LOD_MESH_RESOLUTION[lod]
	var sample_stride = chunk_size_px / mesh_res # How many pixels to skip between samples
	
	# Calculate the actual world-space vertex spacing accounting for both LOD scale AND decimation
	var lod_scale = int(pow(2, lod))
	var chunk_world_size = chunk_size_px * resolution_m * lod_scale
	var actual_vertex_spacing = chunk_world_size / float(mesh_res - 1) # -1 because we want edge-to-edge
	
	if DEBUG_CHUNK_TIMING and verbose and OS.is_debug_build():
		print("Generating mesh: LOD %d, %d×%d vertices, %.1fm spacing..." % [lod, mesh_res, mesh_res, actual_vertex_spacing])
	
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var indices = PackedInt32Array()
	
	# Generate vertices by sampling the heightmap
	for y in range(mesh_res):
		for x in range(mesh_res):
			# Sample from heightmap (ensure we include edges at 0 and 511)
			var px = x * sample_stride
			var py = y * sample_stride
			
			# Clamp to ensure we don't exceed array bounds
			px = mini(px, chunk_size_px - 1)
			py = mini(py, chunk_size_px - 1)
			
			var idx = py * chunk_size_px + px
			var height = heights[idx]
			
			# Position vertices in local chunk space (0 to chunk_world_size)
			var pos = Vector3(
				x * actual_vertex_spacing,
				height,
				y * actual_vertex_spacing
			)
			vertices.append(pos)
	
	if DEBUG_CHUNK_TIMING and verbose and OS.is_debug_build():
		print("Generated %d vertices" % vertices.size())
	
	# Generate indices (two triangles per quad)
	# IMPORTANT: Counter-clockwise winding for Godot (facing up)
	for y in range(mesh_res - 1):
		for x in range(mesh_res - 1):
			var top_left = y * mesh_res + x
			var top_right = top_left + 1
			var bottom_left = (y + 1) * mesh_res + x
			var bottom_right = bottom_left + 1
			
			# First triangle (counter-clockwise when viewed from above)
			indices.append(top_left)
			indices.append(top_right)
			indices.append(bottom_left)
			
			# Second triangle (counter-clockwise when viewed from above)
			indices.append(top_right)
			indices.append(bottom_right)
			indices.append(bottom_left)
	
	if DEBUG_CHUNK_TIMING and verbose and OS.is_debug_build():
		print("Generated %d triangles" % (indices.size() / 3))
	
	_timing_mesh_ms = Time.get_ticks_msec() - t0
	var t_norm = Time.get_ticks_msec()
	# Compute normals with LOD-aware spacing
	normals = _compute_normals_lod_decimated(heights, actual_vertex_spacing, mesh_res, sample_stride, lod)
	_timing_normals_ms = Time.get_ticks_msec() - t_norm
	
	# Build mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	return mesh


func _compute_normals_lod_decimated(heights: Array[float], actual_vertex_spacing: float, mesh_res: int, sample_stride: int, lod: int) -> PackedVector3Array:
	"""
	Compute vertex normals for decimated mesh using sampled heightmap data.
	actual_vertex_spacing is the world-space distance between adjacent vertices.
	mesh_res is the vertex grid size (e.g., 128 for LOD 2).
	sample_stride is how many pixels we skip between samples.
	"""
	
	var normals = PackedVector3Array()
	normals.resize(mesh_res * mesh_res)
	
	for y in range(mesh_res):
		for x in range(mesh_res):
			var idx = y * mesh_res + x
			
			# Get heightmap pixel coordinates
			var px = x * sample_stride
			var py = y * sample_stride
			px = mini(px, chunk_size_px - 1)
			py = mini(py, chunk_size_px - 1)
			
			var h_idx = py * chunk_size_px + px
			var h_center = heights[h_idx]
			
			# Get neighboring heights (sample at same stride)
			var h_left = h_center
			var h_right = h_center
			var h_up = h_center
			var h_down = h_center
			
			if x > 0:
				var px_left = (x - 1) * sample_stride
				px_left = mini(px_left, chunk_size_px - 1)
				h_left = heights[py * chunk_size_px + px_left]
			
			if x < mesh_res - 1:
				var px_right = (x + 1) * sample_stride
				px_right = mini(px_right, chunk_size_px - 1)
				h_right = heights[py * chunk_size_px + px_right]
			
			if y > 0:
				var py_up = (y - 1) * sample_stride
				py_up = mini(py_up, chunk_size_px - 1)
				h_up = heights[py_up * chunk_size_px + px]
			
			if y < mesh_res - 1:
				var py_down = (y + 1) * sample_stride
				py_down = mini(py_down, chunk_size_px - 1)
				h_down = heights[py_down * chunk_size_px + px]
			
			# Compute tangent vectors using actual world-space vertex spacing
			var tangent_x = Vector3(actual_vertex_spacing * 2.0, h_right - h_left, 0)
			var tangent_z = Vector3(0, h_down - h_up, actual_vertex_spacing * 2.0)
			
			# Normal is cross product
			var normal = tangent_z.cross(tangent_x).normalized()
			
			normals[idx] = normal
	
	return normals


func _create_heightmap_collision_lod(heights: Array[float], chunk_x: int, chunk_y: int, lod: int, world_x: float, world_z: float, vertex_spacing: float) -> CollisionShape3D:
	"""
	Create optimized HeightMapShape3D collision for this chunk with LOD-aware scaling and decimation.
	CRITICAL: HeightMapShape3D must be positioned to exactly match the rendered mesh.
	Returns the CollisionShape3D node (caller must add it to collision body).
	"""
	
	var mesh_res = LOD_MESH_RESOLUTION[lod]
	var sample_stride = chunk_size_px / mesh_res
	
	# Convert sampled heights to PackedFloat32Array for HeightMapShape3D
	var height_data = PackedFloat32Array()
	height_data.resize(mesh_res * mesh_res)
	
	# Sample the heightmap at the same resolution as the mesh
	for y in range(mesh_res):
		for x in range(mesh_res):
			var px = x * sample_stride
			var py = y * sample_stride
			px = mini(px, chunk_size_px - 1)
			py = mini(py, chunk_size_px - 1)
			
			var h_idx = py * chunk_size_px + px
			height_data[y * mesh_res + x] = heights[h_idx]
	
	# Create HeightMapShape3D
	var heightmap_shape = HeightMapShape3D.new()
	
	# CRITICAL: Set dimensions BEFORE setting map_data
	heightmap_shape.map_width = mesh_res
	heightmap_shape.map_depth = mesh_res
	heightmap_shape.map_data = height_data
	
	# Create CollisionShape3D
	var collision_shape = CollisionShape3D.new()
	collision_shape.shape = heightmap_shape
	collision_shape.name = "HeightMap_LOD%d_%d_%d" % [lod, chunk_x, chunk_y]
	
	# Calculate chunk world size
	var lod_scale = int(pow(2, lod))
	var chunk_world_size = chunk_size_px * resolution_m * lod_scale
	
	# Position collision shape to match the mesh
	# CRITICAL: HeightMapShape3D is centered on its local origin!
	# The mesh is built from (0,0) to (+size, +size) in local space (top-left anchor).
	# To align a centered shape with a top-left mesh, we must shift the shape by +size/2.
	var half_size = chunk_world_size * 0.5
	collision_shape.position = Vector3(world_x + half_size, 0, world_z + half_size)
	
	# Scale the collision shape
	# The spacing between height samples in world units
	var height_sample_spacing = chunk_world_size / float(mesh_res - 1)
	collision_shape.scale = Vector3(height_sample_spacing, 1.0, height_sample_spacing)
	
	return collision_shape


# --- Async load: Phase A (background) produces arrays; Phase B (main) creates nodes ---

## Start async load: Phase A runs on WorkerThreadPool. Returns { task_id, args }.
## Caller stores args; when is_task_completed(task_id), wait then finish_load(args["result"], ...).
## debug_diagnostic: when true, worker may print height pipeline diagnostics for the Alps chunk (67,35) LOD 0.
func start_async_load(chunk_x: int, chunk_y: int, lod: int, debug_diagnostic: bool = false) -> Dictionary:
	var chunk_path: String = "res://data/terrain/chunks/lod%d/chunk_%d_%d.png" % [lod, chunk_x, chunk_y]
	var args: Dictionary = {
		"chunk_x": chunk_x,
		"chunk_y": chunk_y,
		"lod": lod,
		"resolution_m": resolution_m,
		"chunk_size_px": chunk_size_px,
		"max_elevation_m": max_elevation_m,
		"LOD_MESH_RESOLUTION": LOD_MESH_RESOLUTION.duplicate(),
		"result": {},
		"debug_diagnostic": debug_diagnostic
	}
	if _height_cache.has(chunk_path):
		args["heights"] = _height_cache[chunk_path]
	else:
		args["path"] = chunk_path
	# Use TerrainWorker (static class) so worker never references this node; avoids "previously freed" and editor freeze on stop
	var callable_task = Callable(_TerrainWorkerScript, "compute_chunk_data").bind(args)
	var task_id = WorkerThreadPool.add_task(callable_task, false, "chunk_lod%d_%d_%d" % [lod, chunk_x, chunk_y])
	if DEBUG_CHUNK_TIMING and OS.is_debug_build():
		print("[ASYNC] Submitted lod%d_x%d_y%d" % [lod, chunk_x, chunk_y])
	return { "task_id": task_id, "args": args }


## Phase A: run on worker. No Nodes, no scene tree. Writes computed arrays into args["result"].
func _compute_chunk_data(args: Dictionary) -> void:
	var lod: int = args["lod"]
	var chunk_x: int = args["chunk_x"]
	var chunk_y: int = args["chunk_y"]
	var res_m: float = args["resolution_m"]
	var cpx: int = args["chunk_size_px"]
	var max_elev: float = args["max_elevation_m"]
	var mesh_resolutions: Array = args["LOD_MESH_RESOLUTION"]
	var heights: Array[float]
	var did_decode: bool = false
	if args.has("heights"):
		heights = args["heights"]
	else:
		heights = _decode_png_to_heights(args["path"], max_elev)
		did_decode = true
	if heights.is_empty():
		args["result"] = {}
		return
	var lod_scale: int = int(pow(2, lod))
	var chunk_world_size: float = cpx * res_m * lod_scale
	var world_pos = Vector3(chunk_x * chunk_world_size, 0, chunk_y * chunk_world_size)
	# LOD 4 ultra: at continental zoom chunks are a few pixels; flat quad at avg elevation is enough
	var ultra_lod = (lod == 4)
	var avg_elevation = 0.0
	if ultra_lod:
		var sum_h = 0.0
		for h in heights:
			sum_h += h
		avg_elevation = sum_h / heights.size()
		args["result"] = {
			"chunk_x": chunk_x,
			"chunk_y": chunk_y,
			"lod": lod,
			"world_pos": world_pos,
			"mesh_res": 2,
			"chunk_world_size": chunk_world_size,
			"height_sample_spacing": chunk_world_size,
			"heights_for_cache": heights if did_decode else [],
			"path_for_cache": args.get("path", ""),
			"ultra_lod": true,
			"avg_elevation": avg_elevation,
			"vertices": PackedVector3Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array(),
			"height_data": PackedFloat32Array()
		}
		return
	var mesh_res: int = mesh_resolutions[lod]
	var sample_stride: int = cpx / mesh_res
	var actual_vertex_spacing: float = chunk_world_size / float(mesh_res - 1)
	var vertices = PackedVector3Array()
	var indices = PackedInt32Array()
	for y in range(mesh_res):
		for x in range(mesh_res):
			var px = mini(x * sample_stride, cpx - 1)
			var py = mini(y * sample_stride, cpx - 1)
			var h = heights[py * cpx + px]
			vertices.append(Vector3(x * actual_vertex_spacing, h, y * actual_vertex_spacing))
	for y in range(mesh_res - 1):
		for x in range(mesh_res - 1):
			var top_left = y * mesh_res + x
			var top_right = top_left + 1
			var bottom_left = (y + 1) * mesh_res + x
			var bottom_right = bottom_left + 1
			indices.append(top_left)
			indices.append(top_right)
			indices.append(bottom_left)
			indices.append(top_right)
			indices.append(bottom_right)
			indices.append(bottom_left)
	var normals = _compute_normals_lod_decimated(heights, actual_vertex_spacing, mesh_res, sample_stride, lod)
	var height_data = PackedFloat32Array()
	height_data.resize(mesh_res * mesh_res)
	for y in range(mesh_res):
		for x in range(mesh_res):
			var px = mini(x * sample_stride, cpx - 1)
			var py = mini(y * sample_stride, cpx - 1)
			height_data[y * mesh_res + x] = heights[py * cpx + px]
	var height_sample_spacing = chunk_world_size / float(mesh_res - 1)
	args["result"] = {
		"vertices": vertices,
		"normals": normals,
		"indices": indices,
		"height_data": height_data,
		"chunk_x": chunk_x,
		"chunk_y": chunk_y,
		"lod": lod,
		"world_pos": world_pos,
		"mesh_res": mesh_res,
		"chunk_world_size": chunk_world_size,
		"height_sample_spacing": height_sample_spacing,
		"heights_for_cache": heights if did_decode else [],
		"path_for_cache": args.get("path", ""),
		"ultra_lod": false,
		"avg_elevation": 0.0
	}


## Phase B step 1 (MESH): Create ArrayMesh only. Returns mesh or null.
func finish_load_step_mesh(computed_data: Dictionary) -> ArrayMesh:
	if computed_data.is_empty():
		return null
	var chunk_world_size: float = computed_data["chunk_world_size"]
	if computed_data.get("ultra_lod", false):
		# LOD 4 ultra: flat quad at average elevation (<1ms)
		var avg_y: float = computed_data.get("avg_elevation", 0.0)
		var u_verts = PackedVector3Array([
			Vector3(0, avg_y, 0),
			Vector3(chunk_world_size, avg_y, 0),
			Vector3(chunk_world_size, avg_y, chunk_world_size),
			Vector3(0, avg_y, chunk_world_size)
		])
		var u_normals = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
		var u_indices = PackedInt32Array([0, 1, 2, 0, 2, 3])
		var u_arrays: Array = []
		u_arrays.resize(Mesh.ARRAY_MAX)
		u_arrays[Mesh.ARRAY_VERTEX] = u_verts
		u_arrays[Mesh.ARRAY_NORMAL] = u_normals
		u_arrays[Mesh.ARRAY_INDEX] = u_indices
		var u_mesh = ArrayMesh.new()
		u_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, u_arrays)
		return u_mesh
	var vertices: PackedVector3Array = computed_data["vertices"]
	var normals: PackedVector3Array = computed_data["normals"]
	var indices: PackedInt32Array = computed_data["indices"]
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Phase B step 2 (SCENE): Create MeshInstance3D, set material and transform. Caller adds to scene.
func finish_load_step_scene(computed_data: Dictionary, mesh: ArrayMesh, debug_colors: bool = false) -> MeshInstance3D:
	if mesh == null:
		return null
	var chunk_x: int = computed_data["chunk_x"]
	var chunk_y: int = computed_data["chunk_y"]
	var lod: int = computed_data["lod"]
	var world_pos: Vector3 = computed_data["world_pos"]
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "Chunk_LOD%d_%d_%d" % [lod, chunk_x, chunk_y]
	mesh_instance.mesh = mesh
	if debug_colors:
		var debug_material = StandardMaterial3D.new()
		var colors = [
			Color(0.0, 1.0, 0.0), Color(1.0, 1.0, 0.0), Color(1.0, 0.5, 0.0),
			Color(1.0, 0.0, 0.0), Color(1.0, 0.0, 1.0)
		]
		debug_material.albedo_color = colors[lod]
		debug_material.roughness = 0.9
		debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh_instance.set_surface_override_material(0, debug_material)
	else:
		if lod <= 1:
			mesh_instance.set_surface_override_material(0, shared_terrain_material)
		else:
			mesh_instance.set_surface_override_material(0, shared_terrain_material_lod2plus)
	var surf_mat = mesh_instance.get_surface_override_material(0)
	print("[MAT-TRACE] Chunk material shader: ", surf_mat.shader.resource_path if surf_mat is ShaderMaterial and surf_mat.shader else "NOT ShaderMaterial or no override")
	print("[MAT-TRACE] Chunk material ID: ", surf_mat.get_instance_id() if surf_mat else "NO OVERRIDE")
	print("[MAT-TRACE] Chunk surface material: ", mesh_instance.mesh.surface_get_material(0) if mesh_instance.mesh and mesh_instance.mesh.get_surface_count() > 0 else "NO SURFACE MATERIAL")
	mesh_instance.position = world_pos
	return mesh_instance


## Phase B step 3 (COLLISION): Create HeightMapShape3D + CollisionShape3D, add to body. No-op for LOD >= 2.
func finish_load_step_collision(computed_data: Dictionary, collision_body: StaticBody3D) -> void:
	var lod: int = computed_data["lod"]
	if lod >= 2:
		return
	if computed_data.get("ultra_lod", false):
		return
	if collision_body == null:
		return
	var height_data: PackedFloat32Array = computed_data["height_data"]
	var chunk_x: int = computed_data["chunk_x"]
	var chunk_y: int = computed_data["chunk_y"]
	var world_pos: Vector3 = computed_data["world_pos"]
	var mesh_res: int = computed_data["mesh_res"]
	var chunk_world_size: float = computed_data["chunk_world_size"]
	var height_sample_spacing: float = computed_data["height_sample_spacing"]
	var heightmap_shape = HeightMapShape3D.new()
	heightmap_shape.map_width = mesh_res
	heightmap_shape.map_depth = mesh_res
	heightmap_shape.map_data = height_data
	var collision_shape = CollisionShape3D.new()
	collision_shape.shape = heightmap_shape
	collision_shape.name = "HeightMap_LOD%d_%d_%d" % [lod, chunk_x, chunk_y]
	var half_size = chunk_world_size * 0.5
	collision_shape.position = Vector3(world_pos.x + half_size, 0, world_pos.z + half_size)
	collision_shape.scale = Vector3(height_sample_spacing, 1.0, height_sample_spacing)
	collision_body.add_child(collision_shape)


## Legacy: full Phase B in one call (for initial load only). Creates mesh, scene node, and collision (LOD 0-1).
func finish_load(computed_data: Dictionary, collision_body: StaticBody3D, debug_colors: bool = false) -> Node3D:
	if computed_data.is_empty():
		return null
	var mesh = finish_load_step_mesh(computed_data)
	if mesh == null:
		return null
	var mesh_instance = finish_load_step_scene(computed_data, mesh, debug_colors)
	if mesh_instance == null:
		return null
	finish_load_step_collision(computed_data, collision_body)
	if DEBUG_CHUNK_TIMING and OS.is_debug_build():
		print("[ASYNC] Completed lod%d_x%d_y%d (Phase B: full)" % [computed_data["lod"], computed_data["chunk_x"], computed_data["chunk_y"]])
	return mesh_instance
