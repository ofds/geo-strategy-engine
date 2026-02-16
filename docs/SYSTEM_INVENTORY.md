# System Inventory for Pattern Review

Technical documentation of how each system currently works. No suggestions or improvements — only what exists in code.

---

## 1. Terrain Streaming (`core/chunk_manager.gd`, `core/terrain_loader.gd`, `core/terrain_worker.gd`)

### Approach
Fixed 2D grid of chunks at five LOD levels (0–4). Desired set is recomputed on a timer; async Phase A (worker) decodes PNG and builds mesh data; Phase B (main thread) builds mesh, scene node, and collision in micro-steps with a frame budget. Chunks are keyed by `"lod{L}_x{X}_y{Y}"` and stored in a flat dictionary.

### Implementation Details

**Chunk organization**
- **Grid:** 2D grid of LOD 0 cells. Grid size from metadata: `_lod0_grid = ((master_heightmap_width + 511) / 512, (master_heightmap_height + 511) / 512)`. Each LOD level has half the grid dimensions of the previous (LOD n chunk covers 2^n × 2^n LOD 0 cells).
- **Storage:** `loaded_chunks: Dictionary` — key `"lod{L}_x{X}_y{Y}"`, value `{ node: Node3D, lod: int, x: int, y: int }`. No quadtree; flat dictionary.
- **Load queue:** Array of `{ lod, x, y }`, sorted by distance (and LOD bias when zoomed in). One chunk popped per frame for async submit, up to `MAX_CONCURRENT_ASYNC_LOADS_BASE` (4) or `MAX_CONCURRENT_ASYNC_LOADS_LARGE` (8) when queue > 20.

**Desired set algorithm**
- `_determine_desired_chunks(camera_pos)`:
  1. `visible_radius = max(INNER_RADIUS_M, altitude * VISIBLE_RADIUS_ALTITUDE_FACTOR)` (constants from config).
  2. **Inner ring:** `_determine_inner_chunks(camera_pos, altitude)` — LOD 0 cells in axis-aligned box: camera cell ± `cells_radius` where `cells_radius = ceil(INNER_RADIUS_M / cell_size_m)`, `cell_size_m = 512 * resolution_m`. For each LOD 0 cell in that box, horizontal distance to cell center and altitude are passed to `_select_lod_with_hysteresis(lod0_key, horiz_dist, altitude)` which returns 0–4. Desired set is built by iterating LOD 0–4 and emitting one chunk per LOD 0 cell at its chosen LOD (chunk coordinates at that LOD = cell / 2^lod). Overlapping chunks (same chunk covering multiple cells) are deduplicated; `_verify_full_coverage_box` asserts every LOD 0 cell in the box is covered.
  3. **Outer ring:** `_determine_outer_lod4_chunks(camera_pos, visible_radius)` — LOD 4 chunks only, where distance from camera to chunk center is between INNER_RADIUS_M and visible_radius. Merged into desired; inner takes precedence on key overlap.
  4. **Expand LOD 0–3 to full 2×2 blocks:** `_expand_lod0_to_full_blocks(desired)` so each chunk at LOD 0–3 has its three siblings in desired; this allows visibility logic to hide the coarser parent when all four children are loaded.

**LOD selection and hysteresis**
- **Distance thresholds:** From `_Const.LOD_DISTANCES_M`: LOD 0 if dist < 50 km, LOD 1 if < 75 km, LOD 2 if < 200 km, LOD 3 if < 500 km, else LOD 4. Exact comparisons: `dist < LOD_DISTANCES_M[1]` → 0, etc.
- **Altitude gate:** If altitude > 70 km (hardcoded `ALTITUDE_LOD0_MAX_M = 70000.0`) and base_lod would be 0, force base_lod = 1 (no LOD 0 at high altitude).
- **Hysteresis:** Stored in `lod_hysteresis_state[lod0_key]` (key `"%d_%d" % [lod0_x, lod0_y]`). Upgrade (camera closer, finer LOD): immediate, no hysteresis. Downgrade: only if `dist >= threshold + threshold * LOD_HYSTERESIS` (10% buffer). So when moving away, LOD stays finer until past the buffer.

**Async loading (Phase A vs Phase B)**
- **Phase A (background):** `TerrainLoader.start_async_load(cx, cy, lod)` builds `args` (chunk path or cached heights, resolution, LOD, etc.) and submits `TerrainWorker.compute_chunk_data` to `WorkerThreadPool`. Worker (static methods, no Node refs) reads PNG via `decode_png_to_heights`, builds vertices/normals/indices/height_data at the LOD’s mesh resolution (`LOD_MESH_RESOLUTION[lod]`: 512, 256, 128, 64, 32), writes to `args["result"]`. No mesh or scene nodes in Phase A. LOD 4 “ultra” path (flat quad at avg elevation) is implemented in TerrainLoader’s `_compute_chunk_data` but TerrainWorker sets `ultra_lod: false` and always produces the normal 32×32 mesh.
- **Phase B (main thread):** When `WorkerThreadPool.is_task_completed(task_id)`, ChunkManager drains into `_pending_phase_b`: for each completed task, if `last_desired.has(chunk_key)` and result non-empty, heights are added to TerrainLoader’s height cache and an entry `{ computed, chunk_key, lod, x, y, step: 0, mesh, mesh_instance }` is appended. Each frame, `_do_one_phase_b_step()` runs up to a time budget (default 8 ms, 16 ms during initial load): step 0 → `finish_load_step_mesh` → step 1 → `finish_load_step_scene` (MeshInstance3D, position, material, add to chunks_container, set_instance_shader_parameter("chunk_origin_xz", Vector2(world_pos.x, world_pos.z)), scale tween 0.97→1), step 2 → `finish_load_step_collision` (HeightMapShape3D for LOD 0–1 only), then pop and register in `loaded_chunks`. When camera altitude < 15 km and pending Phase B > 2, minimum 3 steps per frame to drain faster.

**Chunk creation, position, removal**
- **Creation:** Mesh from Phase B; world position from `_chunk_to_world_position(chunk_x, chunk_y, lod)` = `(chunk_x * world_chunk_size, 0, chunk_y * world_chunk_size)` where `world_chunk_size = 512 * resolution_m * 2^lod`. Mesh vertices are in local space 0..chunk_world_size; instance position is that corner.
- **Removal:** Unload candidates = loaded and not in desired. Unload only if (a) camera did a large move (> 200 km) and chunk is beyond 1.5× visible radius (immediate), or (b) chunk’s LOD 0 cells are all covered by finer loaded chunks, or (c) deferred timeout (5 s normally, 1 s after large move). Burst unloads (>10) are spread over 3 frames via `_pending_unload_keys`. `_unload_chunk`: queue_free mesh node, queue_free collision shape by name `"HeightMap_LOD{l}_{x}_{y}"`, erase from `loaded_chunks`.

**Height cache**
- TerrainLoader: `_height_cache` (path → Array[float]), `_height_cache_order` for FIFO. Max 100 entries (`HEIGHT_CACHE_MAX`). On sync load or when Phase A result is drained, `_add_to_height_cache(path_for_cache, heights_for_cache)` is called. `get_height_at(world_x, world_z)`: LOD 0 chunk key from world XZ, path `res://data/terrain/chunks/lod0/chunk_{cx}_{cy}.png`; if not in cache returns -1; else bilinear interpolation in pixel space (lx/lz within chunk, px/pz, four samples, lerp). Used by HexSelector and ChunkManager’s public API.

**Overview plane**
- In `_setup_overview_plane()` (called before chunks_container in _ready): if metadata has `overview_texture`, a single quad MeshInstance3D is created: vertices (0,0,0) to (overview_w, 0, overview_h) with overview_w/h = LOD 0 grid × 512 × resolution_m; Y = -20; UVs so texture north maps to Z=0; StandardMaterial3D unshaded with albedo_texture. Added to group "overview_plane". Same world extent as chunk grid so macro view aligns. Always present; visibility not toggled by altitude — terrain chunks render on top; at high altitude overview texture is also blended in the terrain shader via `overview_blend`.

**Data flow: PNG → mesh → node**
- PNG path: `res://data/terrain/chunks/lod{L}/chunk_{x}_{y}.png`. 16-bit grayscale; raw read, IHDR/IDAT parse, decompress, PNG row filter reconstruction, big-endian uint16 → height_m = (value - SEA_LEVEL_UINT16) / (65535 - SEA_LEVEL_UINT16) * max_elevation_m. Vertices: sample heightmap at stride (chunk_size_px / mesh_res), position in local space (x * actual_vertex_spacing, height, z * actual_vertex_spacing), indices for quads, normals from cross of tangent vectors. Collision: HeightMapShape3D with same mesh_res sample grid; position = world corner + half_size (HeightMapShape3D is centered); scale = height_sample_spacing.

### Key Design Decisions
- Single desired-set pass per update interval; no incremental streaming by “priority ring”.
- Phase B split into three steps (MESH, SCENE, COLLISION) to spread main-thread cost and respect frame budget.
- LOD 0 disabled above 70 km to avoid load/unload flicker and match overview.
- Deferred unload only when area is fully covered by finer LOD or timeout; burst unloads spread across frames.
- Visibility: coarse chunk hidden only when all four finer children are loaded (no per-pixel LOD blend).

### Dependencies
- ChunkManager: TerrainLoader (sibling), camera (viewport), chunks_container, collision_body, LoadingScreen (optional). Uses Constants (via _Const preload) for LOD_DISTANCES_M, INNER_RADIUS_M, VISIBLE_RADIUS_ALTITUDE_FACTOR.
- TerrainLoader: Constants (TERRAIN_DATA_PATH, SEA_LEVEL_UINT16); terrain_metadata.json; terrain.gdshader for shared material.
- TerrainWorker: Constants (SEA_LEVEL_UINT16); no scene references.

### Assumptions
- Chunk grid aligned to world origin (0,0); chunk (0,0) at LOD 0 is at world (0, 0) to (512*resolution_m, 512*resolution_m). Y up; X east, Z south.
- Metadata provides master_heightmap_width/height, resolution_m, chunk_size_px, overview_texture path.
- PNG 16-bit grayscale; sea level encoded as SEA_LEVEL_UINT16.
- Camera has `get_target_ground_position()` and orbit_distance (or position.y) for altitude.

### Ad-hoc or Pattern-Based?
Custom implementation. No reference to a standard (e.g. clipmap, virtual texture). Fixed grid with distance-based LOD bands and hysteresis; async pipeline is a two-phase “worker produces data, main thread consumes” pattern common in engines but not named after a published scheme.

---

## 2. Camera System (`rendering/basic_camera.gd`)

### Approach
Orbital camera: target position on XZ, orbit distance (altitude), pitch and yaw in degrees. Zoom is continuous percentage-based (15% per scroll). Terrain clearance enforced by raycast down each frame; camera is pushed up if below terrain + min_camera_clearance. Camera drives terrain shader uniforms and hex compositor; performs hex hover (throttled raycast) and click-to-select.

### Implementation Details

**Camera model**
- **Orbital:** Target `target_position` (Vector3, Y ignored for “ground”); `orbit_distance`, `orbit_pitch` (degrees from horizontal), `orbit_yaw` (degrees). Position = target + offset where offset = (cos(pitch)*sin(yaw), sin(pitch), cos(pitch)*cos(yaw)) * orbit_distance. Then `look_at(target_position, Vector3.UP)`.

**Movement**
- **Pan:** WASD in `_process`; direction normalized, converted to world XZ: forward = -basis.z flattened to XZ, right = basis.x flattened; movement = (forward * dir.y + right * dir.x) * speed * delta. Speed = pan_speed * (orbit_distance / 1000); if Space held, speed *= speed_boost_multiplier (10). target_position += movement; then _update_camera_transform().
- **Orbit:** Middle mouse drag: orbit_yaw -= delta.x * orbit_sensitivity, orbit_pitch -= delta.y * orbit_sensitivity; pitch clamped 10–89°. No zoom during orbit from scroll (scroll handled in _input).

**Zoom**
- **Continuous:** Scroll in _input calls _zoom(±1). target_orbit_distance *= (1 - 0.15) for zoom in, *= (1 + 0.15) for zoom out. Clamped to 500 m–5,000 km. No discrete steps. In _process, orbit_distance = lerp(orbit_distance, target_orbit_distance, zoom_smoothing * delta) (zoom_smoothing = 8).

**Terrain clearance**
- In _update_camera_transform(), after setting position: raycast from position straight down (position to position - (0, ray_length, 0), ray_length = max(position.y + 10000, 20000)); collision_mask = 1. If hit, min_camera_y = hit.y + min_camera_clearance (100 m). If position.y < min_camera_y, position.y = min_camera_y and orbit_distance += correction, target_orbit_distance = max(target_orbit_distance, orbit_distance).

**Interaction with other systems**
- **Shader uniforms:** _update_hex_grid_interaction() gets terrain material(s) from TerrainLoader group or first node in "terrain_chunks"; sets altitude, camera_position, terrain_center_xz, terrain_radius_m, show_hex_grid, hex_size (HEX_SIZE_M/sqrt(3)). Called from _update_camera_transform().
- **Compositor:** _ensure_hex_compositor() finds WorldEnvironment on parent, gets or creates Compositor, finds or creates HexOverlayCompositor effect; each frame sets altitude, camera_position, selection_time, selected_hex_center, show_grid, hovered_hex_center (from hover raycast).
- **Chunk loading:** ChunkManager uses get_target_ground_position() (target_position with Y=0) and orbit_distance (for altitude) to compute desired set and visibility.
- **Hex hover/selection:** Raycast from screen (project_ray_origin/normal * 500000); hit → get_lod_at_world_position (reject LOD ≥ 3 with “Zoom in to select”) → _hex_center_from_hit_chunk_local → set_selected_hex / clear_selection on HexSelector; compositor selected_hex_center and selection_time updated. Hover: every 3rd frame (when overview_plane exists) same raycast, _hex_center_from_hit_chunk_local → compositor hovered_hex_center.

**Altitude-specific behavior**
- Far plane: if orbit_distance > 1,000 km then far = 10,000 km else 2,000 km.
- No explicit “altitude bands” for control behavior; pan speed and zoom curve are the same at all altitudes. Shader uses altitude for overview blend, fog, desaturation, grid fade (constants GRID_FADE_START/END 5k–20k in constants; compositor uses same for grid_fade_alpha).

### Key Design Decisions
- Single camera script owns both flight and hex interaction; no separate “strategy camera” vs “tactical camera” objects.
- Terrain material discovered via group "terrain_loader" and "terrain_chunks" or recursive find of Chunk_LOD* node.
- Compositor created lazily and attached to WorldEnvironment at runtime (not in scene file).

### Dependencies
- Parent scene must have TerrainLoader, ChunkManager, HexSelector, WorldEnvironment (for compositor). Uses Constants (HEX_SIZE_M, HEX_RADIUS_M, GRID_DEFAULT_VISIBLE, CHUNK_SIZE_PX, RESOLUTION_M).

### Assumptions
- Camera is the viewport’s active camera. Y-up; X east, Z south. Terrain on collision layer 1. Metadata and grid layout same as Terrain Streaming section.

### Ad-hoc or Pattern-Based?
Orbital camera is a common pattern; implementation is straightforward and custom. No reference to a named pattern (e.g. “strategy camera”). Zoom and clearance logic are ad-hoc.

---

## 3. Hex Coordinate System (across all files)

### Approach
Axial coordinates (q, r) with cube constraint (x + y + z = 0); pointy-top orientation (vertex at top). World X = first axial axis, Z = second. Same formulas in terrain shader, basic_camera (selection/hover), hex_overlay_screen.glsl, and hex_selector for geometry; chunk-local space used in shader and selection to keep float precision at large world coordinates.

### Implementation Details

**Where hex math lives**
- **terrain.gdshader:** world_to_axial(xz, size), axial_to_center(axial, size), cube_round(c), hex_sdf(p, apothem), hex_grid_distance(local_xz, size). Uses `v_local_xz = world_pos.xz - chunk_origin_xz`; size = hex_size (pointy-top radius).
- **basic_camera.gd:** _hex_center_from_hit_chunk_local(hit_pos): get_chunk_origin_at from ChunkManager, local_xz = hit - chunk_origin, q/r from local, cube_round_shader, axial_to_center in local then add chunk_origin. _axial_round, _cube_round, _cube_round_shader (returns Vector3 for .x/.z as axial). Phase 4d comparison uses same chunk-local formulas.
- **hex_overlay_screen.glsl:** world_to_axial(pos, width), cube_round(cube), axial_round(axial), hex_dist(p, width). Works in camera-relative XZ; hover/selected centers converted to camera-relative for comparison.
- **hex_selector.gd:** _hex_corners_local(radius) pointy-top six corners; _hex_row_intersection_x(z_row, radius) for flat edges at ±apothem; _is_inside_hex(lx, lz, radius). Uses Constants.HEX_RADIUS_M.
- **hex_grid_mesh.gd:** _world_to_axial(world_x, world_z) for decal texture; uses Constants.HEX_SIZE_M.
- **chunk_manager.gd:** get_chunk_origin_at(world_x, world_z): get_lod_at_world_position; if LOD < 0 uses LOD 0 cell size for origin; else chunk_size = 512*resolution_m*2^lod, origin = (floor(world_x/size)*size, floor(world_z/size)*size). get_lod_at_world_position: iterate loaded_chunks, find finest LOD whose world AABB contains point.

**Coordinate system**
- **Axial (q, r):** q = (2/3 * x) / size, r = (-1/3 * x + sqrt(3)/3 * z) / size (x,z in world or local). Cube: (q, -q-r, r). Round: cube_round then axial = (rounded.x, rounded.z) in shader/camera; cube_round in GDScript returns Vector2(rx, ry) with ry as second component (cube y = -q-r).
- **Pointy-top:** Vertices at (0, ±radius); flat edges at x = ±apothem, apothem = radius * sqrt(3)/2. axial_to_center: cx = size * (1.5 * axial.x), cz = size * (sqrt(3)/2 * axial.x + sqrt(3) * axial.y).
- **Chunk-local:** chunk_origin_xz = NW corner of chunk containing the point (from ChunkManager). Shader: v_local_xz = world_pos.xz - chunk_origin_xz; all hex SDF/axial math in fragment use v_local_xz and hex_size. Selection: hit → chunk_origin_at(hit) → local = hit - chunk_origin → same q/r/cube_round/axial_to_center in local → center_local + chunk_origin.

**HEX_SIZE_M and HEX_RADIUS_M**
- **constants.gd:** HEX_SIZE_M = 1000 (flat-to-flat width); HEX_RADIUS_M = HEX_SIZE_M / sqrt(3) ≈ 577.35 (pointy-top radius, center to vertex).
- **Usage:** Terrain shader and selection use the radius (pointy-top); camera sets shader hex_size = Constants.HEX_SIZE_M/sqrt(3). Compositor hex_size = Constants.HEX_SIZE_M (1000); GLSL then uses width/√3 as “size” for axial (so effective radius 577.35). HexSelector slice and _hex_corners_local use HEX_RADIUS_M. So “hex_size” in shader/camera = radius; in compositor init = flat-to-flat but GLSL derives radius.

**Inconsistencies**
- **Compositor:** Receives hex_size = 1000 (flat-to-flat) from Constants.HEX_SIZE_M; GLSL uses size = width/SQRT_3 for world_to_axial and hex_dist. So effective radius matches elsewhere but the uniform name/semantic differs (flat-to-flat vs radius).
- **Cube component order:** Shader cube = (axial.x, -axial.x-axial.y, axial.y); axial from rounded = (rounded.x, rounded.z). GDScript _cube_round_shader returns Vector3(rx, ry, rz); axial = (rx, rz). Consistent.
- **Phase 4d report:** Documents that SDF at (0, 577.35) and (apothem, 0) should be ~0 for pointy-top; conclusion written based on sdf_top check.

### Key Design Decisions
- Chunk-local origin from ChunkManager as single source for “which chunk this point is in” and origin for float precision; selection and shader both use it.
- Pointy-top everywhere for rendering and selection; flat-to-flat only in constants as the base measure.

### Dependencies
- ChunkManager for get_chunk_origin_at and get_lod_at_world_position. Constants for HEX_SIZE_M, HEX_RADIUS_M. Terrain shader receives chunk_origin_xz per instance from ChunkManager at Phase B.

### Assumptions
- World XZ aligned with axial axes as above; no rotation of hex grid. Chunk grid and hex grid are independent (chunk origin is axis-aligned rectangle, hex cells can cross chunk boundaries in theory but math is per-fragment in local space so no explicit “hex in chunk” index).

### Ad-hoc or Pattern-Based?
Axial/cube math matches common “Red Blob Games”–style hex guides (cube_round, axial formulas). Chunk-local framing for precision is an implementation choice; no named standard.

---

## 4. Hex Grid Rendering (`rendering/terrain.gdshader`)

### Approach
Hex grid is drawn in the terrain fragment shader using SDF-based line distance in chunk-local XZ. Grid darkens and tints terrain; line thickness/softness via smoothstep on distance; steep slopes fade the grid. No separate geometry or decal for the grid in the default path (grid in shader; compositor has draw_grid_lines = false).

### Implementation Details

**SDF approach**
- **world_to_axial(local_xz, size):** (2/3*x)/size, (-1/3*x + sqrt(3)/3*z)/size. **axial_to_center(axial, size):** size*(1.5*axial.x), size*(sqrt(3)/2*axial.x + sqrt(3)*axial.y). **cube_round(c):** round then fix one component by constraint. **hex_sdf(p, apothem):** p = abs(p); max(dot(p, vec2(0.5, 0.8660254)), p.x) - apothem (pointy-top: 0 at vertex and flat edge). **hex_grid_distance(local_xz, size):** axial = world_to_axial(local_xz, size), cube = (axial.x, -axial.x-axial.y, axial.y), rounded = cube_round(cube), center = axial_to_center(rounded.x, rounded.z), p = local_xz - center, apothem = size*0.8660254, return abs(hex_sdf(p, apothem)).

**Chunk-local**
- Vertex: v_local_xz = world_pos.xz - chunk_origin_xz. Fragment uses v_local_xz and hex_size for hex_grid_distance. chunk_origin_xz is instance uniform set per MeshInstance3D in ChunkManager Phase B.

**Line thickness, softness, fading**
- bd = hex_grid_distance(v_local_xz, hex_size). aa = fwidth(bd) * hex_line_softness (hex_line_softness = 3). line_mask = 1 - smoothstep(hex_line_width - aa, hex_line_width + aa, bd) (hex_line_width = 15). Line mask multiplied by smoothstep(0.35, 0.65, n.y) for slope (fade on steep). grid_mix = min(line_mask * hex_grid_strength, 1); base_col = mix(base_col, base_col*0.55, grid_mix); base_col = mix(base_col, hex_line_color, grid_mix*0.7). ROUGHNESS increased by grid_mix*0.3.

**Star of David artifact**
- **Symptom:** Documented in PROGRESS.md and CODEBASE_AUDIT: “Star of David / triangle artifacts” in hex grid; SDF orientation and axial system not fully consistent.
- **What’s been tried:** Phase 4d report checks SDF at (0, 577.35) and (apothem, 0); conclusion that if sdf_top != 0 the SDF may be oriented for flat-top. Shader comment states pointy-top (vertices at p.y = ±radius, flat at p.x = ±apothem). PROGRESS notes “to be replaced by cell texture approach” to eliminate analytical hex math.

### Key Design Decisions
- Grid only in terrain shader (no compositor grid when draw_grid_lines = false). Single set of hex constants (hex_size, hex_line_width, hex_line_softness, hex_grid_strength, hex_line_color) in shader; camera sets hex_size and show_hex_grid.

### Dependencies
- Instance uniform chunk_origin_xz from ChunkManager. Uniforms altitude, camera_position, terrain_center_xz, terrain_radius_m, show_hex_grid, hex_size from camera via TerrainLoader’s shared material.

### Assumptions
- chunk_origin_xz matches the chunk’s world XZ corner. hex_size is pointy-top radius. Same axial/cube convention as selection.

### Ad-hoc or Pattern-Based?
SDF-based grid lines are a common trick; the exact formula and pointy-top choice are custom. No reference to a paper or library.

---

## 5. Hex Selection & Hover (`rendering/basic_camera.gd`, `core/hex_selector.gd`)

### Approach
Click: physics raycast → hit → LOD check (reject LOD ≥ 3) → chunk-local world_to_axial + cube_round → axial_to_center → hex center in world; if same as current selection clear, else HexSelector.set_selected_hex(center). Hover: same raycast every 3rd frame when overview_plane exists; hex center → compositor hovered_hex_center. HexSelector builds a physical slice mesh (top = hex-clipped grid with heights from ChunkManager height cache, walls, lift + oscillation); selection rim is drawn in screen-space compositor.

### Implementation Details

**Raycast → hex cell**
- basic_camera: project_ray_origin(screen_pos), project_ray_normal(screen_pos)*500000; PhysicsRayQueryParameters3D, collision_mask = 1; intersect_ray. Hit position → get_lod_at_world_position(hit_pos) (ChunkManager); if >= 3 show “Zoom in to select” and return. _hex_center_from_hit_chunk_local(hit_pos): get_chunk_origin_at(hit_pos.x, hit_pos.z), local_xz = hit - chunk_origin, q/r = (2/3*local_x)/hex_size and (-1/3*local_x + sqrt(3)/3*local_z)/hex_size, cube = (q, -q-r, r), rounded = _cube_round_shader(cube), center_local = hex_size*(1.5*rounded.x) and hex_size*(sqrt(3)/2*rounded.x + sqrt(3)*rounded.z), return center_local + chunk_origin. So full pipeline: screen → ray → hit → chunk origin → local → axial → round → center local → world center.

**Chunk-local selection math**
- As above: chunk_origin from ChunkManager.get_chunk_origin_at(world_x, world_z), which uses get_lod_at_world_position and then LOD 0 cell size or chunk size at that LOD to compute origin. All axial math in local space then add chunk_origin.

**Physical slice (mesh)**
- **Grid:** Rectangular grid in local XZ with step GRID_STEP_M (50); nx/nz from 2*radius/step. For each row z_local, _hex_row_intersection_x(z_local, radius) gives [left_x, right_x]. For each cell (i,j) if _is_inside_hex(x_center, z_local, radius) then sample height at world (_center_x + x_snap, _center_z + z_local) via _chunk_manager.get_height_at; x_snap = left_x or right_x for boundary columns else x_center. Vertices: (x_snap, h + SLICE_TERRAIN_OFFSET_M, z_local); color from _terrain_color(h); normals up. Triangulation: regular grid quads as two triangles (v00,v10,v01) and (v10,v11,v01) CCW from above; only where all four corners valid (grid_vertex_index >= 0). Smooth normals from triangle accumulation over top vertices only.
- **Boundary:** _build_boundary_vertices: 6 edges, each stepped at BOUNDARY_STEP_M (25), world position at each step, get_height_at for y; list of Vector3 local (x, y, z); min_terrain_y tracked.
- **Walls:** For each consecutive pair of boundary vertices, one quad: top L/R, bottom L/R (bottom = top.y - WALL_DEPTH_M, 120). Outward normal from (pt.x, 0, pt.z). Four vertices per quad, two triangles. Earth color.
- **Single ArrayMesh:** vertices, colors, normals, indices; one surface. Material: StandardMaterial3D, vertex_color_use_as_albedo, emission driven by lift_factor in _process.

**Slice animation**
- _lift_t: 0 → 1 over LIFT_DURATION_S (0.3); ease_out = 1 - (1-_lift_t)^2. position.y = ease_out * LIFT_TOP_M (150) during rise; then LIFT_TOP_M + OSCILLATION_AMP_M * sin(TAU * OSCILLATION_HZ * _selection_time) (3 m, 1 Hz). Emission enabled when lift_factor > 0.02; emission color and energy scaled by lift_factor.

**Hover**
- In _update_hex_grid_interaction(), when overview_plane exists: _hover_raycast_frame % 3 == 0 → raycast from get_mouse_position(); if result, center = _hex_center_from_hit_chunk_local(hit_pos), _hovered_hex_center = center, compositor.hovered_hex_center = center; else _hovered_hex_center = sentinel (-999999), compositor same. Debug labels and Phase 4d/F7 comparison also in this block.

### Key Design Decisions
- Slice built only from height cache (get_height_at); no mesh from terrain chunks. Reject selection on LOD ≥ 3. Rim and hover/selection visuals in compositor, not as 3D geometry.

### Dependencies
- ChunkManager (get_chunk_origin_at, get_lod_at_world_position, get_height_at). Constants HEX_RADIUS_M. basic_camera drives compositor and HexSelector via get_parent().get_node_or_null.

### Assumptions
- Height cache has the LOD 0 chunk for the selected hex; otherwise get_height_at returns -1 and slice uses 0 or boundary fallback. Pointy-top hex geometry (radius = HEX_RADIUS_M) matches shader/compositor.

### Ad-hoc or Pattern-Based?
Physical “lifted hex” slice is a custom visual. Raycast → hex center is standard strategy-game approach; chunk-local math is for consistency with shader, not from a published pattern.

---

## 6. Compositor / Screen-Space Overlay (`rendering/hex_overlay_compositor.gd`, `rendering/hex_overlay_screen.glsl`)

### Approach
CompositorEffect (PRE_TRANSPARENT) runs a compute shader that reads the depth buffer, reconstructs world position (clip → view → world via inv_projection and inv_view), works in camera-relative XZ for precision, and draws selection rim, hover highlight, and optional grid on the frontmost surface. Grid drawing is disabled (draw_grid_lines = false); terrain shader draws the grid.

### Implementation Details

**Effects**
- **Selection:** Golden rim at hex edge (rim_width = 18 * border_scale, border_scale from altitude); gold tint and emission with pulse; interior subtle darken (0.85) and gold tint; neighbors within 2*hex_size darkened (0.15 alpha). Fades: glow_fade, darken_fade, tint_fade from selection_time (0.1 s, 0.3 s, 0.2 s to reach 1).
- **Hover:** If pixel’s hex matches hovered_hex_center (axial comparison in camera-relative space), white line at edge (LINE_WIDTH/2) and slight fill (0.08 alpha). Only when not selected.
- **Grid:** When draw_grid_lines > 0.5 and show_grid and grid_fade_alpha > 0: line at hex edge (dist_from_edge < half_width), black line, 0.6 alpha. Currently draw_grid_lines is false so this branch is skipped.
- **Debug:** debug_depth: show depth in four quadrants (R/G/B/A); debug_visualization 1 = raw depth, 2 = camera-relative world XZ pattern (fract(world_xz/2000)).

**Technical**
- **Compute shader:** 8×8 workgroups; one dispatch per frame. Binding 0: color_image (rgba16f), 1: depth_texture (sampler2D), 2: Params uniform buffer. Params: inv_projection (4×4), inv_view (4×4), hex_size, show_grid, altitude, depth_ndc_flip, camera_position (vec3), time, hovered_hex_center, selected_hex_center, selection_time, debug_visualization, debug_depth, use_resolved_depth, draw_grid_lines.
- **Depth:** depth_raw from texture R channel. Sky/nothing: depth_raw >= 1 or < 1e-6 → return. depth_ndc_flip: if set, NDC z = (1 - raw)*2 - 1. reconstruct_world_position(uv, raw_depth): uv → NDC xy, NDC z from depth, clip = (ndc_xy, ndc_z, 1); view = inv_projection * clip; view.xyz /= w; world = inv_view * (view, 1).
- **Camera-relative:** world_pos from reconstruction; relative_pos = world_pos - (camera_xz.x, 0, camera_xz.y); world_xz = relative_pos.xz. Hex axial and comparisons use this world_xz; hovered/selected centers passed in world space then converted to relative: hovered_center_relative = params.hovered_hex_center - camera_xz. Axial equality with epsilon 0.01.

**draw_grid_lines = false**
- Compositor does not draw grid lines; grid comes from terrain shader. Avoids double grid and depth/unproject issues for the grid; compositor used only for selection rim, hover, and darkening.

**Communication**
- basic_camera each frame: _hex_compositor.altitude, camera_position, selection_time, selected_hex_center, show_grid, hovered_hex_center. Compositor packs these plus inv_proj/inv_view from RenderSceneData (view_projection(0), cam_transform) into Params and dispatches.

### Key Design Decisions
- One fullscreen pass; no per-chunk or per-hex passes. Camera-relative XZ to avoid precision loss at 2M+ m. Resolved or raw depth selectable (use_resolved_depth) for debugging.

### Dependencies
- RenderData, RenderSceneBuffersRD, RenderSceneData for size, depth texture, view projection, camera transform. Constants HEX_SIZE_M, GRID_DEFAULT_VISIBLE. basic_camera sets all effect properties.

### Assumptions
- Depth is reverse-Z (1 = near, 0 = far). inv_projection and inv_view correctly map clip and view to world. Hovered/selected centers in same world space as reconstruction.

### Ad-hoc or Pattern-Based?
Screen-space overlay with depth reconstruction is standard; hex-specific logic (axial in camera-relative space, rim/hover) is custom. No reference to a named post-process pattern.

---

## 7. Terrain Shader — Non-Hex Parts (`rendering/terrain.gdshader`)

### Approach
Single spatial shader: vertex passes world position, chunk-local XZ, elevation, normal, view dir; fragment does elevation-based coloring, slope blend, water, overview blend, desaturation and darkening at altitude, edge fade, distance fog, then hex grid mix on top.

### Implementation Details

**Elevation-based coloring**
- **terrain_height_color(elev):** smoothstep bands: 300±TRANSITION_M (200), 800, 1500, 2200, 3000. Colors: COLOR_LOWLAND → COLOR_FOOTHILLS → COLOR_ALPINE → COLOR_ROCK → COLOR_HIGH_ROCK → COLOR_SNOW (constants in shader, e.g. 0.18,0.32,0.12 → 0.92,0.93,0.95). Low-elev detail: terrain_low_elev_color for elev < 300: smoothstep 50±50, 150±50 for COLOR_COASTAL_LOW, COLOR_PLAINS, COLOR_LOW_HILLS; then blend to height_color between 200–400 m (smoothstep(200, 400, elev)).

**Slope**
- steep_mix = smoothstep(0.7, 0.5, n.y) (steeper = more rock). mesh_terrain_color = mix(height_col, COLOR_STEEP_ROCK, steep_mix).

**Water**
- v_elevation < WATER_ELEVATION_M (5): mesh_terrain_color = mix(water_low, water_high, smoothstep(100000, 1000000, length(camera_position))).

**Overview texture**
- overview_blend = use_overview ? smoothstep(15000, 180000, altitude) : 0. So 15 km → 0, 180 km → 1; linear in between. overview_uv = (v_world_pos.xz - overview_origin) / overview_size; clamped 0–1. base_col = mix(mesh_terrain_color, overview_col, overview_blend).

**Fog**
- fog_color = mix(ground_fog_color, space_color, smoothstep(200000, 1200000, altitude)). fog_end_actual = altitude < 100000 ? 800000 : max(1200000, altitude*4). fog_start = mix(50000, 250000, smoothstep(100000, 600000, altitude)). fog_factor = smoothstep(fog_start, fog_end_actual, dist). base_col = mix(base_col, fog_color, fog_factor).

**Desaturation at altitude**
- desat = 0.3 * smoothstep(100000, 500000, altitude). base_col = mix(base_col, luminance(base_col), desat). base_col *= mix(1, 0.8, smoothstep(500000, 2000000, altitude)).

**Edge fade**
- dist_from_center = length(v_world_pos.xz - terrain_center_xz). edge_fade_width = 80000. edge_fade = smoothstep(terrain_radius_m - edge_fade_width, terrain_radius_m, dist_from_center). base_col = mix(base_col, fog_color, edge_fade).

**Constants**
- All color and elevation thresholds are hardcoded in the shader (TRANSITION_M = 200, LOW_ELEV_BLEND_M = 50, WATER_ELEVATION_M = 5, etc.). terrain_center_xz and terrain_radius_m come from camera; overview_origin/size and use_overview from TerrainLoader.

### Key Design Decisions
- One shader for all terrain (elevation, slope, water, overview, fog, edge, grid). Overview blend purely by altitude; no separate “macro mode” flag.

### Dependencies
- Uniforms from TerrainLoader (overview_texture, overview_origin/size, use_overview, albedo, roughness, etc.) and from camera (altitude, camera_position, terrain_center_xz, terrain_radius_m, show_hex_grid, hex_size). ChunkManager sets chunk_origin_xz per instance.

### Assumptions
- World Y = elevation. terrain_center_xz and terrain_radius_m describe a circular region for edge fade. Overview texture covers same extent as chunk grid (set in TerrainLoader).

### Ad-hoc or Pattern-Based?
Standard elevation bands and fog; exact thresholds and colors are project-specific. No reference to a terrain shader standard.

---

## 8. Python Pipeline (`tools/process_terrain.py`)

### Approach
CLI: load region from regions.json, download or use cached SRTM tiles, merge to master heightmap (optionally at 90 m in one pass), fill voids, normalize to uint16 (sea level = SEA_LEVEL_UINT16), save master PNG, generate LOD pyramid (2× box downsample per level), chunk each LOD into 512×512 PNGs, generate overview texture from master with elevation coloring, write terrain_metadata.json.

### Implementation Details

**End-to-end**
- TerrainProcessor(region_config, output_dir, cache_dir). run(): (1) download + merge (SRTM3: _download_and_merge_srtm3 one tile at a time; SRTM1: _download_tiles then _merge_tiles); (2) _fill_voids (nearest-neighbor iterative + Gaussian on filled); (3) _normalize to uint16; (4) _save_png_16bit(master); (5) _generate_lods_and_chunk (LOD 0..4, each level chunked then downsampled for next); (6b) _generate_overview_texture(normalized); (7) _generate_metadata. Optional run_overview_only(): load master, overview only, update metadata.

**SRTM acquisition and merge**
- _get_tile(lat, lon): filename N/Snn E/Wnnn.hgt; cache in cache_dir; else _download_hgt from AWS S3 (elevation-tiles-prod, skadi, gzipped). _read_hgt: big-endian int16 3601×3601 (SRTM_TILE_SIZE). For SRTM3: _download_and_merge_srtm3 allocates merged at 90 m (px_per_degree = 1200), iterates lat/lon, gets tile, tile[::3,::3] to 1201×1201, places in merged by lat/lon offsets. For SRTM1: _merge_tiles same placement logic at 30 m or 90 m depending on downsample_3x.

**Chunk generation**
- _generate_lods_and_chunk: current_lod = master; for lod 0..4: _chunk_lod(current_lod, lod, lod_dir) writes 512×512 PNGs, chunks_info; then current_lod = _downsample(current_lod) (2×2 box average, pad if odd). _chunk_lod: num_chunks_xy = ceil(size/512); for each chunk extract region, pad to 512×512 if needed, _save_png_16bit, append {lod, x, y, path}.

**Overview texture**
- _generate_overview_texture(master): target 4096 width, aspect from master; stride-sample master to overview size; elev_m from uint16 same formula as loader (SEA_LEVEL_UINT16, max_elevation_m); RGB from elevation bands (water < 5 m, then coastal/plains/low hills/lowland/foothills/alpine/rock/high_rock/snow with TRANSITION_M 200, LOW_ELEV_BLEND_M 50); save overview_texture.png; return dict with overview_texture, overview_width_px, overview_height_px, overview_world_width_m, overview_world_height_m (grid_w/h * 512 * resolution_m).

**Metadata**
- terrain_metadata.json: region_name, bounding_box, resolution_m, max_elevation_m, chunk_size_px, lod_levels, total_chunks, master_heightmap_width/height, chunks (list of {lod, x, y, path}), and if overview: overview_texture, overview_width_px, overview_height_px, overview_world_width_m, overview_world_height_m.

**Regions**
- regions.json: parser expects regions[region_name]; region_config has display_name, bounding_box (lat_min/max, lon_min/max), max_elevation_m, resolution ('srtm1' or 'srtm3'). resolution_m = 90 if srtm3 else 30; for very large regions with srtm3, downsample_3x forced true.

### Key Design Decisions
- Single Python script; no plugin or external LOD library. Chunk layout and LOD pyramid match engine expectations (512 px, 5 LODs, 2× downsample). Overview coloring mirrors shader constants (manually kept in sync).

### Dependencies
- numpy, Pillow; regions.json; optional cache dir for .hgt files. AWS S3 for SRTM (no auth).

### Assumptions
- SRTM tiles 3601×3601 (or 1201 for 90 m); big-endian int16; -32768 = nodata. Region bbox in degrees. Output dir writable; engine reads same paths and resolution/chunk_size.

### Ad-hoc or Pattern-Based?
Standard “download tiles → merge → normalize → tile” pipeline; LOD and overview design are tailored to this engine. No reference to a standard (e.g. Cesium, GDAL workflow).

---

## 9. Scene Structure (`scenes/terrain_demo.tscn`)

### Approach
Single root Node3D (TerrainDemo) with TerrainLoader, ChunkManager, HexSelector, Camera3D, lights, WorldEnvironment, UI layers. No compositor or HexGridMesh in the scene file; compositor is created at runtime by the camera. Discovery is by sibling/parent get_node and groups.

### Implementation Details

**Node tree**
- TerrainDemo (Node3D)
  - ProfilingDriver (Node), DiagnosticCameraDriver (Node)
  - TerrainLoader (Node) — script terrain_loader.gd, DEBUG_HEX_GRID = true
  - ChunkManager (Node3D) — script chunk_manager.gd
  - HexSelector (Node3D) — script hex_selector.gd
  - Camera3D — script basic_camera.gd, DEBUG_DIAGNOSTIC = true
  - DirectionalLight3D
  - WorldEnvironment — environment only (no compositor in .tscn)
  - FPSCounter (CanvasLayer) — Label with fps_counter.gd
  - LoadingScreen (CanvasLayer) — loading_screen.gd, Panel, VBoxContainer, StatusLabel, ProgressBar

**Initialization order**
- _ready order is scene tree order: TerrainLoader _ready first (load metadata, create shared materials, add to group "terrain_loader"). ChunkManager _ready (needs TerrainLoader sibling, waits 2 process_frame, gets camera from viewport, gets LoadingScreen from /root/TerrainDemo or /root/Node3D, _setup_overview_plane, creates chunks_container and collision_body, then _initial_load which fills initial_desired and load_queue and sets initial_load_in_progress). HexSelector _ready (gets ChunkManager from parent). Camera _ready (far/near, load metadata, set target_position and orbit from metadata or fallback, _update_camera_transform). No explicit “init” signals; ChunkManager does not wait for camera _ready, but it gets camera in _ready after two frames. WorldEnvironment has no script; compositor is created on first _update_hex_grid_interaction when camera calls _ensure_hex_compositor (get_parent().get_node("WorldEnvironment"), get or create Compositor, append HexOverlayCompositor effect).

**Discovery**
- **Groups:** terrain_loader (TerrainLoader), terrain_chunks (each MeshInstance3D chunk in ChunkManager), overview_plane (overview MeshInstance3D). ChunkManager finds TerrainLoader via get_node("../TerrainLoader"). Camera finds TerrainLoader with get_tree().get_first_node_in_group("terrain_loader"), ChunkManager with get_parent().get_node_or_null("ChunkManager"), HexSelector with get_parent().get_node_or_null("HexSelector"), WorldEnvironment with get_parent().get_node_or_null("WorldEnvironment"). HexSelector finds ChunkManager with get_parent().get_node_or_null("ChunkManager"). LoadingScreen by path /root/TerrainDemo/LoadingScreen or /root/Node3D/LoadingScreen. No signals for “terrain ready” or “chunks ready”; ChunkManager sets initial_load_complete when initial_desired is fully loaded and then hides loading screen.

### Key Design Decisions
- All core systems under one root; camera and ChunkManager assume same parent. Compositor and HexGridMesh (if used) are not in scene; camera creates compositor and could drive a decal if present.

### Dependencies
- Scene must have TerrainLoader, ChunkManager, HexSelector, Camera3D, WorldEnvironment under same parent for node paths. LoadingScreen path hardcoded.

### Assumptions
- Root is TerrainDemo or Node3D for LoadingScreen. No multi-scene or sub-viewport; one main camera. First camera in viewport is used by ChunkManager.

### Ad-hoc or Pattern-Based?
Flat hierarchy and node-path discovery are typical in Godot; no formal “service locator” or dependency injection. Groups used for material/chunk lookup.

---

## 10. Constants & Configuration (`config/constants.gd`)

### Approach
Single autoload (or preload) class `Constants` with const declarations for data, chunks, LOD, streaming, hex, geography, camera, micro terrain, transitions, selection visuals, raycast, grid visibility, performance, UI, overlay, paths, and debug. Scripts preload or use the class name; shaders receive values via uniforms set by GDScript (no direct constant file in shaders).

### Implementation Details

**All constants (by category)**
- **Data / heightmap:** RESOLUTION_M (90), HEIGHT_BIT_DEPTH (65535), SEA_LEVEL_M (0), SEA_LEVEL_UINT16 (1000).
- **Chunks:** CHUNK_SIZE_PX (512), CHUNK_SIZE_M (46080), CHUNK_POOL_SIZE (100), TARGET_LOADED_CHUNKS (49).
- **LOD:** LOD_LEVELS (5), LOD_RESOLUTIONS_M array (90,180,360,720,1440), LOD_DISTANCES_M (0, 50k, 75k, 200k, 500k), LOD_HYSTERESIS (0.1), INNER_RADIUS_M (500000), VISIBLE_RADIUS_ALTITUDE_FACTOR (2.5).
- **Streaming:** LOAD_RADIUS_CHUNKS (3), UNLOAD_DISTANCE_CHUNKS (5), MAX_CONCURRENT_LOADS (4), UNLOAD_CHECK_INTERVAL_S (0.5), MEMORY_BUDGET_BYTES (2G).
- **Hex:** HEX_SIZE_M (1000), HEX_WIDTH_M (1000), HEX_HEIGHT_M (866.025), HEX_RADIUS_M (1000/sqrt(3)), HEX_VERTICES (7).
- **Geographic:** EARTH_RADIUS_M (6371000).
- **Camera macro:** CAMERA_MIN_ALTITUDE_M (5000), CAMERA_MAX_ALTITUDE_M (5e6), CAMERA_BOUNDS_MARGIN_M (50k), CAMERA_SPEED_FACTOR (100), CAMERA_PITCH_MIN/MAX_DEG (30, 80), CAMERA_ROTATE_STEP_DEG (15), CAMERA_ZOOM_LEVELS (10), CAMERA_EDGE_SCROLL_MARGIN_PX (10).
- **Camera micro:** MICRO_CAMERA_ALTITUDE_M (500), MICRO_CAMERA_PITCH_DEG (45), MICRO_CAMERA_BOUNDS_HEXES (3).
- **Micro terrain:** MICRO_RESOLUTION_M (10), MICRO_NOISE_AMPLITUDE_M (5), MICRO_NOISE_FREQUENCY (0.01), MICRO_NOISE_OCTAVES (3), MICRO_COVERAGE_RINGS (1), MICRO_EDGE_BLEND_M (50), MICRO_MESH_GEN_TARGET_MS (200).
- **View transition:** TRANSITION_DURATION_S (1.5), TRANSITION_FADE_OUT/IN_S (0.3).
- **Hex selection visuals:** HEX_SELECTED_COLOR, HEX_HOVERED_COLOR, HEX_HOVERED_OUTLINE_PX (3), HEX_GRID_COLOR, HEX_GRID_LINE_PX (2), HEX_SELECTION_PULSE_S (0.5).
- **Raycast:** TERRAIN_PHYSICS_LAYER (10), RAYCAST_MAX_DISTANCE_M (10000).
- **Grid visibility:** GRID_FADE_START_M (5000), GRID_FADE_END_M (20000), GRID_DEFAULT_VISIBLE (true).
- **Performance:** TARGET_FPS (30), IDEAL_FPS (60), FPS_DEGRADE_THRESHOLD (30), FPS_DEGRADE_DURATION_S (3), FPS_RECOVERY_*, FPS_DEGRADE_LOD_INCREASE (0.2), TARGET/IDEAL_FRAME_TIME_MS, CHUNK_LOAD_TARGET_MS (100).
- **UI:** MINIMAP_SIZE_PX (200), NOTIFICATION_FADE_S (3), ERROR_NOTIFICATION_S (5), UI_SCALE_OPTIONS.
- **Overlay:** OVERLAY_OPACITY_DEFAULT/STEP/MIN/MAX.
- **Paths:** TERRAIN_DATA_PATH, CHUNK_PATH_PATTERN, METADATA_PATH, REGIONS_CONFIG_PATH, SETTINGS_PATH, LOG_PATH.
- **Debug:** DEBUG_OVERLAY_KEY ("F3"), CHUNK_VISUALIZER_KEY ("F4"), ERROR_TILE_COLOR.

**Which systems use which**
- **ChunkManager:** _Const preload for LOD_DISTANCES_M, INNER_RADIUS_M, VISIBLE_RADIUS_ALTITUDE_FACTOR; TERRAIN_DATA_PATH in overview path. Resolution/grid from metadata, not constants.
- **TerrainLoader:** TERRAIN_DATA_PATH, SEA_LEVEL_UINT16.
- **TerrainWorker:** SEA_LEVEL_UINT16.
- **basic_camera:** HEX_SIZE_M, HEX_RADIUS_M, GRID_DEFAULT_VISIBLE, CHUNK_SIZE_PX, RESOLUTION_M (Phase 4d).
- **hex_selector:** HEX_RADIUS_M.
- **hex_overlay_compositor:** HEX_SIZE_M, GRID_DEFAULT_VISIBLE.
- **hex_grid_mesh:** HEX_SIZE_M.
- **Shaders:** No direct constants.gd; terrain shader gets hex_size, show_hex_grid, etc. from camera; compositor GLSL has its own LINE_WIDTH, GRID_FADE_*, etc.

**Unused or redundant**
- CHUNK_POOL_SIZE, TARGET_LOADED_CHUNKS: ChunkManager does not use these; it uses its own MAX_CONCURRENT_ASYNC_LOADS_* and desired set. LOAD_RADIUS_CHUNKS, UNLOAD_DISTANCE_CHUNKS, UNLOAD_CHECK_INTERVAL_S: ChunkManager uses INNER_RADIUS_M and its own UPDATE_INTERVAL_*. TERRAIN_PHYSICS_LAYER (10): engine uses collision_mask = 1 in raycasts, not 10. CAMERA_ZOOM_LEVELS: camera uses continuous zoom. MICRO_* and TRANSITION_*: no clear use in current terrain_demo flow. LOD_RESOLUTIONS_M: TerrainLoader uses its own LOD_MESH_RESOLUTION array; resolution_m from metadata.

**How constants reach shaders**
- Only via GDScript setting shader parameters: basic_camera sets terrain material hex_size = Constants.HEX_SIZE_M/sqrt(3), show_hex_grid = _grid_visible (from Constants.GRID_DEFAULT_VISIBLE). TerrainLoader sets overview_origin/size, use_overview, albedo, roughness. ChunkManager sets chunk_origin_xz per instance. Compositor packs hex_size, show_grid, etc. into Params buffer from its export/var (initialized from Constants). No constants.gd in shader code.

### Key Design Decisions
- One file for all tunables; some duplication with ChunkManager (LOD distances, update interval) and TerrainLoader (resolution, mesh resolution). Camera zoom and physics layer don’t use all constants.

### Dependencies
- None; other systems depend on it via preload or global class name.

### Assumptions
- Autoload or preload so "Constants" or preload("res://config/constants.gd") is available. Shaders assume script sets uniforms; no fallback in shader for missing values.

### Ad-hoc or Pattern-Based?
Central constants file is common; this one mixes many domains (LOD, camera, hex, UI, performance). Not all entries are used; pattern is “single source of truth” but some consumers use local or metadata values instead.
