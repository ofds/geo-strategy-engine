extends Node3D
## Hex selection as a physical 3D slice: extract terrain for selected hex, lift it, show cutout below.
## Independent of terrain LOD; uses ChunkManager.get_height_at() from height cache.
## Slice built with clipped rectangular grid (no polar grid) for correct hex shape.

const LIFT_TOP_M := 150.0
const LIFT_DURATION_S := 0.3
const WALL_DEPTH_M := 120.0  # 3x deeper for dramatic "chunk of earth" feel
const OSCILLATION_AMP_M := 3.0
const OSCILLATION_HZ := 1.0
# Rectangular grid clipped to pointy-top hex; radius from Constants.HEX_RADIUS_M
const GRID_STEP_M := 50.0
const BOUNDARY_STEP_M := 25.0
const HEIGHT_SAMPLE_WARN_RATIO := 0.2  # Warn if > 20% of samples return -1
# Small offset above terrain so slice doesn't z-fight with terrain at the border
const SLICE_TERRAIN_OFFSET_M := 0.5

var _chunk_manager: Node = null
var _slice_instance: MeshInstance3D = null
var _slice_mesh: ArrayMesh = null
var _center_x: float = 0.0
var _center_z: float = 0.0
var _lift_t: float = 1.0
var _lift_base_y: float = 0.0
var _selection_time: float = 0.0


func _ready() -> void:
	_chunk_manager = get_parent().get_node_or_null("ChunkManager")


func _process(delta: float) -> void:
	if _slice_instance == null:
		return
	_selection_time += delta
	if _lift_t < 1.0:
		var rate: float = delta / LIFT_DURATION_S
		_lift_t = minf(1.0, _lift_t + rate)
		var ease_out: float = 1.0 - (1.0 - _lift_t) * (1.0 - _lift_t)
		_slice_instance.position.y = ease_out * LIFT_TOP_M
	else:
		_slice_instance.position.y = LIFT_TOP_M + OSCILLATION_AMP_M * sin(TAU * OSCILLATION_HZ * _selection_time)
	var lift_factor: float = _lift_t if _lift_t >= 1.0 else (1.0 - (1.0 - _lift_t) * (1.0 - _lift_t))
	var mat: Material = _slice_instance.get_material_override()
	if mat is StandardMaterial3D:
		var smat: StandardMaterial3D = mat
		smat.emission_enabled = lift_factor > 0.02
		smat.emission = Color(0.12, 0.08, 0.02) * clampf(lift_factor * 1.2, 0.0, 1.0)
		smat.emission_energy_multiplier = 0.4


## True if local point (lx, lz) is inside or on the pointy-top hex (center at origin, radius = center to vertex).
## Use same boundary as _hex_row_intersection_x: flat edges at x = ±apothem, slanted caps at z = ±radius.
## (Using the SDF with radius instead of apothem incorrectly included points out to ~±667 at z=0, giving a rectangular bbox.)
func _is_inside_hex(lx: float, lz: float, radius: float) -> bool:
	var row: PackedFloat32Array = _hex_row_intersection_x(lz, radius)
	if row.size() < 2:
		return false
	return lx >= row[0] and lx <= row[1]


## Hex corners in local XZ (pointy-top: vertex at top, flat edges left/right). CCW from top.
func _hex_corners_local(radius: float) -> PackedVector2Array:
	var c: float = radius * 0.8660254  # cos(30°) = sqrt(3)/2
	var s: float = radius * 0.5       # sin(30°) = 0.5
	return PackedVector2Array([
		Vector2(0.0, radius),   # top
		Vector2(-c, s),         # upper-left
		Vector2(-c, -s),       # lower-left
		Vector2(0.0, -radius),  # bottom
		Vector2(c, -s),        # lower-right
		Vector2(c, s),         # upper-right
	])


## Intersection of line z = z_row with pointy-top hex boundary. Returns [left_x, right_x] or empty if no intersection.
func _hex_row_intersection_x(z_row: float, radius: float) -> PackedFloat32Array:
	var apothem: float = radius * 0.8660254  # sqrt(3)/2 * R = center to flat edge
	var abs_z: float = abs(z_row)
	if abs_z > radius:
		return PackedFloat32Array()
	var x_extent: float
	if abs_z <= apothem:
		x_extent = apothem
	else:
		x_extent = apothem * (radius - abs_z) / (radius - apothem)
	return PackedFloat32Array([-x_extent, x_extent])


## Sample height at world XZ; return 0.0 if get_height_at returns -1 (not in cache).
func _sample_height(world_x: float, world_z: float) -> float:
	var h: float = _chunk_manager.get_height_at(world_x, world_z) if _chunk_manager else -1.0
	return h if h >= 0.0 else 0.0


func _terrain_color(elev: float) -> Color:
	if elev < 5.0:
		return Color(0.15, 0.25, 0.45)
	if elev < 300.0:
		return Color(0.18, 0.32, 0.12)
	if elev < 800.0:
		return Color(0.25, 0.42, 0.15)
	if elev < 1500.0:
		return Color(0.35, 0.48, 0.18)
	if elev < 2200.0:
		return Color(0.45, 0.38, 0.30)
	if elev < 3000.0:
		return Color(0.62, 0.60, 0.58)
	return Color(0.92, 0.93, 0.95)


## Build ordered boundary vertices: walk 6 hex edges, step BOUNDARY_STEP_M, with terrain height.
## Returns array of Vector3 in local coords (x, height, z); also sets min_terrain_y.
func _build_boundary_vertices(radius: float, min_terrain_y: float) -> Array:
	var corners: PackedVector2Array = _hex_corners_local(radius)
	var boundary: Array = []  # Vector3 local (x, y, z)
	var failed_count: int = 0
	var total_count: int = 0
	for e in range(6):
		var a: Vector2 = corners[e]
		var b: Vector2 = corners[(e + 1) % 6]
		var seg_len: float = a.distance_to(b)
		var n_steps: int = maxi(1, int(ceil(seg_len / BOUNDARY_STEP_M)))
		for k in range(n_steps + 1):
			if k == 0 and e > 0:
				continue  # corner already added as end of previous edge
			if e == 5 and k == n_steps:
				continue  # don't duplicate c0 at end
			var t: float = float(k) / float(n_steps)
			var pt: Vector2 = a.lerp(b, t)
			var wx: float = _center_x + pt.x
			var wz: float = _center_z + pt.y
			total_count += 1
			var h: float = _chunk_manager.get_height_at(wx, wz) if _chunk_manager else -1.0
			if h < 0.0:
				h = 0.0
				failed_count += 1
			boundary.append(Vector3(pt.x, h, pt.y))
			if h < min_terrain_y:
				min_terrain_y = h
	if total_count > 0 and float(failed_count) / float(total_count) > HEIGHT_SAMPLE_WARN_RATIO:
		push_warning("[HexSelector] >20%% of boundary height samples failed (%d/%d). Slice may look flat." % [failed_count, total_count])
	return [boundary, min_terrain_y]


func _build_slice_mesh() -> ArrayMesh:
	var radius: float = Constants.HEX_RADIUS_M  # pointy-top: center to vertex
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var earth := Color(0.35, 0.25, 0.15)
	var slice_dump: bool = OS.get_environment("SLICE_DUMP") == "1"

	# --- [SLICE-DUMP] A) Selection center and radius (gate: SLICE_DUMP=1) ---
	if slice_dump:
		print("[SLICE-DUMP] Selected hex center (world XZ): (%.3f, %.3f)" % [_center_x, _center_z])
		print("[SLICE-DUMP] Hex radius used: %.3f" % radius)

	# --- [SLICE-DUMP] B) Hex corners (actual from _hex_corners_local) vs expected (terrain shader math) ---
	var actual_corners: PackedVector2Array = _hex_corners_local(radius)
	var hex_size: float = Constants.HEX_RADIUS_M
	var c: float = hex_size * 0.8660254
	var s: float = hex_size * 0.5
	var expected_corners: Array = [
		Vector2(0.0, hex_size),
		Vector2(-c, s),
		Vector2(-c, -s),
		Vector2(0.0, -hex_size),
		Vector2(c, -s),
		Vector2(c, s),
	]
	if slice_dump:
		for i in range(6):
			var ac: Vector2 = actual_corners[i]
			var ex: Vector2 = expected_corners[i]
			var wx: float = _center_x + ac.x
			var wz: float = _center_z + ac.y
			print("[SLICE-DUMP] Corner %d (local): (%.3f, %.3f) -> (world): (%.3f, %.3f)  expected_local: (%.3f, %.3f)" % [i, ac.x, ac.y, wx, wz, ex.x, ex.y])

	# --- Boundary vertices (ordered, for walls and rim) ---
	var min_terrain_y: float = 0.0
	var boundary_result: Array = _build_boundary_vertices(radius, 99999.0)
	var boundary_verts: Array = boundary_result[0]
	min_terrain_y = boundary_result[1]
	if min_terrain_y > 99998.0:
		min_terrain_y = 0.0

	# --- [SLICE-DUMP] D) Boundary vertices (first/last few) ---
	var n_boundary: int = boundary_verts.size()
	if slice_dump:
		print("[SLICE-DUMP] Boundary vertex count: %d" % n_boundary)
		for idx in range(mini(5, n_boundary)):
			var bv: Vector3 = boundary_verts[idx]
			print("[SLICE-DUMP] Boundary[%d]: Vector3(%.3f, %.3f, %.3f)" % [idx, bv.x, bv.y, bv.z])
		if n_boundary > 10:
			print("[SLICE-DUMP] ... (omitted %d) ..." % (n_boundary - 10))
			for idx in range(n_boundary - 5, n_boundary):
				var bv: Vector3 = boundary_verts[idx]
				print("[SLICE-DUMP] Boundary[%d]: Vector3(%.3f, %.3f, %.3f)" % [idx, bv.x, bv.y, bv.z])
		elif n_boundary > 5:
			for idx in range(5, n_boundary):
				var bv: Vector3 = boundary_verts[idx]
				print("[SLICE-DUMP] Boundary[%d]: Vector3(%.3f, %.3f, %.3f)" % [idx, bv.x, bv.y, bv.z])

	# --- Rectangular grid (snap outer points to hex boundary) ---
	var step: float = GRID_STEP_M
	var nx: int = maxi(2, int(ceil(2.0 * radius / step)))
	var nz: int = maxi(2, int(ceil(2.0 * radius / step)))
	# grid_vertex_index[i][j] = vertex index in arrays, or -1
	var grid_vertex_index: Array = []
	for j in range(nz):
		grid_vertex_index.append([])
		for i in range(nx):
			grid_vertex_index[j].append(-1)

	# Fallback height when get_height_at returns -1 (chunk not in cache)
	var height_fallback: float = 0.0
	for bv in boundary_verts:
		var yh: float = (bv as Vector3).y
		if yh > 0.0:
			height_fallback = yh
			break
	if height_fallback <= 0.0:
		height_fallback = min_terrain_y if min_terrain_y > 0.0 else 0.0

	var apothem: float = radius * 0.8660254
	var sample_fail_count: int = 0
	var sample_total: int = 0
	var dump_epsilon: float = 15.0
	for j in range(nz):
		var z_local: float = -radius + (float(j) + 0.5) * step
		var row_intersection: PackedFloat32Array = _hex_row_intersection_x(z_local, radius)
		var left_x: float = -radius
		var right_x: float = radius
		if row_intersection.size() >= 2:
			left_x = row_intersection[0]
			right_x = row_intersection[1]
		# First pass: which columns in this row are inside the hex?
		var valid_i: Array = []
		for i in range(nx):
			var x_center: float = -radius + (float(i) + 0.5) * step
			if _is_inside_hex(x_center, z_local, radius):
				valid_i.append(i)
		# --- [SLICE-DUMP] E) Grid clipping samples: z=0, z near ±radius, z near ±apothem ---
		if slice_dump:
			var abs_z: float = abs(z_local)
			var near_mid: bool = abs_z < dump_epsilon
			var near_radius: bool = abs(abs_z - radius) < dump_epsilon
			var near_apothem: bool = abs(abs_z - apothem) < dump_epsilon
			if near_mid or near_radius or near_apothem:
				var expected_x: float
				if abs_z > radius:
					expected_x = 0.0
				elif abs_z <= apothem:
					expected_x = apothem
				else:
					expected_x = apothem * (radius - abs_z) / (radius - apothem)
				print("[SLICE-DUMP] Grid row z=%.1f: intersection_x range = [%.1f, %.1f] (expected for hex: [%.1f, %.1f])" % [z_local, left_x, right_x, -expected_x, expected_x])
				var sample_lx: float = -radius + (float(nx) * 0.5 + 0.5) * step
				var inside: bool = _is_inside_hex(sample_lx, z_local, radius)
				print("[SLICE-DUMP] Grid point (lx, lz) = (%.1f, %.1f): is_inside = %s" % [sample_lx, z_local, inside])
		if valid_i.is_empty():
			continue
		var i_min: int = valid_i[0]
		var i_max: int = valid_i[0]
		for i in valid_i:
			if i < i_min:
				i_min = i
			if i > i_max:
				i_max = i
		for i in valid_i:
			var x_center: float = -radius + (float(i) + 0.5) * step
			var x_snap: float = left_x if i == i_min else (right_x if i == i_max else x_center)
			var wx: float = _center_x + x_snap
			var wz: float = _center_z + z_local
			sample_total += 1
			var h: float = _chunk_manager.get_height_at(wx, wz) if _chunk_manager else -1.0
			if h < 0.0:
				h = height_fallback
				sample_fail_count += 1
			var idx: int = vertices.size()
			vertices.append(Vector3(x_snap, h + SLICE_TERRAIN_OFFSET_M, z_local))
			colors.append(_terrain_color(h))
			normals.append(Vector3.UP)
			grid_vertex_index[j][i] = idx

	if sample_total > 0 and float(sample_fail_count) / float(sample_total) > HEIGHT_SAMPLE_WARN_RATIO:
		push_warning("[HexSelector] >20%% of grid height samples failed (%d/%d). Slice may look flat." % [sample_fail_count, sample_total])

	# --- Triangulate top surface (regular grid, CCW from above) ---
	for j in range(nz - 1):
		for i in range(nx - 1):
			var v00: int = grid_vertex_index[j][i]
			var v10: int = grid_vertex_index[j][i + 1]
			var v01: int = grid_vertex_index[j + 1][i]
			var v11: int = grid_vertex_index[j + 1][i + 1]
			if v00 < 0 or v10 < 0 or v01 < 0 or v11 < 0:
				continue
			# CCW when viewed from above (+Y): (00, 10, 01) and (10, 11, 01)
			indices.append_array([v00, v10, v01])
			indices.append_array([v10, v11, v01])

	# --- Smooth normals for top surface ---
	_compute_grid_normals(vertices, normals, indices, vertices.size())

	var top_vertex_count: int = vertices.size()

	# --- Side walls: consecutive boundary vertices, quad each (top L/R, bottom L/R). Bottom follows terrain (each vertex drops WALL_DEPTH_M from its surface height). ---
	for k in range(boundary_verts.size()):
		var next_k: int = (k + 1) % boundary_verts.size()
		var pt: Vector3 = boundary_verts[k]
		var pn: Vector3 = boundary_verts[next_k]
		var pt_bottom_y: float = pt.y - WALL_DEPTH_M
		var pn_bottom_y: float = pn.y - WALL_DEPTH_M
		var outwards: Vector3 = Vector3(pt.x, 0.0, pt.z)
		if outwards.length_squared() > 1e-6:
			outwards = outwards.normalized()
		else:
			outwards = Vector3(1.0, 0.0, 0.0)
		var out_n: Vector3 = Vector3(pn.x, 0.0, pn.z)
		if out_n.length_squared() > 1e-6:
			out_n = out_n.normalized()
		else:
			out_n = Vector3(1.0, 0.0, 0.0)
		var v0_top: int = vertices.size()
		vertices.append(Vector3(pt.x, pt.y + SLICE_TERRAIN_OFFSET_M, pt.z))
		colors.append(earth)
		normals.append(outwards)
		vertices.append(Vector3(pt.x, pt_bottom_y, pt.z))
		colors.append(earth)
		normals.append(outwards)
		vertices.append(Vector3(pn.x, pn.y + SLICE_TERRAIN_OFFSET_M, pn.z))
		colors.append(earth)
		normals.append(out_n)
		vertices.append(Vector3(pn.x, pn_bottom_y, pn.z))
		colors.append(earth)
		normals.append(out_n)
		# Quad: top-left, bottom-left, bottom-right, top-right. CCW from outside (normal points out): two tris
		indices.append_array([v0_top, v0_top + 1, v0_top + 3, v0_top, v0_top + 3, v0_top + 2])

	# --- [SLICE-DUMP] F) Final mesh stats ---
	var wall_vertex_count: int = vertices.size() - top_vertex_count
	if slice_dump:
		print("[SLICE-DUMP] Total top vertices: %d" % top_vertex_count)
		print("[SLICE-DUMP] Total wall vertices: %d" % wall_vertex_count)
		var vmin := Vector3(1e30, 1e30, 1e30)
		var vmax := Vector3(-1e30, -1e30, -1e30)
		for v in vertices:
			vmin.x = minf(vmin.x, v.x)
			vmin.y = minf(vmin.y, v.y)
			vmin.z = minf(vmin.z, v.z)
			vmax.x = maxf(vmax.x, v.x)
			vmax.y = maxf(vmax.y, v.y)
			vmax.z = maxf(vmax.z, v.z)
		print("[SLICE-DUMP] Mesh bounding box: min(%.3f, %.3f, %.3f) to max(%.3f, %.3f, %.3f)" % [vmin.x, vmin.y, vmin.z, vmax.x, vmax.y, vmax.z])
		print("[SLICE-DUMP] Slice node position (world offset): (%.3f, %.3f, %.3f)" % [_center_x, 0.0, _center_z])

	# --- Single surface ---
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _compute_grid_normals(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, top_count: int) -> void:
	var accum: PackedVector3Array = []
	accum.resize(vertices.size())
	for i in range(accum.size()):
		accum[i] = Vector3.ZERO
	var i: int = 0
	while i < indices.size():
		var i0: int = indices[i]
		var i1: int = indices[i + 1]
		var i2: int = indices[i + 2]
		if i0 < top_count and i1 < top_count and i2 < top_count:
			var n: Vector3 = (vertices[i1] - vertices[i0]).cross(vertices[i2] - vertices[i0])
			accum[i0] += n
			accum[i1] += n
			accum[i2] += n
		i += 3
	for idx in range(top_count):
		if accum[idx].length_squared() > 1e-10:
			normals[idx] = accum[idx].normalized()


# Rim is now drawn in screen-space shader (hex_overlay_screen.glsl) - thick, visible, scales with altitude.
# func _build_golden_rim_mesh() -> ArrayMesh:
# 	var hex_size: float = Constants.HEX_SIZE_M
# 	var corners: PackedVector2Array = _hex_corners_local(hex_size)
# 	var vertices := PackedVector3Array()
# 	for e in range(6):
# 		var a: Vector2 = corners[e]
# 		var wx0: float = _center_x + a.x
# 		var wz0: float = _center_z + a.y
# 		var h: float = _chunk_manager.get_height_at(wx0, wz0) if _chunk_manager else 0.0
# 		if h < 0.0:
# 			h = 0.0
# 		vertices.append(Vector3(a.x, h + SLICE_TERRAIN_OFFSET_M, a.y))
# 	var mat := StandardMaterial3D.new()
# 	mat.albedo_color = Color(0.9, 0.75, 0.3)
# 	mat.emission_enabled = true
# 	mat.emission = Color(0.9, 0.75, 0.3)
# 	mat.emission_energy_multiplier = 0.8
# 	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
# 	var mesh := ArrayMesh.new()
# 	var indices := PackedInt32Array()
# 	for i in range(6):
# 		indices.append(i)
# 	indices.append(0)
# 	var arr: Array = []
# 	arr.resize(Mesh.ARRAY_MAX)
# 	arr[Mesh.ARRAY_VERTEX] = vertices
# 	arr[Mesh.ARRAY_INDEX] = indices
# 	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arr)
# 	mesh.surface_set_material(0, mat)
# 	return mesh


func set_selected_hex(center_xz: Vector2) -> void:
	clear_selection()
	_center_x = center_xz.x
	_center_z = center_xz.y
	if not _chunk_manager or not _chunk_manager.has_method("get_height_at"):
		return
	var h_center: float = _chunk_manager.get_height_at(_center_x, _center_z)
	if h_center < 0.0:
		return
	_lift_base_y = h_center
	_lift_t = 0.0
	_selection_time = 0.0

	_slice_mesh = _build_slice_mesh()
	if _slice_mesh.get_surface_count() == 0:
		return

	_slice_instance = MeshInstance3D.new()
	_slice_instance.mesh = _slice_mesh
	_slice_instance.position = Vector3(_center_x, 0.0, _center_z)
	var mat := StandardMaterial3D.new()
	# Godot 4: use vertex COLOR as albedo so slice top shows terrain colors, walls show earth
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_slice_instance.material_override = mat
	add_child(_slice_instance)

	# Quick diagnostic: print hex_selector positioning (coordinate space mismatch check)
	if OS.is_debug_build():
		var world_center: Vector3 = Vector3(_center_x, 0.0, _center_z)
		print("\n=== HEX_SELECTOR DEBUG ===")
		print("Received world_center: ", world_center)
		if _slice_instance != null:
			print("hex_mesh.global_position: ", _slice_instance.global_position)
			print("hex_mesh.position (local): ", _slice_instance.position)
			var parent_node: Node = _slice_instance.get_parent()
			print("hex_mesh parent: ", parent_node.name)
			print("hex_mesh parent global_position: ", parent_node.global_position)
		print("==========================\n")

	# Rim is now drawn in screen-space shader (hex_overlay_screen.glsl)
	# var rim_mesh: ArrayMesh = _build_golden_rim_mesh()
	# if rim_mesh.get_surface_count() > 0:
	# 	var rim_instance := MeshInstance3D.new()
	# 	rim_instance.mesh = rim_mesh
	# 	_slice_instance.add_child(rim_instance)


func clear_selection() -> void:
	if _slice_instance:
		_slice_instance.queue_free()
		_slice_instance = null
	_slice_mesh = null


func has_slice() -> bool:
	return _slice_instance != null
