extends Camera3D
## Basic Camera Controller for Terrain Viewing
## Features: WASD pan, scroll zoom, middle mouse orbit
## Stays above terrain at all times

const HexOverlayCompositorScript = preload("res://rendering/hex_overlay_compositor.gd")

# Camera state
var target_position: Vector3 = Vector3.ZERO # Point camera looks at
var orbit_distance: float = 10000.0 # Distance from target (altitude)
var target_orbit_distance: float = 10000.0 # Target distance for smooth zoom
var orbit_pitch: float = 60.0 # Angle from horizontal (degrees)
var orbit_yaw: float = 0.0 # Rotation around vertical axis (degrees)


## Get the ground point the camera is looking at (for chunk streaming)
func get_target_ground_position() -> Vector3:
	return Vector3(target_position.x, 0, target_position.z)

# Control parameters
var pan_speed: float = 200.0 # Increased from 50 - faster pan
var zoom_speed: float = 0.2 # Increased from 0.1 - faster zoom
var zoom_smoothing: float = 8.0 # Higher = snappier, lower = smoother
var orbit_sensitivity: float = 0.3 # Increased from 0.2 - more responsive orbit

# Debug
var debug_collision: bool = false # Set to true to see collision debug info
var frame_count: int = 0
# Height pipeline diagnostic: when true, print [SHADER] altitude/overview_blend once per second (enable with ChunkManager DEBUG_DIAGNOSTIC for full pipeline)
@export var DEBUG_DIAGNOSTIC: bool = false
var _shader_diag_timer: float = 0.0

# Speed boost
var speed_boost_multiplier: float = 10.0 # 10x speed when Space is held
var is_speed_boost_active: bool = false

# Mouse state
var is_orbiting: bool = false
var last_mouse_pos: Vector2 = Vector2.ZERO
# Throttle hover raycast to every 3rd frame to reduce per-frame cost
var _hover_raycast_frame: int = 0

# Terrain chunk reference (for initial positioning)
var chunk_size_m: float = 15360.0 # 512 px × 30 m = 15.36 km
# Region bounds (for edge fade in shader)
var _terrain_center_xz: Vector2 = Vector2.ZERO
var _terrain_radius_m: float = 2000000.0 # half-diagonal of region

# Terrain height reference
var terrain_min_elevation: float = 0.0
var terrain_max_elevation: float = 5000.0
var min_camera_clearance: float = 100.0 # Stay at least 100m above terrain


func _load_terrain_metadata() -> Dictionary:
	var path = "res://data/terrain/terrain_metadata.json"
	if not FileAccess.file_exists(path):
		return {}
	var f = FileAccess.open(path, FileAccess.READ)
	if not f:
		return {}
	var json = JSON.new()
	if json.parse(f.get_as_text()) != OK:
		f.close()
		return {}
	f.close()
	return json.data


func _ready() -> void:
	# Continental scale: 2000 km far plane, fog extended in shader
	far = 2000000.0 # 2000 km for full Europe view
	near = 10.0 # Prevent clipping when very close to terrain
	
	# Center camera on terrain from metadata (Europe ~50°N, 15°E; Alps fallback)
	var meta = _load_terrain_metadata()
	var res_m: float = meta.get("resolution_m", 90.0)
	chunk_size_m = 512.0 * res_m
	
	var grid_center_world_x: float = 0.0
	var grid_center_world_z: float = 0.0
	if meta.has("bounding_box") and meta.has("master_heightmap_width") and meta.has("master_heightmap_height"):
		var bb = meta.bounding_box
		var lat_min: float = bb.lat_min
		var lat_max: float = bb.lat_max
		var lon_min: float = bb.lon_min
		var lon_max: float = bb.lon_max
		var mw: int = meta.master_heightmap_width
		var mh: int = meta.master_heightmap_height
		var width_m: float = float(mw) * res_m
		var height_m: float = float(mh) * res_m
		var center_lat: float = (lat_min + lat_max) * 0.5
		var center_lon: float = (lon_min + lon_max) * 0.5
		# World X = east, Z = south; origin at NW corner
		grid_center_world_x = (center_lon - lon_min) / (lon_max - lon_min) * width_m
		grid_center_world_z = (lat_max - center_lat) / (lat_max - lat_min) * height_m
		_terrain_center_xz = Vector2(grid_center_world_x, grid_center_world_z)
		_terrain_radius_m = sqrt((width_m * 0.5) * (width_m * 0.5) + (height_m * 0.5) * (height_m * 0.5))
	else:
		# Fallback: Alps-style center
		grid_center_world_x = 15.5 * chunk_size_m
		grid_center_world_z = 8.5 * chunk_size_m
		_terrain_center_xz = Vector2(grid_center_world_x, grid_center_world_z)
		_terrain_radius_m = 500000.0 # fallback for small region
	
	target_position = Vector3(grid_center_world_x, 1000.0, grid_center_world_z)
	# Start altitude: ~150 km for Europe so a large area is visible
	orbit_distance = 150000.0
	target_orbit_distance = 150000.0
	orbit_pitch = 70.0
	orbit_yaw = 45.0
	
	_update_camera_transform()
	
	if OS.is_debug_build():
		print("\n=== Camera initialized for multi-LOD view ===")
		print("Target: %s" % target_position)
		print("Distance: %.1f m (%.1f km)" % [orbit_distance, orbit_distance / 1000.0])
		print("Camera far plane: %.1f km" % (far / 1000.0))


func _input(event: InputEvent) -> void:
	# Middle mouse button - orbit
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				is_orbiting = true
				last_mouse_pos = event.position
			else:
				is_orbiting = false
		
		# Scroll wheel - zoom
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1)
			
		# Mouse Click - Hex Selection
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_handle_hex_selection_click(event.position)
	
	# Mouse motion - orbit when middle button held
	elif event is InputEventMouseMotion:
		if is_orbiting:
			var delta = event.position - last_mouse_pos
			last_mouse_pos = event.position
			
			orbit_yaw -= delta.x * orbit_sensitivity
			orbit_pitch -= delta.y * orbit_sensitivity
			
			# Clamp pitch to prevent flipping
			orbit_pitch = clamp(orbit_pitch, 10.0, 89.0)
			
			_update_camera_transform()
func _handle_hex_selection_click(screen_pos: Vector2) -> void:
	var space_state = get_world_3d().direct_space_state
	var ray_origin = project_ray_origin(screen_pos)
	var ray_end = ray_origin + project_ray_normal(screen_pos) * 500000.0

	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collision_mask = 1
	var result = space_state.intersect_ray(query)

	if result:
		var hit_pos = result.position

		# Only allow selection on LOD 0–2 terrain; LOD 3+ is too coarse for hex visual
		var chunk_mgr = get_parent().get_node_or_null("ChunkManager")
		if chunk_mgr and chunk_mgr.has_method("get_lod_at_world_position"):
			var hit_lod = chunk_mgr.get_lod_at_world_position(hit_pos)
			if hit_lod >= 3:
				_show_zoom_in_to_select_message()
				return
			_clear_zoom_in_message()

		var width = Constants.HEX_SIZE_M
		var hex_size = width / sqrt(3.0)

		var q = (2.0 / 3.0 * hit_pos.x) / hex_size
		var r = (-1.0 / 3.0 * hit_pos.x + sqrt(3.0) / 3.0 * hit_pos.z) / hex_size

		var hex_axial = _axial_round(Vector2(q, r))
		var hex_q = int(hex_axial.x)
		var hex_r = int(hex_axial.y)

		var center_x = hex_size * (3.0 / 2.0 * hex_q)
		var center_z = hex_size * (sqrt(3.0) / 2.0 * hex_q + sqrt(3.0) * hex_r)
		var center = Vector2(center_x, center_z)

		var hex_selector = get_parent().get_node_or_null("HexSelector")
		if _selected_hex_center.distance_to(center) < 1.0:
			_selected_hex_center = Vector2(999999, 999999)
			if hex_selector and hex_selector.has_method("clear_selection"):
				hex_selector.clear_selection()
		else:
			_selected_hex_center = center
			_selection_time = 0.0
			if hex_selector and hex_selector.has_method("set_selected_hex"):
				hex_selector.set_selected_hex(center)
	else:
		_selected_hex_center = Vector2(999999, 999999)
		_clear_zoom_in_message()
		var hex_sel = get_parent().get_node_or_null("HexSelector")
		if hex_sel and hex_sel.has_method("clear_selection"):
			hex_sel.clear_selection()

	_update_hex_selection_uniform()


# DEBUG VISUALS
var debug_hit_sphere: MeshInstance3D = null
var debug_center_sphere: MeshInstance3D = null

func _update_debug_visuals(hit_pos: Vector3, center_pos: Vector3) -> void:
	if not debug_hit_sphere:
		debug_hit_sphere = MeshInstance3D.new()
		var sphere = SphereMesh.new()
		sphere.radius = 20.0
		sphere.height = 40.0
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(1, 0, 0) # Red = Hit
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere.material = mat
		debug_hit_sphere.mesh = sphere
		get_tree().root.add_child(debug_hit_sphere)
		
	if not debug_center_sphere:
		debug_center_sphere = MeshInstance3D.new()
		var sphere = SphereMesh.new()
		sphere.radius = 30.0
		sphere.height = 60.0
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0, 1, 0) # Green = Center
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere.material = mat
		debug_center_sphere.mesh = sphere
		get_tree().root.add_child(debug_center_sphere)

	debug_hit_sphere.global_position = hit_pos
	debug_center_sphere.global_position = center_pos
	debug_hit_sphere.visible = true
	debug_center_sphere.visible = true


var _selected_hex_center: Vector2 = Vector2(999999, 999999)
var _selection_time: float = 0.0 # Seconds since selection; animates lift/border/tint

# Screen-space hex overlay (CompositorEffect); set in _ensure_hex_compositor() from world environment compositor
var _hex_compositor: CompositorEffect = null
var _hovered_hex_center: Vector2 = Vector2(-999999.0, -999999.0)

func _update_hex_selection_uniform() -> void:
	if _hex_compositor:
		_hex_compositor.selected_hex_center = _selected_hex_center
		_hex_compositor.selection_time = _selection_time


func _process(delta: float) -> void:
	# Check for speed boost (Space key)
	is_speed_boost_active = Input.is_key_pressed(KEY_SPACE)

	# Animate selection (lift/border/tint fade-in)
	if _selected_hex_center.x < 900000.0: # Has selection (not sentinel)
		_selection_time += delta

	if _zoom_in_label_timer > 0.0:
		_zoom_in_label_timer -= delta
		if _zoom_in_label_timer <= 0.0 and _zoom_in_label:
			_zoom_in_label.visible = false
	
	# Stage 5 diagnostic: altitude and overview_blend once per second (DEBUG_DIAGNOSTIC)
	if DEBUG_DIAGNOSTIC and OS.is_debug_build():
		_shader_diag_timer += delta
		if _shader_diag_timer >= 1.0:
			_shader_diag_timer = 0.0
			var alt: float = orbit_distance if orbit_distance > 0.0 else position.y
			var t: float = clampf((alt - 15000.0) / (180000.0 - 15000.0), 0.0, 1.0)
			var overview_blend: float = t * t * (3.0 - 2.0 * t)
			print("[SHADER] altitude=%.1f overview_blend=%.3f" % [alt, overview_blend])
			if alt < 15000.0 and overview_blend < 0.01:
				print("[VERIFY] At 5km altitude: overview_blend=0.0, mesh color active")

	# Smoothly interpolate orbit_distance toward target
	orbit_distance = lerp(orbit_distance, target_orbit_distance, zoom_smoothing * delta)
	
	# Dynamic far plane: 10,000 km at high altitude to avoid z-fighting; 2,000 km at lower altitude
	if orbit_distance > 1000000.0:
		far = 10000000.0
	else:
		far = 2000000.0
	
	# WASD panning
	var pan_input = Vector2.ZERO
	
	if Input.is_key_pressed(KEY_W):
		pan_input.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		pan_input.y += 1.0
	if Input.is_key_pressed(KEY_A):
		pan_input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		pan_input.x += 1.0
	
	if pan_input.length() > 0:
		_pan(pan_input.normalized(), delta)
	else:
		# Update camera even when not panning (for smooth zoom)
		_update_camera_transform()


func _pan(direction: Vector2, delta: float) -> void:
	"""Pan the camera target in screen-space directions."""
	
	# Speed scales with altitude
	var speed = pan_speed * (orbit_distance / 1000.0)
	
	# Apply speed boost if Space is held
	if is_speed_boost_active:
		speed *= speed_boost_multiplier
	
	# Convert screen-space direction to world-space
	# Forward is along the camera's -Z axis (projected to XZ plane)
	# Right is along the camera's X axis (projected to XZ plane)
	
	var forward = - transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	
	var right = transform.basis.x
	right.y = 0
	right = right.normalized()
	
	var movement = (forward * direction.y + right * direction.x) * speed * delta
	
	target_position += movement
	
	# Keep target above minimum terrain elevation
	if target_position.y < terrain_min_elevation:
		target_position.y = terrain_min_elevation
	
	_update_camera_transform()


func _zoom(direction: int) -> void:
	"""Zoom in (direction < 0) or out (direction > 0)."""
	# Percentage-based zoom: ~15% per scroll keeps feel proportional from 1 km to 5,000 km
	# (e.g. 10 km → ~1.5 km/step; 1,000 km → ~150 km/step; 3,000 km → ~450 km/step)
	var zoom_factor = 0.15
	
	# Calculate new target distance
	if direction < 0:
		# Zoom in - reduce distance by zoom_factor
		target_orbit_distance *= (1.0 - zoom_factor)
	else:
		# Zoom out - increase distance by zoom_factor
		target_orbit_distance *= (1.0 + zoom_factor)
	
	# Clamp distance to reasonable range
	# Min: 500m (close to terrain); Max: 5,000km (full continental view, e.g. all of Europe)
	target_orbit_distance = clamp(target_orbit_distance, 500.0, 5000000.0)


func _update_camera_transform() -> void:
	"""Update camera position and rotation based on orbit parameters."""
	
	# Convert spherical coordinates to Cartesian
	var pitch_rad = deg_to_rad(orbit_pitch)
	var yaw_rad = deg_to_rad(orbit_yaw)
	
	# Calculate offset from target
	var offset = Vector3(
		cos(pitch_rad) * sin(yaw_rad),
		sin(pitch_rad),
		cos(pitch_rad) * cos(yaw_rad)
	) * orbit_distance
	
	# Set camera position
	position = target_position + offset
	
	# CRITICAL: Prevent camera from going below terrain
	# Raycast down from camera to find terrain height
	var space_state = get_world_3d().direct_space_state
	var ray_length = max(position.y + 10000.0, 20000.0) # Always reach ground
	var query = PhysicsRayQueryParameters3D.create(
		position, # Start at camera
		position + Vector3(0, -ray_length, 0) # Ray straight down
	)
	query.collision_mask = 1 # Only check layer 1 (terrain)
	var result = space_state.intersect_ray(query)
	
	# Debug output (every 30 frames to reduce spam; only in debug builds)
	if debug_collision and OS.is_debug_build():
		frame_count += 1
		if frame_count % 30 == 0:
			if result:
				print("COLLISION: Hit at Y=%.1f, Camera Y=%.1f, Clearance=%.1f, Shape=%s" %
					[result.position.y, position.y, position.y - result.position.y, result.collider.name])
			else:
				print("COLLISION: MISS - No terrain hit! Camera at Y=%.1f" % position.y)
	
	if result:
		# Found terrain below, ensure we stay above it
		var terrain_height = result.position.y
		var min_camera_y = terrain_height + min_camera_clearance
		
		if position.y < min_camera_y:
			# Push camera up to maintain clearance
			var correction = min_camera_y - position.y
			position.y = min_camera_y
			
			# Also adjust orbit_distance to prevent fighting with zoom
			# This prevents the zoom from constantly trying to push you back down
			orbit_distance += correction
			target_orbit_distance = max(target_orbit_distance, orbit_distance)
	
	# Look at target
	look_at(target_position, Vector3.UP)
	
	# Update hex overlay (compositor) and terrain material uniforms
	_update_hex_grid_interaction()


# TODO: Get material reference from TerrainLoader directly instead of from first chunk node
func _get_terrain_material() -> ShaderMaterial:
	var chunk = get_tree().get_first_node_in_group("terrain_chunks")
	if chunk and chunk is MeshInstance3D:
		var mat = chunk.get_surface_override_material(0)
		if mat is ShaderMaterial:
			return mat
	var root = get_tree().root
	if root:
		var node = _find_chunk_recursive(root)
		if node:
			var mat = node.get_surface_override_material(0)
			if mat is ShaderMaterial:
				return mat
	return null


func _ensure_hex_compositor() -> void:
	if _hex_compositor != null:
		return
	var world_env: WorldEnvironment = get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if not world_env:
		return
	# Compositor is on WorldEnvironment; effects are in compositor_effects array
	var comp: Compositor = world_env.compositor
	if comp == null:
		world_env.compositor = Compositor.new()
		comp = world_env.compositor
	var effects: Array = comp.get_compositor_effects()
	for e in effects:
		if e != null and e.get_script() == HexOverlayCompositorScript:
			_hex_compositor = e
			return
	_hex_compositor = HexOverlayCompositorScript.new()
	effects.append(_hex_compositor)
	comp.set_compositor_effects(effects)


func _update_hex_grid_interaction() -> void:
	var alt_uniform: float = orbit_distance if orbit_distance > 0.0 else position.y
	var terrain_materials: Array[ShaderMaterial] = []
	_ensure_hex_compositor()

	# Update terrain materials only (no hex — hex is now screen-space compositor)
	var loader = get_tree().get_first_node_in_group("terrain_loader")
	if loader and loader is TerrainLoader:
		if loader.shared_terrain_material is ShaderMaterial:
			terrain_materials.append(loader.shared_terrain_material as ShaderMaterial)
		if loader.shared_terrain_material_lod2plus is ShaderMaterial:
			terrain_materials.append(loader.shared_terrain_material_lod2plus as ShaderMaterial)
	if terrain_materials.is_empty():
		var single = _get_terrain_material()
		if single:
			terrain_materials.append(single)

	if DEBUG_DIAGNOSTIC and OS.is_debug_build() and not _hex_diag_printed and _hex_compositor:
		_hex_diag_printed = true
		print("[HEX] Frame update: altitude=%.1f show_grid=%s (compositor)" % [alt_uniform, _hex_compositor.show_grid])

	for terrain_material in terrain_materials:
		terrain_material.set_shader_parameter("altitude", alt_uniform)
		terrain_material.set_shader_parameter("camera_position", position)
		terrain_material.set_shader_parameter("terrain_center_xz", _terrain_center_xz)
		terrain_material.set_shader_parameter("terrain_radius_m", _terrain_radius_m)
		terrain_material.set_shader_parameter("show_hex_grid", _grid_visible)
		# Same lens as selection: pointy-top radius
		terrain_material.set_shader_parameter("hex_size", Constants.HEX_SIZE_M / sqrt(3.0))

	# Compositor: selection rim, hover highlight only (grid is in terrain shader)
	if _hex_compositor:
		_hex_compositor.altitude = alt_uniform
		_hex_compositor.camera_position = position
		_hex_compositor.selection_time = _selection_time
		_hex_compositor.selected_hex_center = _selected_hex_center
		_hex_compositor.show_grid = _grid_visible

	# F1: toggle grid visibility (terrain shader + compositor; grid is world-space in shader)
	if Input.is_key_pressed(KEY_F1):
		if not _f1_pressed_last_frame:
			_grid_visible = not _grid_visible
			for terrain_material in terrain_materials:
				terrain_material.set_shader_parameter("show_hex_grid", _grid_visible)
			if _hex_compositor:
				_hex_compositor.show_grid = _grid_visible
			if OS.is_debug_build():
				print("[Camera] Hex grid: ", "ON" if _grid_visible else "OFF")
			_f1_pressed_last_frame = true
	else:
		_f1_pressed_last_frame = false

	var overview_node = get_tree().get_first_node_in_group("overview_plane")
	if overview_node and overview_node is MeshInstance3D:
		_hover_raycast_frame += 1
		var do_raycast = (_hover_raycast_frame % 3 == 0)

		if _selected_hex_center.x < 900000.0:
			var width = Constants.HEX_SIZE_M
			var size_axial = width / sqrt(3.0)
			var q = (2.0 / 3.0 * _selected_hex_center.x) / size_axial
			var r = (-1.0 / 3.0 * _selected_hex_center.x + sqrt(3.0) / 3.0 * _selected_hex_center.y) / size_axial
			var sel_axial = _axial_round(Vector2(q, r))
			_update_selection_label(int(sel_axial.x), int(sel_axial.y))
		else:
			_hide_selection_label()

		if do_raycast:
			var mouse_pos = get_viewport().get_mouse_position()
			var space_state = get_world_3d().direct_space_state
			var ray_origin = project_ray_origin(mouse_pos)
			var ray_end = ray_origin + project_ray_normal(mouse_pos) * 500000.0
			var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
			query.collision_mask = 1
			var result = space_state.intersect_ray(query)

			if result:
				var hit_pos = result.position
				var width = Constants.HEX_SIZE_M
				var hex_size = width / sqrt(3.0)
				var q = (2.0 / 3.0 * hit_pos.x) / hex_size
				var r = (-1.0 / 3.0 * hit_pos.x + sqrt(3.0) / 3.0 * hit_pos.z) / hex_size
				var hex_axial = _axial_round(Vector2(q, r))
				var hex_q = int(hex_axial.x)
				var hex_r = int(hex_axial.y)
				var center_x = hex_size * (3.0 / 2.0 * hex_q)
				var center_z = hex_size * (sqrt(3.0) / 2.0 * hex_q + sqrt(3.0) * hex_r)
				_hovered_hex_center = Vector2(center_x, center_z)
				if _hex_compositor:
					_hex_compositor.hovered_hex_center = _hovered_hex_center
				_update_debug_visuals(hit_pos, Vector3(center_x, hit_pos.y, center_z))
				_update_debug_label(hex_q, hex_r)
			else:
				_hide_debug_label()
				_hovered_hex_center = Vector2(-999999.0, -999999.0)
				if _hex_compositor:
					_hex_compositor.hovered_hex_center = _hovered_hex_center

		# F2: cycle hex overlay debug (0=off, 1=depth, 2=world XZ pattern) to diagnose grid drift
		if Input.is_key_pressed(KEY_F2):
			if not _f2_pressed_last_frame and _hex_compositor:
				var d = _hex_compositor.debug_visualization
				d = 0.0 if d >= 2.0 else (1.0 if d < 0.5 else 2.0)
				_hex_compositor.debug_visualization = d
				if OS.is_debug_build():
					var msg = "Hex debug: off" if d < 0.5 else ("depth" if d < 1.5 else "world XZ pattern")
					print("[HEX DEBUG] %s (F2 to cycle)" % msg)
				_f2_pressed_last_frame = true
		else:
			_f2_pressed_last_frame = false

		# F3: toggle depth NDC flip (use 1-depth as NDC z; try if depth debug is "all dark")
		if Input.is_key_pressed(KEY_F3):
			if not _f3_pressed_last_frame and _hex_compositor:
				_hex_compositor.depth_ndc_flip = not _hex_compositor.depth_ndc_flip
				if OS.is_debug_build():
					print("[HEX DEBUG] depth_ndc_flip = %s (F3 to toggle)" % _hex_compositor.depth_ndc_flip)
				_f3_pressed_last_frame = true
		else:
			_f3_pressed_last_frame = false

		# F4: toggle Debug Depth view (4 quadrants = R/G/B/A channels; border = magenta raw / yellow resolved)
		if Input.is_key_pressed(KEY_F4):
			if not _f4_pressed_last_frame and _hex_compositor:
				_hex_compositor.debug_depth = not _hex_compositor.debug_depth
				if OS.is_debug_build():
					var on_off = "ON (4 quadrants = R,G,B,A)" if _hex_compositor.debug_depth else "OFF"
					print("[HEX DEBUG] Debug Depth %s (F4=toggle view, F6=toggle depth source)" % on_off)
				_f4_pressed_last_frame = true
		else:
			_f4_pressed_last_frame = false

		# F6: toggle depth source (raw vs resolved). Border in debug view: MAGENTA=raw, YELLOW=resolved.
		if Input.is_key_pressed(KEY_F6):
			if not _f6_pressed_last_frame and _hex_compositor:
				_hex_compositor.use_resolved_depth = not _hex_compositor.use_resolved_depth
				if OS.is_debug_build():
					var src = "RESOLVED" if _hex_compositor.use_resolved_depth else "RAW"
					print("[HEX DEBUG] depth source = %s (F6 to toggle; with F4 on, border is yellow=resolved, magenta=raw)" % src)
				_f6_pressed_last_frame = true
		else:
			_f6_pressed_last_frame = false


var _grid_visible: bool = Constants.GRID_DEFAULT_VISIBLE
var _f1_pressed_last_frame: bool = false
var _f2_pressed_last_frame: bool = false
var _f3_pressed_last_frame: bool = false
var _f4_pressed_last_frame: bool = false
var _f6_pressed_last_frame: bool = false
var _debug_label: Label = null
var _selection_label: Label = null
var _hex_diag_printed: bool = false


func _find_chunk_recursive(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and node.name.begins_with("Chunk_LOD"):
		return node
	
	for child in node.get_children():
		var result = _find_chunk_recursive(child)
		if result:
			return result
	return null


func _axial_round(axial: Vector2) -> Vector2:
	return _cube_round(Vector3(axial.x, axial.y, -axial.x - axial.y))


func _cube_round(cube: Vector3) -> Vector2:
	var rx = round(cube.x)
	var ry = round(cube.y)
	var rz = round(cube.z)

	var x_diff = abs(rx - cube.x)
	var y_diff = abs(ry - cube.y)
	var z_diff = abs(rz - cube.z)

	if x_diff > y_diff and x_diff > z_diff:
		rx = - ry - rz
	elif y_diff > z_diff:
		ry = - rx - rz
	else:
		rz = - rx - ry
	
	return Vector2(rx, ry)


func _update_debug_label(q: int, r: int) -> void:
	if not _debug_label:
		_debug_label = Label.new()
		_debug_label.position = Vector2(20, 20)
		_debug_label.add_theme_font_size_override("font_size", 24)
		add_child(_debug_label)
	
	_debug_label.text = "Hex: (%d, %d)" % [q, r]
	_debug_label.visible = true


func _hide_debug_label() -> void:
	if _debug_label:
		_debug_label.visible = false


func _update_selection_label(q: int, r: int) -> void:
	if not _selection_label:
		_selection_label = Label.new()
		_selection_label.position = Vector2(20, 52)
		_selection_label.add_theme_font_size_override("font_size", 20)
		_selection_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.4))
		add_child(_selection_label)
	_selection_label.text = "Selected: (%d, %d)" % [q, r]
	_selection_label.visible = true


func _hide_selection_label() -> void:
	if _selection_label:
		_selection_label.visible = false


var _zoom_in_label: Label = null
var _zoom_in_label_timer: float = 0.0

func _show_zoom_in_to_select_message() -> void:
	if not _zoom_in_label:
		_zoom_in_label = Label.new()
		_zoom_in_label.position = Vector2(20, 84)
		_zoom_in_label.add_theme_font_size_override("font_size", 18)
		_zoom_in_label.add_theme_color_override("font_color", Color(0.9, 0.75, 0.3))
		add_child(_zoom_in_label)
	_zoom_in_label.text = "Zoom in to select a hex"
	_zoom_in_label.visible = true
	_zoom_in_label_timer = 3.0

func _clear_zoom_in_message() -> void:
	if _zoom_in_label:
		_zoom_in_label.visible = false
	_zoom_in_label_timer = 0.0
