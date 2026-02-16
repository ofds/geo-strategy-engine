class_name TerrainWorker
extends RefCounted
## Stateless worker for Phase A chunk computation. Used by WorkerThreadPool.
## All methods are static so no scene node is referenced; tasks keep running safely after scene free.

static func _paeth(a: int, b: int, c: int) -> int:
	var p = a + b - c
	var pa = abs(p - a)
	var pb = abs(p - b)
	var pc = abs(p - c)
	if pa <= pb and pa <= pc:
		return a
	if pb <= pc:
		return b
	return c


static func _png_reconstruct_row(filter_type: int, row: PackedByteArray, prev_row: PackedByteArray, bpp: int) -> PackedByteArray:
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


## Optional diag_raw: if non-empty and has key "collect", fill with raw_min, raw_max, raw_sample (10 center values)
static func decode_png_to_heights(path: String, max_elev: float, diag_raw: Dictionary = {}) -> Array:
	var heights: Array = []
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return heights
	var file_bytes = file.get_buffer(file.get_length())
	file.close()
	if file_bytes.size() < 8:
		return heights
	var png_sig = PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
	for i in range(8):
		if file_bytes[i] != png_sig[i]:
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
			return []
		if chunk_type[0] == 0x49 and chunk_type[1] == 0x48 and chunk_type[2] == 0x44 and chunk_type[3] == 0x52:
			if chunk_len != 13:
				return []
			width = (file_bytes[pos] << 24) | (file_bytes[pos + 1] << 16) | (file_bytes[pos + 2] << 8) | file_bytes[pos + 3]
			height = (file_bytes[pos + 4] << 24) | (file_bytes[pos + 5] << 16) | (file_bytes[pos + 6] << 8) | file_bytes[pos + 7]
			bit_depth = file_bytes[pos + 8]
			color_type = file_bytes[pos + 9]
		elif chunk_type[0] == 0x49 and chunk_type[1] == 0x44 and chunk_type[2] == 0x41 and chunk_type[3] == 0x54:
			idat_data.append_array(file_bytes.slice(pos, pos + chunk_len))
		pos += chunk_len + 4
	if width <= 0 or height <= 0 or bit_depth != 16 or color_type != 0 or idat_data.is_empty() or idat_data.size() < 6:
		return []
	var row_bytes = 1 + width * 2
	var expected_size = height * row_bytes
	var decompressed: PackedByteArray = idat_data.decompress_dynamic(expected_size * 2, FileAccess.COMPRESSION_DEFLATE)
	var raw_deflate: PackedByteArray
	if decompressed.size() != expected_size:
		raw_deflate = idat_data.slice(2, idat_data.size() - 4)
		decompressed = raw_deflate.decompress(expected_size, FileAccess.COMPRESSION_DEFLATE)
	if decompressed.size() != expected_size:
		decompressed = raw_deflate.decompress_dynamic(expected_size * 2, FileAccess.COMPRESSION_DEFLATE)
	if decompressed.size() != expected_size:
		return []
	var do_diag_raw: bool = diag_raw.get("collect", false)
	var raw_min: int = 65535
	var raw_max: int = 0
	var raw_sample: Array = []
	var center_y: int = height / 2
	var center_x_start: int = maxi(0, width / 2 - 5)
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
			if do_diag_raw:
				raw_min = mini(raw_min, value_16)
				raw_max = maxi(raw_max, value_16)
				if y == center_y and x >= center_x_start and raw_sample.size() < 10:
					raw_sample.append(value_16)
			var height_m = (float(value_16) - float(Constants.SEA_LEVEL_UINT16)) / (65535.0 - float(Constants.SEA_LEVEL_UINT16)) * max_elev
			height_m = clampf(height_m, 0.0, max_elev)
			heights.append(height_m)
	if do_diag_raw:
		diag_raw["raw_min"] = raw_min
		diag_raw["raw_max"] = raw_max
		diag_raw["raw_sample"] = raw_sample
	return heights


static func compute_normals_lod_decimated(heights: Array, actual_vertex_spacing: float, mesh_res: int, sample_stride: int, cpx: int) -> PackedVector3Array:
	var normals = PackedVector3Array()
	normals.resize(mesh_res * mesh_res)
	for y in range(mesh_res):
		for x in range(mesh_res):
			var idx = y * mesh_res + x
			var px = x * sample_stride
			var py = y * sample_stride
			px = mini(px, cpx - 1)
			py = mini(py, cpx - 1)
			var h_idx = py * cpx + px
			var h_center = heights[h_idx]
			var h_left = h_center
			var h_right = h_center
			var h_up = h_center
			var h_down = h_center
			if x > 0:
				var px_left = (x - 1) * sample_stride
				px_left = mini(px_left, cpx - 1)
				h_left = heights[py * cpx + px_left]
			if x < mesh_res - 1:
				var px_right = (x + 1) * sample_stride
				px_right = mini(px_right, cpx - 1)
				h_right = heights[py * cpx + px_right]
			if y > 0:
				var py_up = (y - 1) * sample_stride
				py_up = mini(py_up, cpx - 1)
				h_up = heights[py_up * cpx + px]
			if y < mesh_res - 1:
				var py_down = (y + 1) * sample_stride
				py_down = mini(py_down, cpx - 1)
				h_down = heights[py_down * cpx + px]
			var tangent_x = Vector3(actual_vertex_spacing * 2.0, h_right - h_left, 0)
			var tangent_z = Vector3(0, h_down - h_up, actual_vertex_spacing * 2.0)
			normals[idx] = tangent_z.cross(tangent_x).normalized()
	return normals


## Alps center chunk for height diagnostics (Europe grid: dramatic terrain)
const _DIAG_ALPS_CHUNK_X: int = 67
const _DIAG_ALPS_CHUNK_Y: int = 35

## Phase A: run on worker. Writes to args["result"]. No reference to any Node.
static func compute_chunk_data(args: Dictionary) -> void:
	var lod: int = args["lod"]
	var chunk_x: int = args["chunk_x"]
	var chunk_y: int = args["chunk_y"]
	var res_m: float = args["resolution_m"]
	var cpx: int = args["chunk_size_px"]
	var max_elev: float = args["max_elevation_m"]
	var mesh_resolutions: Array = args["LOD_MESH_RESOLUTION"]
	var debug_diag: bool = args.get("debug_diagnostic", false)
	var is_alps_chunk: bool = (chunk_x == _DIAG_ALPS_CHUNK_X and chunk_y == _DIAG_ALPS_CHUNK_Y and lod == 0)
	var do_height_diag: bool = debug_diag and is_alps_chunk
	var heights: Array
	var did_decode: bool = false
	var diag_raw: Dictionary = {}
	if do_height_diag:
		diag_raw["collect"] = true
	if args.has("heights"):
		heights = args["heights"]
	else:
		heights = decode_png_to_heights(args["path"], max_elev, diag_raw)
		did_decode = true
	if heights.is_empty():
		args["result"] = {}
		return
	# Stage 1: Raw PNG (Alps chunk only, when debug_diagnostic)
	if do_height_diag and OS.is_debug_build() and diag_raw.has("raw_min"):
		var raw_sample_str: String = ""
		for v in diag_raw.get("raw_sample", []):
			raw_sample_str += str(v) + ", "
		print("[HEIGHT] Raw uint16: min=%d max=%d sample=[%s]" % [diag_raw["raw_min"], diag_raw["raw_max"], raw_sample_str.strip_edges().trim_suffix(",")])
	# Stage 2: Converted elevation (meters)
	var elev_min: float = 1e9
	var elev_max: float = -1e9
	for h in heights:
		elev_min = minf(elev_min, h)
		elev_max = maxf(elev_max, h)
	if do_height_diag and OS.is_debug_build():
		print("[HEIGHT] Elevation meters: min=%.1fm max=%.1fm range=%.1fm" % [elev_min, elev_max, elev_max - elev_min])
	var lod_scale: int = int(pow(2, lod))
	var chunk_world_size: float = cpx * res_m * lod_scale
	var world_pos = Vector3(chunk_x * chunk_world_size, 0, chunk_y * chunk_world_size)
	# LOD 4 ultra path disabled: was producing flat green planes; use normal 32x32 mesh instead
	var mesh_res: int = mesh_resolutions[lod]
	var sample_stride: int = cpx / mesh_res  # Integer division: pixels per vertex
	if do_height_diag and OS.is_debug_build():
		print("[DECIMATE] LOD %d step=%d -> %dx%d vertices" % [lod, sample_stride, mesh_res, mesh_res])
	var actual_vertex_spacing: float = chunk_world_size / float(mesh_res - 1)
	var uv_scale_x: float = 1.0 / maxf(1.0, float(mesh_res) - 1.0)
	var uv_scale_y: float = 1.0 / maxf(1.0, float(mesh_res) - 1.0)
	var vertices = PackedVector3Array()
	var uvs = PackedVector2Array()
	var indices = PackedInt32Array()
	for y in range(mesh_res):
		for x in range(mesh_res):
			var px = mini(x * sample_stride, cpx - 1)
			var py = mini(y * sample_stride, cpx - 1)
			var h = heights[py * cpx + px]
			vertices.append(Vector3(x * actual_vertex_spacing, h, y * actual_vertex_spacing))
			uvs.append(Vector2(float(x) * uv_scale_x, float(y) * uv_scale_y))
	# Stage 3: Vertex Y range
	var vy_min: float = 1e9
	var vy_max: float = -1e9
	for i in range(vertices.size()):
		vy_min = minf(vy_min, vertices[i].y)
		vy_max = maxf(vy_max, vertices[i].y)
	if do_height_diag and OS.is_debug_build():
		print("[HEIGHT] Vertex Y: min=%.1f max=%.1f range=%.1f (LOD=%d, vertices=%d)" % [vy_min, vy_max, vy_max - vy_min, lod, vertices.size()])
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
	var normals = compute_normals_lod_decimated(heights, actual_vertex_spacing, mesh_res, sample_stride, cpx)
	# Stage 4: Normal sample (center few) and normal variance (expected > 0.1 if not flat)
	var normal_variance: float = 0.0
	if do_height_diag and OS.is_debug_build() and normals.size() > 0:
		var mid: int = mesh_res * (mesh_res / 2) + (mesh_res / 2)
		var n0 = normals[mini(mid, normals.size() - 1)]
		var n1 = normals[mini(mid + 1, normals.size() - 1)]
		var n2 = normals[mini(mid + mesh_res, normals.size() - 1)]
		print("[HEIGHT] Normal sample: (%.3f, %.3f, %.3f) (%.3f, %.3f, %.3f) (%.3f, %.3f, %.3f)" % [n0.x, n0.y, n0.z, n1.x, n1.y, n1.z, n2.x, n2.y, n2.z])
		# Variance of (1 - n.y) over center 10x10: 0 = all up, >0.1 = sloped
		var sum_dev: float = 0.0
		var nn: int = 0
		for dy in range(-5, 6):
			for dx in range(-5, 6):
				var ix: int = (mesh_res / 2) + dx
				var iy: int = (mesh_res / 2) + dy
				if ix >= 0 and ix < mesh_res and iy >= 0 and iy < mesh_res:
					var idx: int = iy * mesh_res + ix
					if idx < normals.size():
						sum_dev += 1.0 - normals[idx].y
						nn += 1
		if nn > 0:
			normal_variance = sum_dev / float(nn)
		print("[VERIFY] Alps chunk lod0_x%d_y%d: vertex_Y range=%.1fm to %.1fm (expected ~500-4000m)" % [chunk_x, chunk_y, vy_min, vy_max])
		print("[VERIFY] Normal variance: %.3f (expected > 0.1, indicating non-flat normals)" % normal_variance)
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
		"uvs": uvs,
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
