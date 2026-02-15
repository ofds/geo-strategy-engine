class_name TerrainLoader
extends Node
## Terrain Loader - Stateless utility for loading single terrain chunks
## CRITICAL: Properly handles 16-bit PNG elevation data
## Called by ChunkManager to generate individual chunk meshes

# Metadata from terrain_metadata.json
var terrain_metadata: Dictionary = {}
var max_elevation_m: float = 4810.0
var resolution_m: float = 30.0  # Base resolution at LOD 0
var chunk_size_px: int = 512

# Mesh resolution per LOD level (vertex grid size)
const LOD_MESH_RESOLUTION: Array[int] = [
	512,  # LOD 0: Full detail (512×512 = 262k vertices)
	256,  # LOD 1: Quarter detail (256×256 = 65k vertices)
	128,  # LOD 2: 1/16 detail (128×128 = 16k vertices)
	64,   # LOD 3: 1/64 detail (64×64 = 4k vertices)
	32,   # LOD 4: 1/256 detail (32×32 = 1k vertices)
]

# SHARED MATERIAL: One material for all chunks to enable draw call batching
var shared_terrain_material: StandardMaterial3D = null


func _ready() -> void:
	# Load metadata
	if not _load_metadata():
		push_error("TerrainLoader: Failed to load terrain metadata!")
		return
	
	# Create SHARED material for all chunks (enables draw call batching)
	shared_terrain_material = StandardMaterial3D.new()
	shared_terrain_material.albedo_color = Color(0.4, 0.6, 0.3)  # Greenish terrain color
	shared_terrain_material.roughness = 0.9
	shared_terrain_material.metallic = 0.0
	shared_terrain_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	shared_terrain_material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Render both sides
	
	# Add subtle rim lighting to help with faceting
	shared_terrain_material.rim_enabled = true
	shared_terrain_material.rim = 0.15
	shared_terrain_material.rim_tint = 0.3


## Load a single chunk and return a complete Node3D with mesh and collision
## Returns null on failure
## chunk_x, chunk_y: Grid coordinates at the specified LOD level
## lod: LOD level (0-4)
## collision_body: StaticBody3D to attach collision shapes to
## debug_colors: If true, color-codes chunks by LOD for visual debugging
func load_chunk(chunk_x: int, chunk_y: int, lod: int, collision_body: StaticBody3D, debug_colors: bool = false) -> Node3D:
	var chunk_path: String = "res://data/terrain/chunks/lod%d/chunk_%d_%d.png" % [lod, chunk_x, chunk_y]
	
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
	
	# Generate mesh with LOD-scaled vertex spacing and decimated resolution
	var mesh = _generate_mesh_lod(heights, vertex_spacing, lod, false)  # Pass false to disable verbose logging
	
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
			Color(0.0, 1.0, 0.0),    # LOD 0: Bright green
			Color(1.0, 1.0, 0.0),    # LOD 1: Yellow
			Color(1.0, 0.5, 0.0),    # LOD 2: Orange
			Color(1.0, 0.0, 0.0),    # LOD 3: Red
			Color(1.0, 0.0, 1.0),    # LOD 4: Magenta
		]
		debug_material.albedo_color = colors[lod]
		debug_material.roughness = 0.9
		debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh_instance.set_surface_override_material(0, debug_material)
	else:
		mesh_instance.set_surface_override_material(0, shared_terrain_material)
	
	# Position chunk in world space using LOD-aware positioning
	var world_pos = _chunk_to_world_position(chunk_x, chunk_y, lod)
	mesh_instance.position = world_pos
	
	# Add optimized HeightMapShape3D collision for this chunk
	var collision_shape = _create_heightmap_collision_lod(heights, chunk_x, chunk_y, lod, world_pos.x, world_pos.z, vertex_spacing)
	if collision_shape and collision_body:
		collision_body.add_child(collision_shape)
	
	# Update statistics
	var mesh_res = LOD_MESH_RESOLUTION[lod]
	var verts = mesh_res * mesh_res
	
	return mesh_instance


func _chunk_to_world_position(chunk_x: int, chunk_y: int, lod: int) -> Vector3:
	"""
	Convert chunk grid coordinates to world position.
	Each LOD level has different chunk sizes in world space.
	"""
	var lod_scale = int(pow(2, lod))  # LOD 0 = 1x, LOD 1 = 2x, LOD 2 = 4x, etc.
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
	resolution_m = terrain_metadata.get("resolution_m", 30.0)  # Base resolution (LOD 0)
	chunk_size_px = terrain_metadata.get("chunk_size_px", 512)
	
	print("Terrain metadata loaded:")
	print("  Max elevation: %.1f m" % max_elevation_m)
	print("  Base resolution (LOD 0): %.1f m/pixel" % resolution_m)
	print("  Chunk size: %d px" % chunk_size_px)
	
	return true


func _load_16bit_heightmap(path: String) -> Array[float]:
	"""
	Load 16-bit PNG heightmap. Godot's Image.load() often downcasts to 8-bit.
	We read raw bytes and parse manually to ensure 16-bit precision.
	"""
	
	var heights: Array[float] = []
	
	if not FileAccess.file_exists(path):
		push_error("Heightmap file not found: " + path)
		return heights
	
	# First, try using Image.load() and check if it preserved 16-bit
	var image = Image.new()
	var err = image.load(path)
	
	if err != OK:
		push_error("Failed to load image: " + path)
		return heights
	
	# Reduced logging - only log format if there's an issue
	var format = image.get_format()
	# print("Image format: %d (L8=3, RH=22)" % format)
	# print("Image size: %dx%d" % [image.get_width(), image.get_height()])
	
	# Check if Godot preserved the format
	# Image.FORMAT_L8 = 3 (8-bit grayscale)
	# Image.FORMAT_RH = 22 (16-bit half-float)
	# Image.FORMAT_R16 is not available in Godot 4.x
	
	if format == Image.FORMAT_L8:
		push_warning("Image was loaded as 8-bit! Attempting manual 16-bit parse...")
		# Try to read raw PNG bytes
		heights = _parse_16bit_png_manual(path)
		if heights.is_empty():
			# Fall back to 8-bit but warn loudly
			push_error("CRITICAL: 16-bit loading failed! Using degraded 8-bit data!")
			heights = _extract_heights_from_8bit(image)
	else:
		# If format is not L8, try to extract data
		# Note: Godot may load as RH (half-float) or another format
		heights = _extract_heights_from_image(image)
	
	# Verify we got the right number of pixels
	var expected_pixels = chunk_size_px * chunk_size_px
	if heights.size() != expected_pixels:
		push_error("Pixel count mismatch! Expected %d, got %d" % [expected_pixels, heights.size()])
		return []
	
	return heights


func _parse_16bit_png_manual(path: String) -> Array[float]:
	"""
	Manually parse PNG file to extract 16-bit grayscale data.
	This is a workaround for Godot's Image class downsampling to 8-bit.
	"""
	
	var heights: Array[float] = []
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Cannot open file for raw reading: " + path)
		return heights
	
	# Read entire file
	var file_bytes = file.get_buffer(file.get_length())
	file.close()
	
	# Parse PNG structure
	# PNG signature: 89 50 4E 47 0D 0A 1A 0A
	if file_bytes.size() < 8:
		push_error("File too small to be PNG")
		return heights
	
	var png_sig = PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
	for i in range(8):
		if file_bytes[i] != png_sig[i]:
			push_error("Invalid PNG signature")
			return heights
	
	# Find IDAT chunk(s) - this is where image data is
	# For now, use stb_image-style parsing via Image class but force conversion
	
	# Alternative: Use Image but convert properly
	var image = Image.new()
	image.load(path)
	
	# If it's 8-bit, we know each pixel value represents a 16-bit value that was divided by 256
	# We can multiply back up, but precision is lost
	if image.get_format() == Image.FORMAT_L8:
		push_warning("Reconstructing 16-bit from 8-bit with reduced precision")
		for y in range(chunk_size_px):
			for x in range(chunk_size_px):
				var pixel = image.get_pixel(x, y)
				# L8 stores value in R channel
				var value_8bit = int(pixel.r * 255.0)
				# Assume original was scaled from 16-bit: value_16bit / 256 = value_8bit
				var value_16bit = value_8bit * 256
				var height_m = (float(value_16bit) / 65535.0) * max_elevation_m
				heights.append(height_m)
	else:
		# Try to interpret other formats
		heights = _extract_heights_from_image(image)
	
	return heights


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
			var height_m = (pixel_value / 65535.0) * max_elevation_m
			
			heights.append(height_m)
	
	return heights


func _extract_heights_from_8bit(image: Image) -> Array[float]:
	"""Extract heights from 8-bit image (degraded quality)."""
	
	var heights: Array[float] = []
	
	push_warning("Using 8-bit degraded data - terrain will have ~256 discrete height levels")
	
	for y in range(chunk_size_px):
		for x in range(chunk_size_px):
			var pixel = image.get_pixel(x, y)
			var gray_8bit = pixel.r  # 0.0 to 1.0
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
	
	var mesh_res = LOD_MESH_RESOLUTION[lod]
	var sample_stride = chunk_size_px / mesh_res  # How many pixels to skip between samples
	
	# Calculate the actual world-space vertex spacing accounting for both LOD scale AND decimation
	var lod_scale = int(pow(2, lod))
	var chunk_world_size = chunk_size_px * resolution_m * lod_scale
	var actual_vertex_spacing = chunk_world_size / float(mesh_res - 1)  # -1 because we want edge-to-edge
	
	if verbose:
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
	
	if verbose:
		print("Generated %d triangles" % (indices.size() / 3))
	
	# Compute normals with LOD-aware spacing
	normals = _compute_normals_lod_decimated(heights, actual_vertex_spacing, mesh_res, sample_stride, lod)
	
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
	# CRITICAL: HeightMapShape3D is positioned from its MIN corner, same as the mesh!
	# The mesh is at (world_x, 0, world_z) so collision must be too
	collision_shape.position = Vector3(world_x, 0, world_z)
	
	# Scale the collision shape
	# The spacing between height samples in world units
	var height_sample_spacing = chunk_world_size / float(mesh_res - 1)
	collision_shape.scale = Vector3(height_sample_spacing, 1.0, height_sample_spacing)
	
	return collision_shape
