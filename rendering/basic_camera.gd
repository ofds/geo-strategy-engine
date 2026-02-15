extends Camera3D
## Basic Camera Controller for Terrain Viewing
## Features: WASD pan, scroll zoom, middle mouse orbit
## Stays above terrain at all times

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

# Speed boost
var speed_boost_multiplier: float = 10.0 # 10x speed when Space is held
var is_speed_boost_active: bool = false

# Mouse state
var is_orbiting: bool = false
var last_mouse_pos: Vector2 = Vector2.ZERO

# Terrain chunk reference (for initial positioning)
var chunk_size_m: float = 15360.0 # 512 px × 30 m = 15.36 km

# Terrain height reference
var terrain_min_elevation: float = 0.0
var terrain_max_elevation: float = 5000.0
var min_camera_clearance: float = 100.0 # Stay at least 100m above terrain


func _ready() -> void:
	# Ensure camera can see very far for large terrain
	far = 500000.0 # 500km view distance (very large for complete coverage)
	near = 10.0 # Prevent clipping when very close to terrain
	
	# Position camera above center of terrain (chunk 15, 8 at LOD 0)
	# Each LOD 0 chunk is 15,360m wide (512 px × 30 m)
	var local_chunk_size_m: float = 15360.0
	
	# Calculate center of terrain in world space
	var center_chunk_x: float = 15.0
	var center_chunk_y: float = 8.0
	var grid_center_world_x: float = (center_chunk_x + 0.5) * local_chunk_size_m
	var grid_center_world_z: float = (center_chunk_y + 0.5) * local_chunk_size_m
	
	target_position = Vector3(grid_center_world_x, 1000, grid_center_world_z) # Look at 1km elevation
	
	# Start at 50km altitude to see LOD rings clearly
	orbit_distance = 50000.0 # 50km altitude
	target_orbit_distance = 50000.0
	orbit_pitch = 70.0 # Steep angle for top-down view
	orbit_yaw = 45.0
	
	_update_camera_transform()
	
	print("\n=== Camera initialized for multi-LOD view ===")
	print("Target: %s" % target_position)
	print("Distance: %.1f m (%.1f km)" % [orbit_distance, orbit_distance / 1000.0])
	print("Pitch: %.1f°" % orbit_pitch)
	print("Camera position: %s" % position)
	print("Camera far plane: %.1f m" % far)
	print("View optimized for seeing LOD rings across large terrain")


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
			print("DEBUG: Left Click Detected at ", event.position)
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
	# Raycast to find clicked hex
	var space_state = get_world_3d().direct_space_state
	var ray_origin = project_ray_origin(screen_pos)
	var ray_end = ray_origin + project_ray_normal(screen_pos) * 500000.0
	
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collision_mask = 1
	var result = space_state.intersect_ray(query)
	
	if result:
		var hit_pos = result.position
		
		# Convert to hex
		var width = Constants.HEX_SIZE_M
		var hex_size = width / sqrt(3.0)
		
		var q = (2.0 / 3.0 * hit_pos.x) / hex_size
		var r = (-1.0 / 3.0 * hit_pos.x + sqrt(3.0) / 3.0 * hit_pos.z) / hex_size
		
		var hex_axial = _axial_round(Vector2(q, r))
		var hex_q = int(hex_axial.x)
		var hex_r = int(hex_axial.y)
		
		# Calculate Center
		var center_x = hex_size * (3.0 / 2.0 * hex_q)
		var center_z = hex_size * (sqrt(3.0) / 2.0 * hex_q + sqrt(3.0) * hex_r)
		var center = Vector2(center_x, center_z)
		
		print("DEBUG: Clicked Hex (%d, %d) Center: %s" % [hex_q, hex_r, center])
		
		# Toggle selection
		if _selected_hex_center.distance_to(center) < 1.0:
			# Deselect if clicking same hex (instant, no fade-out)
			print("DEBUG: Deselecting")
			_selected_hex_center = Vector2(999999, 999999)
		else:
			# Select new hex — reset animation timer
			print("DEBUG: Selecting new hex")
			_selected_hex_center = center
			_selection_time = 0.0
	else:
		# Clicked sky/nothing -> Deselect
		print("DEBUG: Clicked Sky -> Deselecting")
		_selected_hex_center = Vector2(999999, 999999)
	
	# Update Shader immediately
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

func _update_hex_selection_uniform() -> void:
	# ... existing code ...
	# Find material (reusing logic from _update_hex_grid_interaction or caching it would be better)
	# For now, quick lookup same as before
	var terrain_material: ShaderMaterial = null
	var chunk = get_tree().get_first_node_in_group("terrain_chunks")
	if chunk and chunk is MeshInstance3D:
		var mat = chunk.get_surface_override_material(0)
		# UNIFIED SHADER FLIP: The material IS the ShaderMaterial now, not next_pass
		if mat is ShaderMaterial:
			terrain_material = mat
	
	# Fallback search
	if not terrain_material:
		var root = get_tree().root
		if root:
			var node = _find_chunk_recursive(root)
			if node:
				var mat = node.get_surface_override_material(0)
				if mat is ShaderMaterial:
					terrain_material = mat
	
	if terrain_material:
		terrain_material.set_shader_parameter("selected_hex_center", _selected_hex_center)
		terrain_material.set_shader_parameter("selection_time", _selection_time)
	else:
		print("DEBUG: Could not find terrain material to update selection!")


func _process(delta: float) -> void:
	# Check for speed boost (Space key)
	is_speed_boost_active = Input.is_key_pressed(KEY_SPACE)
	
	# Animate selection (lift/border/tint fade-in)
	if _selected_hex_center.x < 900000.0: # Has selection (not sentinel)
		_selection_time += delta
	
	# Smoothly interpolate orbit_distance toward target
	orbit_distance = lerp(orbit_distance, target_orbit_distance, zoom_smoothing * delta)
	
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
	
	# Zoom amount should be a percentage of current distance
	# This keeps zoom speed proportional at all distances
	var zoom_factor = 0.15 # 15% per scroll
	
	# Calculate new target distance
	if direction < 0:
		# Zoom in - reduce distance by zoom_factor
		target_orbit_distance *= (1.0 - zoom_factor)
	else:
		# Zoom out - increase distance by zoom_factor
		target_orbit_distance *= (1.0 + zoom_factor)
	
	# Clamp distance to reasonable range
	# Min: 500m (close to terrain)
	# Max: 150km (far enough to see entire region)
	target_orbit_distance = clamp(target_orbit_distance, 500.0, 150000.0)


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
	
	# Debug output (every 30 frames to reduce spam)
	if debug_collision:
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
	
	# Update Hex Grid Uniforms and Interaction
	_update_hex_grid_interaction()


func _update_hex_grid_interaction() -> void:
	# 1. Update Altitude Uniform
	# The terrain material is shared, so we can access it from any chunk or via the customized TerrainLoader if we had a reference.
	# But better: access via the tree or a known global.
	# Since we don't have a direct reference to the terrain material here, we need to find it.
	# In this demo setup, the chunks are children of the scene root or a manager.
	# We can try to get the material from a chunk if one exists, or rely on a global singleton if it existed.
	# A robust way: The camera doesn't usually manage terrain materials.
	# However, for this task, we need to pass the uniforms.
	# We can find a MeshInstance3D that is a chunk and get its material.
	# Or, improved: TerrainLoader sets the material on the chunks.
	# Let's assume we can get it from the first MeshInstance3D we find in the "Terrain" group or similar.
	# For now, let's look for a chunk in the scene tree.
	var terrain_material: ShaderMaterial = null
	var chunk = get_tree().get_first_node_in_group("terrain_chunks")
	if chunk and chunk is MeshInstance3D:
		var mat = chunk.get_surface_override_material(0)
		if mat is ShaderMaterial:
			terrain_material = mat
	
	# fallback: try to find by name pattern if group not set
	if not terrain_material:
		var root = get_tree().root
		if root:
			var node = _find_chunk_recursive(root)
			if node:
				var mat = node.get_surface_override_material(0)
				if mat is ShaderMaterial:
					terrain_material = mat
	
	if terrain_material:
		# Update Altitude
		terrain_material.set_shader_parameter("altitude", position.y)
		# Fog: pass camera position to shader
		terrain_material.set_shader_parameter("camera_position", position)
		# Selection animation time (incremented in _process when selected)
		terrain_material.set_shader_parameter("selection_time", _selection_time)
		terrain_material.set_shader_parameter("selected_hex_center", _selected_hex_center)
		
		# Update Hovered Hex
		var mouse_pos = get_viewport().get_mouse_position()
		var space_state = get_world_3d().direct_space_state
		var ray_origin = project_ray_origin(mouse_pos)
		var ray_end = ray_origin + project_ray_normal(mouse_pos) * 500000.0 # Long ray
		
		# Raycast to terrain (mask 1)
		var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
		query.collision_mask = 1
		var result = space_state.intersect_ray(query)
		
		if result:
			var hit_pos = result.position
			
			# Convert hit_pos to Hex Coordinates
			# Flat-top hex math (matching shader exactly)
			# Width (flat-to-flat) = HEX_SIZE_M (1000.0)
			# Size (center-to-corner) = Width / sqrt(3)
			var width = Constants.HEX_SIZE_M
			var hex_size = width / sqrt(3.0)
			
			# Axial coordinates (q, r)
			# q = (2/3 * x) / size
			# r = (-1/3 * x + sqrt(3)/3 * z) / size
			var q = (2.0 / 3.0 * hit_pos.x) / hex_size
			var r = (-1.0 / 3.0 * hit_pos.x + sqrt(3.0) / 3.0 * hit_pos.z) / hex_size
			
			# Round to nearest hex
			var hex_axial = _axial_round(Vector2(q, r))
			var hex_q = int(hex_axial.x)
			var hex_r = int(hex_axial.y)
			
			# Calculate World Center of hit hex
			# x = size * (3/2 * q)
			# z = size * (sqrt(3)/2 * q + sqrt(3) * r)
			var center_x = hex_size * (3.0 / 2.0 * hex_q)
			var center_z = hex_size * (sqrt(3.0) / 2.0 * hex_q + sqrt(3.0) * hex_r)
			
			# Pass to Shader
			if terrain_material:
				terrain_material.set_shader_parameter("hovered_hex_center", Vector2(center_x, center_z))
			
			# Debug Visuals
			_update_debug_visuals(hit_pos, Vector3(center_x, hit_pos.y, center_z))
			
			# Show Debug Label
			_update_debug_label(hex_q, hex_r)
		else:
			# No hit
			_hide_debug_label()
			
		# Toggle Visibility F1
		if Input.is_key_pressed(KEY_F1):
			if not _f1_pressed_last_frame:
				_grid_visible = not _grid_visible
				terrain_material.set_shader_parameter("show_grid", _grid_visible)
				_f1_pressed_last_frame = true
		else:
			_f1_pressed_last_frame = false


var _grid_visible: bool = true
var _f1_pressed_last_frame: bool = false
var _debug_label: Label = null


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
