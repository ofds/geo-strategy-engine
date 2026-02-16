extends Node3D
## World-space hex grid: lines at terrain height. No depth buffer; grid locks to terrain.
## Replaces screen-space compositor grid when depth is unavailable (e.g. Godot 4.5).

const SQRT3 := 1.73205080757
## Decal footprint on ground (X and Z). Y (projection depth) set separately in _ready. Do not rotate decal.
const DECAL_WORLD_SIZE := 20000.0

@export var hex_size: float = 1000.0
var _show_grid_backing: bool = true
@export var show_grid: bool = true:
	get:
		return _show_grid_backing
	set(value):
		_show_grid_backing = value
		visible = _show_grid_backing
		if _grid_decal:
			_grid_decal.visible = _show_grid_backing
@export var grid_radius_m: float = 50000.0  # 50km radius (covers continental zoom)
const REBUILD_REGION_M: float = 10000.0  # Only rebuild when camera moves > 10km (static grid)
const MAX_VISIBLE_DIST_M: float = 20000.0  # Only draw hexes within 20km of camera (cull)

var center_world_xz: Vector2 = Vector2.ZERO
var hovered_hex_center: Vector2 = Vector2(-999999.0, -999999.0)
var selected_hex_center: Vector2 = Vector2(-999999.0, -999999.0)

var _chunk_manager: Node = null
var _grid_decal: Decal = null
var _last_rebuild_center: Vector2 = Vector2.ZERO  # ZERO = not built yet (kept for future hex texture region)


func _ready() -> void:
	_chunk_manager = get_parent().get_node_or_null("ChunkManager")
	if _chunk_manager == null:
		_chunk_manager = get_tree().get_first_node_in_group("chunk_manager")
	hex_size = Constants.HEX_SIZE_M

	# Create Decal for grid rendering (replaces MeshInstance3D line mesh)
	_grid_decal = Decal.new()
	add_child(_grid_decal)

	# --- DECAL ORIENTATION (do not change; Godot projects along local -Y by default) ---
	# - rotation_degrees must stay ZERO so the texture projects straight down onto terrain.
	# - size: AABB from -size/2 to +size/2. X and Z = horizontal footprint, Y = projection depth.
	# - If you rotate the decal (e.g. -90 on X), only one texture axis appears (looks like a line).
	_grid_decal.position = Vector3(0, 5000, 0)
	_grid_decal.rotation_degrees = Vector3.ZERO
	_grid_decal.size = Vector3(DECAL_WORLD_SIZE, 10000, DECAL_WORLD_SIZE)  # Y = projection depth

	# Hex grid texture (world-space aligned so grid stays fixed when orbiting)
	var texture := _create_hex_grid_texture()
	_grid_decal.texture_albedo = texture

	# Visual settings
	_grid_decal.modulate = Color(1, 1, 1, 0.85)  # strong visibility
	_grid_decal.cull_mask = 1  # Render on layer 1 (terrain layer)
	_grid_decal.distance_fade_enabled = false  # don't fade grid when camera is far

	# Visibility controlled by _show_grid_backing
	_grid_decal.visible = _show_grid_backing

	print("[HexGridMesh] Decal initialized")


func _process(_delta: float) -> void:
	if not _grid_decal:
		return
	# Keep decal in world space: center on look-at XZ, fixed height, project straight down (default -Y)
	_grid_decal.global_position = Vector3(center_world_xz.x, 5000.0, center_world_xz.y)
	_grid_decal.global_rotation_degrees = Vector3.ZERO
	_grid_decal.visible = _show_grid_backing

	# Fixed size: decal always covers same world area so grid scale stays consistent when zooming.
	_grid_decal.size = Vector3(DECAL_WORLD_SIZE, 10000.0, DECAL_WORLD_SIZE)

	# Optional: altitude-based opacity fade at very high altitude (> 20 km)
	var cam := get_viewport().get_camera_3d()
	if cam:
		var altitude := cam.global_position.y
		var fade := clampf(1.0 - (altitude - 20000.0) / 30000.0, 0.3, 1.0)
		_grid_decal.modulate = Color(1.0, 1.0, 1.0, fade * 0.6)
	else:
		_grid_decal.modulate = Color(1.0, 1.0, 1.0, 0.6)


func set_center_world_xz(world_x: float, world_z: float) -> void:
	center_world_xz = Vector2(world_x, world_z)
	# Rebuild disabled: using Decal rendering (kept for future hex texture region logic)
	var needs_rebuild := false
	if _last_rebuild_center == Vector2.ZERO:
		needs_rebuild = true
	elif center_world_xz.distance_to(_last_rebuild_center) > REBUILD_REGION_M:
		needs_rebuild = true
	if needs_rebuild:
		_last_rebuild_center = center_world_xz
		_build_mesh(world_x, world_z)


func _hex_corners_local() -> PackedVector2Array:
	var corners: PackedVector2Array
	var hs := hex_size * 0.5
	var q := hex_size * SQRT3 * 0.25
	corners.append(Vector2(hs, 0.0))
	corners.append(Vector2(hex_size * 0.25, q))
	corners.append(Vector2(-hex_size * 0.25, q))
	corners.append(Vector2(-hs, 0.0))
	corners.append(Vector2(-hex_size * 0.25, -q))
	corners.append(Vector2(hex_size * 0.25, -q))
	return corners


func _axial_to_world(q: float, r: float) -> Vector2:
	var size_ax := hex_size / SQRT3
	var cx := size_ax * (1.5 * q)
	var cz := size_ax * (SQRT3 * 0.5 * q + SQRT3 * r)
	return Vector2(cx, cz)


func _world_to_axial(world_x: float, world_z: float) -> Vector2:
	var size_ax := hex_size / SQRT3
	var q: float = (2.0 / 3.0 * world_x) / size_ax
	var r: float = (-1.0 / 3.0 * world_x + SQRT3 / 3.0 * world_z) / size_ax
	return Vector2(q, r)


func _axial_round(axial: Vector2) -> Vector2:
	var rx: float = round(axial.x)
	var ry: float = round(axial.y)
	var rz: float = -rx - ry
	var xd: float = abs(rx - axial.x)
	var yd: float = abs(ry - axial.y)
	var zd: float = abs(rz - (-axial.x - axial.y))
	if xd > yd and xd > zd:
		rx = -ry - rz
	elif yd > zd:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2(rx, ry)


func _build_mesh(_center_x: float, _center_z: float) -> void:
	# Disabled: using Decal rendering now (mesh building was line-based; decal uses texture)
	print("[HexGridMesh] _rebuild_grid() called but disabled (using Decal)")


func _create_hex_grid_texture() -> ImageTexture:
	"""Procedural hex grid for decal: same hex math as world, so grid locks to terrain."""
	var tex_size := 1024
	var img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line_width := 2
	# World range covered by decal: -DECAL_WORLD_SIZE/2 to +DECAL_WORLD_SIZE/2 on X and Z
	var half_world := DECAL_WORLD_SIZE * 0.5
	var corners := _hex_corners_local()
	var radius_hex := int(half_world / (hex_size / SQRT3)) + 2
	for q in range(-radius_hex, radius_hex + 1):
		for r in range(-radius_hex, radius_hex + 1):
			var w := _axial_to_world(float(q), float(r))
			if abs(w.x) > half_world or abs(w.y) > half_world:
				continue
			for e in 6:
				var p0 := corners[e]
				var p1 := corners[(e + 1) % 6]
				var x0 := w.x + p0.x
				var z0 := w.y + p0.y
				var x1 := w.x + p1.x
				var z1 := w.y + p1.y
				# World to texture: (0,0) at (-half_world, -half_world), (1,1) at (+half_world, +half_world)
				var u0 := (x0 + half_world) / DECAL_WORLD_SIZE
				var v0 := (z0 + half_world) / DECAL_WORLD_SIZE
				var u1 := (x1 + half_world) / DECAL_WORLD_SIZE
				var v1 := (z1 + half_world) / DECAL_WORLD_SIZE
				# Gold to match selection rim (visual unity with compositor)
				var grid_color := Color(1.0, 0.8, 0.3, 0.6)
				_draw_line(img, u0, v0, u1, v1, tex_size, line_width, grid_color)
	var texture := ImageTexture.create_from_image(img)
	print("[HexGridMesh] Hex grid texture created (%d×%d)" % [tex_size, tex_size])
	return texture

func _draw_line(img: Image, u0: float, v0: float, u1: float, v1: float, tex_size: int, line_width: int, col: Color) -> void:
	var span: float = max(abs(u1 - u0), abs(v1 - v0))
	var steps: int = max(1, int(span * tex_size))
	var hw: int = line_width >> 1
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var u: float = lerp(u0, u1, t)
		var v: float = lerp(v0, v1, t)
		var px: int = clamp(int(u * tex_size), 0, tex_size - 1)
		var py: int = clamp(int(v * tex_size), 0, tex_size - 1)
		for dy in range(-hw, hw + 1):
			for dx in range(-hw, hw + 1):
				var nx: int = clamp(px + dx, 0, tex_size - 1)
				var ny: int = clamp(py + dy, 0, tex_size - 1)
				img.set_pixel(nx, ny, col)


func _get_shader_code() -> String:
	return """
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, depth_test_enabled;

uniform vec3 hovered_hex_center;
uniform vec3 selected_hex_center;
uniform bool has_selection;
uniform bool has_hover;

void vertex() {
	// Pass through; UV2 is hex center XZ
}

void fragment() {
	vec2 hex_xz = UV2.xy;
	vec2 hover_xz = hovered_hex_center.xz;
	vec2 sel_xz = selected_hex_center.xz;
	float eps = 600.0; // same hex (center within half hex size)
	bool is_selected = has_selection && distance(hex_xz, sel_xz) < eps;
	bool is_hovered = has_hover && distance(hex_xz, hover_xz) < eps && !is_selected;
	if (is_selected) {
		ALBEDO = vec3(0.9, 0.75, 0.3);
		ALPHA = 1.0;
	} else if (is_hovered) {
		ALBEDO = vec3(1.0, 1.0, 1.0);
		ALPHA = 1.0;
	} else {
		ALBEDO = vec3(0.0, 0.0, 0.0);
		ALPHA = 0.7;
	}
}
"""
