# GeoStrategy Engine — Codebase Audit Report

**Date:** February 15, 2026  
**Scope:** Read-only audit. No code was modified.  
**Purpose:** Complete picture of current state before further fixes.

---

## Section 1: File Inventory

For every file in the project (code, shaders, scenes, resources, data):

| File | Lines | Purpose (1 sentence) | Status | Notes |
|------|-------|------------------------|--------|-------|
| `core/chunk_manager.gd` | 1318 | Drives terrain streaming: desired set, async load queue, Phase B micro-steps, visibility, deferred unload. | Working | Central orchestrator; DEBUG_STREAMING_TIMING, DEBUG_DIAGNOSTIC. |
| `core/terrain_loader.gd` | 957 | Stateless chunk loading: 16-bit PNG decode, LOD mesh/collision, shared terrain material + hex next_pass, height cache. | Working | Phase A/B split; DEBUG_CHUNK_TIMING, DEBUG_HEX_GRID. |
| `core/terrain_worker.gd` | 291 | Static Phase A worker: PNG decode + mesh arrays on WorkerThreadPool; no node refs. | Working | Used via Callable(TerrainWorker, "compute_chunk_data").bind(args). |
| `core/hex_selector.gd` | 396 | Physical hex slice: build mesh from height cache, walls/rim, lift + oscillation, cutout alignment. | Fragile | Depends on get_height_at; >20% cache miss → warning; rim is LINE_STRIP. |
| `rendering/terrain.gdshader` | 127 | Terrain only: elevation/slope color, water, overview blend, fog, desaturation, edge fade. | Working | depth_draw_opaque; no hex logic. |
| `rendering/hex_grid.gdshader` | 176 | Hex overlay (next_pass): grid lines, hover, selection cutout/border/glow/darken; depth_test_disabled. | Working | blend_mix; alpha only where grid/hover/selection. |
| `rendering/basic_camera.gd` | 612 | Orbital camera: WASD, zoom, orbit, terrain clearance, hex hover/selection, terrain/hex material uniforms. | Working | DEBUG_DIAGNOSTIC; updates shared material from first chunk in group. |
| `config/constants.gd` | 174 | Central constants: LOD, hex, paths, camera, grid fade, etc. | Working | Single source of truth; some values duplicated in chunk_manager (LOD distances). |
| `scenes/terrain_demo.tscn` | 99 | Main scene: TerrainLoader, ChunkManager, HexSelector, Camera3D, LoadingScreen, FPS, ProfilingDriver, DiagnosticDriver. | Working | Entry point; DEBUG flags set in scene (e.g. Camera DEBUG_DIAGNOSTIC true). |
| `node_3d.tscn` | 37 | Minimal scene: TerrainLoader, ChunkManager, Camera3D, light, env; no LoadingScreen/HexSelector. | Unknown | Alternate/minimal run; may miss refs. |
| `ui/loading_screen.gd` | 44 | Shows progress bar during initial chunk load; hide_loading when initial load complete. | Working | Progress bar max_value = total from ChunkManager. |
| `ui/fps_counter.gd` | 43 | Label: FPS, rolling avg, 1% low, draw calls; [PERF] if 1% low < 60. | Working | Reads ChunkManager._last_phase_b_ms for warning. |
| `data/terrain/terrain_metadata.json` | ~91583 | Region metadata: bounding_box, resolution_m, max_elevation_m, chunk list, overview_texture. | Working | Very large (chunks array); used by TerrainLoader, ChunkManager, camera. |
| `config/regions.json` | ~25 | Region definitions (alps_test, europe) for process_terrain.py. | Working | Not loaded by engine at runtime. |
| `tools/process_terrain.py` | 509 | Python CLI: download SRTM, merge, LOD/chunk, overview texture, terrain_metadata.json. | Working | Requires numpy, Pillow; cache in tools/cache. |
| `tools/diagnostic_camera_driver.gd` | 298 | Automated camera sequence: zoom out/in, pan, orbit, region jump; logs [DIAG] and phase summaries. | Working | @export enabled = false; uses get_diagnostic_snapshot(). |
| `tools/profiling_camera_driver.gd` | 117 | Stress-test: pan, zoom in/out, fast pan; then quit. For [TIME] / streaming analysis. | Working | @export enabled = false; uses initial_load_complete. |
| `rendering/overview.gdshader` | 46 | Standalone overview plane shader (fog, desat, edge fade). | Dead code | PROGRESS.md says "Removed"; file still present; ChunkManager uses StandardMaterial3D for overview plane. |
| `rendering/hex_overlay.gdshader` | 154 | Older hex overlay (v_is_selected varying, different uniforms). | Dead code | PROGRESS.md says "Removed"; replaced by hex_grid.gdshader as next_pass. |
| `docs/PROGRESS.md` | 259 | Progress tracker, session notes, backlog, architecture vision. | Working | Documentation only. |
| `.vscode/settings.json` | — | Editor settings. | — | Not part of engine logic. |

**Summary:** 2 dead shader files (overview.gdshader, hex_overlay.gdshader) still on disk; 1 minimal scene (node_3d.tscn) with unknown usage; rest are in use and either Working or Fragile.

---

## Section 2: System Architecture (Actual, Not Planned)

### 2.1 Terrain Streaming Pipeline

- **Desired set:** `_determine_desired_chunks(camera_pos)` in chunk_manager.gd. Inner ring: LOD 0 cells within `INNER_RADIUS_M` (500 km), per-cell LOD from `_select_lod_with_hysteresis` using `LOD_DISTANCES_M` and altitude (above 70 km → no LOD 0). Outer ring: LOD 4 only from 500 km to `visible_radius` (max(500 km, altitude × 2.5)). Then `_expand_lod0_to_full_blocks(desired)` adds sibling chunks so every LOD 0–3 chunk is in a complete 2×2 block (so coarse parent can be hidden when all 4 children are loaded).
- **Loading:** Phase A: `terrain_loader.start_async_load(x, y, lod)` submits `TerrainWorker.compute_chunk_data` to WorkerThreadPool; result (vertices, normals, indices, height_data, etc.) stored in args["result"]. Phase B on main thread: `_drain_completed_async_to_phase_b()` moves completed tasks into `_pending_phase_b`. Each entry has step 0=MESH, 1=SCENE, 2=COLLISION. `_do_one_phase_b_step()` does one step per call: step 0 → `finish_load_step_mesh`, step 1 → `finish_load_step_scene` (create MeshInstance3D, add to chunks_container, scale tween 0.97→1), step 2 → `finish_load_step_collision` then pop and register in `loaded_chunks`. Up to 4 (or 8 if queue > 20) async loads in flight; one new load submitted per frame in `_process` when queue has work. Phase B runs with 8 ms frame budget (16 ms during initial load), minimum 1 step per frame when pending (3 when alt < 15 km and backlog > 2).
- **Unloading:** Chunks in `loaded_chunks` but not in `desired` become unload candidates. Deferred unload: a chunk is unloaded only if (a) its LOD 0 cells are all covered by finer *loaded* chunks, or (b) deferred timeout (5 s normal, 1 s after large move >200 km). Immediate unload when camera jumped and chunk is beyond 1.5× visible radius. Burst unloads (>10) are spread across frames via `_pending_unload_keys`.
- **LOD decisions:** Per LOD 0 cell: distance-based LOD from `LOD_DISTANCES_M` (0–50 km LOD 0, 50–75 km LOD 1, …), with hysteresis (downgrade only after 10% buffer). Altitude gate: above 70 km, base_lod 0 is forced to 1.
- **Chunk visibility:** `_update_chunk_visibility()` runs after each `_update_chunks()`. For each loaded chunk: LOD 0 always visible; LOD > 0 hidden iff all four finer children (at LOD-1, 2×2 sub-chunks) exist in `loaded_chunks`. So multiple LODs can be in `loaded_chunks` but only the finest covering each area is shown.
- **Uniforms flow:** Camera does not push uniforms to ChunkManager or TerrainLoader. Camera in `_update_hex_grid_interaction()` gets terrain material via `get_first_node_in_group("terrain_chunks")` → get_surface_override_material(0), and hex material as terrain_material.next_pass. Camera sets on terrain: altitude, camera_position, terrain_center_xz, terrain_radius_m. On hex: altitude, selection_time, selected_hex_center; hovered_hex_center set from raycast. TerrainLoader sets terrain material defaults and overview_texture/origin/size in _ready; ChunkManager only creates overview plane and chunk nodes that use the shared material.

### 2.2 Terrain Rendering

- **Terrain shader (terrain.gdshader):** Vertex: world position, elevation (VERTEX.y), world normal. Fragment: if elevation < 5 m → water color (blue gradient by camera distance); else height-based terrain color (terrain_height_color + terrain_low_elev_color for <300 m), then steep slope mix with COLOR_STEEP_ROCK (n.y < 0.5). Overview: if use_overview, sample overview_texture at (world_xz - overview_origin) / overview_size, blend with mesh color by altitude (smoothstep 15–180 km). Then desaturation by altitude, edge fade (dist to terrain_center_xz vs terrain_radius_m), distance fog (fog_start/fog_end_actual, fog_color). Outputs ALBEDO, ROUGHNESS, METALLIC, RIM, RIM_TINT; EMISSION = 0.
- **Render mode:** blend_mix, depth_draw_opaque, cull_back. So terrain writes depth and is opaque.
- **Uniforms set by:** TerrainLoader _ready (albedo, roughness, overview_texture, overview_origin, overview_size, use_overview). Camera every frame (altitude, camera_position, terrain_center_xz, terrain_radius_m).
- **Overview texture:** Loaded in TerrainLoader from metadata overview_texture path; dimensions from grid × 512 × resolution_m. Same extent as chunk grid so UV aligns.
- **Overview plane (safety net):** ChunkManager `_setup_overview_plane()`: if metadata has overview_texture, creates a quad mesh (0,0,0) to (overview_w, 0, overview_h), Y = -20, StandardMaterial3D unshaded with albedo_texture = same overview image. Fills gaps where no chunk exists at high zoom.

### 2.3 Hex Grid Overlay

- **Setup:** TerrainLoader creates shared_terrain_material (terrain.gdshader), then creates hex_material (hex_grid.gdshader), sets hex_material as shader_material.next_pass. So every chunk using shared_terrain_material draws terrain then the same hex overlay pass.
- **Hex shader uniforms:** hex_size, show_grid, grid_fade_start, grid_fade_end, altitude, hovered_hex_center, selected_hex_center, selection_time. Set by TerrainLoader (_ready) for size/fade; by Camera for altitude, hover, selection, selection_time, show_grid (F1).
- **Grid lines:** world_to_axial / axial_round / hex_dist; dist_from_edge < half LINE_WIDTH → black line, alpha 0.6 × grid_fade_alpha (fade by altitude between grid_fade_start and grid_fade_end).
- **Hover:** Raycast every 3rd frame in camera; hit position → axial hex center; hex_mat.set_shader_parameter("hovered_hex_center", center). Shader: is_hovered → white border + alpha max 0.08.
- **Selection:** Left click → raycast → hex center; if same as current selection → clear (HexSelector.clear_selection, selected_hex_center = sentinel); else set_selected_hex(center), selected_hex_center = center, selection_time = 0. HexSelector builds slice mesh, adds slice node. Camera updates selected_hex_center and selection_time on hex material.
- **Cutout/shadow:** In fragment, inside_cutout = (dist_from_sel_center <= hex_radius + CUTOUT_MARGIN_M). If inside_cutout → dark albedo + alpha 0.95×tint_fade. Selection also draws golden border/glow inside hex and surrounding darken for nearby hexes.

### 2.4 Hex Slice (Physical Selection)

- **Height data:** HexSelector calls `_chunk_manager.get_height_at(world_x, world_z)`. ChunkManager forwards to `terrain_loader.get_height_at(world_x, world_z)`. TerrainLoader: chunk key from world XZ (LOD 0 chunk index), path = lod0 chunk PNG path; if path not in _height_cache returns -1. Else bilinear interpolate from cache. Height cache is filled when async load completes (ChunkManager passes heights_for_cache/path_for_cache to terrain_loader._add_to_height_cache).
- **Slice mesh:** `_build_slice_mesh()`: boundary vertices from 6 hex edges (BOUNDARY_STEP_M 25 m), heights from get_height_at (fallback 0 if -1). Rectangular grid clipped to hex (GRID_STEP_M 50 m), row intersection with hex for left/right X; only vertices inside hex; height at each grid point from get_height_at. Top surface triangulation (CCW), then _compute_grid_normals for top only. Walls: consecutive boundary segments, quads (top/bottom), earth color. Single ArrayMesh with ARRAY_VERTEX, COLOR, NORMAL, INDEX. Golden rim: _build_golden_rim_mesh() — 6 corner positions + height at each, LINE_STRIP with emissive material, child of slice_instance.
- **Animation:** _process: _lift_t < 1 → ease-out to 1 over LIFT_DURATION_S, position.y = ease_out * LIFT_TOP_M; else position.y = LIFT_TOP_M + OSCILLATION_AMP_M * sin(TAU * OSCILLATION_HZ * _selection_time). Material emission driven by lift factor.
- **Deselection:** clear_selection() → slice_instance.queue_free(), _slice_instance = null, _slice_mesh = null.

### 2.5 Camera System

- **Movement:** WASD → _pan(direction, delta); speed = pan_speed * (orbit_distance/1000), × speed_boost if Space. Forward/right from basis, target_position += movement. Zoom: scroll → _zoom(direction); target_orbit_distance *= (1 ± 0.15), clamped 500–5,000,000 m. Orbit: middle mouse drag → orbit_yaw, orbit_pitch (clamped 10–89). _update_camera_transform(): position = target + spherical offset; raycast down for terrain height; if position.y < terrain_height + min_camera_clearance, push camera up and adjust orbit_distance.
- **Altitude:** orbit_distance (or position.y fallback) passed to shaders as altitude. Far plane: if orbit_distance > 1,000,000 then far = 10,000,000 else 2,000,000.
- **Hover raycast:** In _update_hex_grid_interaction(), every 3rd frame (_hover_raycast_frame % 3 == 0): ray from camera through mouse; intersect collision_mask 1; hit → hex center from axial round; set hovered_hex_center on hex material. Miss → hovered_hex_center = (999999, 999999).
- **Selection/deselection:** Left click → _handle_hex_selection_click. Raycast; if hit, get_lod_at_world_position(hit_pos); if LOD ≥ 3 show "Zoom in to select" and return. Else compute hex center; if same as _selected_hex_center → clear (HexSelector.clear_selection, sentinel); else set_selected_hex(center). Then _update_hex_selection_uniform() (selected_hex_center, selection_time). _selection_time += delta in _process.
- **Uniform updates per frame:** _update_hex_grid_interaction() sets terrain material (altitude, camera_position, terrain_center_xz, terrain_radius_m) and hex material (altitude, selection_time, selected_hex_center, and hovered_hex_center when raycast runs).

---

## Section 3: Known Bugs (Verified by Code Reading)

### 3.1 Multiple hex grids visible simultaneously

- **Symptom:** Multiple terrain chunks covering the same area are visible at once, so the hex overlay (next_pass on the shared material) draws on each visible chunk and the grid appears duplicated.
- **Root cause (code):**  
  - **Visibility logic:** In `_update_chunk_visibility()` (chunk_manager.gd 558–569), a non–LOD 0 chunk is hidden only if all four finer children exist in `loaded_chunks`. So if the desired set has both a coarse chunk and one or more of its children, the coarse chunk stays visible until all four children are *loaded*. During loading, e.g. one LOD 1 chunk and two LOD 0 chunks may be visible for the same area.  
  - **Expand LOD 0 to full blocks:** `_expand_lod0_to_full_blocks(desired)` (chunk_manager.gd 663–699) only ensures that for each LOD 0–3 chunk in desired, the other three siblings of its 2×2 block are *in the desired set*. It does not remove or hide coarser LODs from the desired set; it only adds missing siblings so that when all are loaded, the parent can be hidden. So the desired set can still contain both a parent (e.g. LOD 2) and its children (LOD 1/0).  
  - **Race:** When a chunk is added in _do_one_phase_b_step (step 2), it is added to loaded_chunks and the scene in the same frame. _update_chunk_visibility() is called at the end of _update_chunks(), which runs on the timer (every 0.25–0.5 s). So there is a window where a new chunk is visible and its parent has not yet been hidden because visibility is not re-evaluated until the next _update_chunks().  
  - **Overlay duplication:** The hex overlay is next_pass on the *shared* material. Every MeshInstance3D that uses that material draws the same overlay. So if two chunk meshes covering the same screen area are visible (e.g. one LOD 1 and one LOD 0 overlapping), the overlay is drawn twice for that area. There is no per-chunk or per-region switch to disable the overlay on coarser chunks; visibility is by chunk_node.visible, and both can be true.
- **Where:** chunk_manager.gd: _update_chunk_visibility() 558–569; _expand_lod0_to_full_blocks 673–668; _update_chunks() calls _update_chunk_visibility() at line 569; _do_one_phase_b_step 417–428.
- **Fix (brief):** (1) Call _update_chunk_visibility() immediately after adding a chunk in Phase B (and optionally once per frame when load_queue or _pending_phase_b is non-empty) so visibility updates as soon as children exist. (2) Optionally, in desired set computation, when a 2×2 block of finer LOD is complete in desired, do not request the parent (so coarse chunk is never loaded for that area); or keep current load logic but ensure visibility is updated every frame while streaming. (3) To avoid double overlay when two LODs are visible: either use a single full-screen hex pass instead of next_pass per chunk, or mark overlay draw only for the “primary” LOD per region (e.g. finest LOD covering camera).
- **Risk of fix:** Changing desired set to omit parents when children are present could change load order and memory; per-frame visibility may add cost; single overlay pass would require architectural change.

### 3.2 Terrain looks transparent / hex grid shows through terrain

- **Symptom:** Terrain appears transparent or the hex grid is visible “through” the terrain.
- **Root cause (code):**  
  - **Terrain shader:** terrain.gdshader has `render_mode blend_mix, depth_draw_opaque`. So terrain writes depth and is opaque; it does not use alpha.  
  - **Hex overlay:** hex_grid.gdshader has `depth_draw_never, depth_test_disabled`. So the overlay does not read or write depth; it draws on top of whatever was drawn before, in blend_mix.  
  - **Hex fragment alpha:** In hex_grid.gdshader fragment(), `albedo` and `alpha` start at 0. They are set only when: (1) show_grid && grid line (alpha max 0.6×line_alpha), (2) is_hovered (alpha max 0.08 and line alpha), (3) has_selection: inside_cutout (alpha up to 0.95×tint_fade), is_selected (golden tint/border/glow alpha), or !is_selected nearby (alpha 0.15×darken_fade). So for pixels with no grid, no hover, no selection: alpha remains 0. ALPHA = alpha is written at line 174. So “empty” overlay pixels have alpha 0. With blend_mix, that should not tint the terrain.  
  - **Possible causes if bug persists:** (1) Driver or Godot version treating alpha or blend differently. (2) Order of draws: if overlay is drawn before terrain for some chunks, terrain would draw on top; but next_pass runs after main pass for the same mesh, so terrain draws first. (3) If there is a second camera or viewport, or if terrain_chunks group returns a chunk that doesn’t use the shared material, wrong material could be updated. (4) Default shader ALPHA: in Godot, if the shader doesn’t set ALPHA, it may default to 1.0; this shader sets ALPHA = alpha (0 where no overlay). So by code, empty overlay areas should be fully transparent.
- **Where:** rendering/terrain.gdshader line 2 (depth_draw_opaque); rendering/hex_grid.gdshader lines 2, 76–175 (alpha only set for grid/hover/selection), 174 (ALPHA = alpha).
- **Fix (brief):** Ensure ALPHA is explicitly 0 when no overlay effect (already done). If bug reproduces, verify render order and that all terrain chunks use the same material; add explicit ALPHA = 0 at start of fragment and only raise where needed.
- **Risk of fix:** Low.

### 3.3 Hex slice appearance

- **Mesh building / triangulation:** In hex_selector.gd, top surface uses a rectangular grid clipped to hex; indices for each quad as (v00, v10, v01) and (v10, v11, v01). CCW from above. Wall quads: indices [v0_top, v0_top+1, v0_top+3, v0_top, v0_top+3, v0_top+2] — two triangles for quad top-left, bottom-left, bottom-right, top-right. Winding is consistent (CCW from outside per normal). Normals: top from _compute_grid_normals (face accumulation, normalized); walls use outwards vector from (pt.x, 0, pt.z). So triangulation and winding are consistent.
- **get_height_at(-1):** When get_height_at returns -1 (chunk not in cache), _sample_height returns 0.0; _build_boundary_vertices and grid loop use height_fallback (from first boundary vertex with y>0 or min_terrain_y) or 0. So slice does not break; it may be flat or wrong in missing regions. >20% fail triggers push_warning.
- **Vertex colors:** Top: _terrain_color(h) per elevation. Walls: earth Color(0.35, 0.25, 0.15). Correct.
- **Golden rim:** _build_golden_rim_mesh() creates 6 vertices at hex corners with height from get_height_at (0 if -1), indices 0,1,2,3,4,5,0 for LINE_STRIP. So a closed hex outline at rim height. Material: unshaded, emissive gold. It is a child of _slice_instance so it moves with the slice. Position is local to slice (slice at _center_x, _center_z); rim vertices are in local coords (a.x, h + offset, a.y). So the rim is correctly positioned.
- **Lift animation:** _process: _lift_t < 1 → _lift_t += rate, ease_out = 1.0 - (1.0 - _lift_t)^2, position.y = ease_out * LIFT_TOP_M. Else position.y = LIFT_TOP_M + 3*sin(TAU*_selection_time). So lift and oscillation are implemented.
- **Potential issues:** (1) Rim is LINE_STRIP; on some GPUs line width may be 1 pixel or thin. (2) If many height samples fail, slice looks flat. (3) Wall quad winding: indices [v0_top, v0_top+1, v0_top+3, v0_top, v0_top+3, v0_top+2] — first tri (v0_top, v0_top+1, v0_top+3), second (v0_top, v0_top+3, v0_top+2). With vertices in order top-L, bottom-L, top-R, bottom-R, this is correct for two tris. No bug identified in slice geometry; status Fragile due to dependency on height cache.

### 3.4 Other bugs from code reading

- **LoadingScreen.update_progress chunk_name:** In loading_screen.gd update_progress(current, total, chunk_name), the status label is set to "Loading %s (%d/%d)" % [chunk_name, current, total]. ChunkManager calls update_progress(loaded_chunks.size(), want_count, "") with empty chunk_name, so label shows "Loading  (44/529)" etc. Minor UX; not a crash. **Where:** ui/loading_screen.gd 39; chunk_manager.gd 419.
- **profiling_camera_driver uses initial_load_complete:** It reads _chunk_manager.get("initial_load_complete"). ChunkManager has initial_load_complete as a var (not @export). So .get() works. No bug.
- **diagnostic_camera_driver get_diagnostic_snapshot:** ChunkManager defines get_diagnostic_snapshot(). Diagnostic driver calls it when has_method("get_diagnostic_snapshot"). OK.
- **Null refs:** ChunkManager _ready gets loading_screen from /root/TerrainDemo/LoadingScreen or /root/Node3D/LoadingScreen; if null, no crash, just no loading UI. HexSelector _chunk_manager from get_parent().get_node_or_null("ChunkManager") — if parent is TerrainDemo, ChunkManager is sibling; OK. set_selected_hex checks _chunk_manager and has_method("get_height_at") and returns early if not; safe.
- **Hex axial round in camera vs shader:** Camera uses _axial_round (cube_round) in GDScript; shader uses axial_round (cube_round) in GLSL. Both use same formula (round cube, resolve tie by largest diff). Should match.
- **TerrainLoader resolution_m from metadata:** TerrainLoader loads resolution_m from metadata (default 30). ChunkManager overwrites _resolution_m from terrain_loader.resolution_m in _ready. So Europe (90) and Alps (30) both supported. OK.
- **Unused _verify_no_overlaps:** chunk_manager.gd defines _verify_no_overlaps(chunks) but it is never called. Dead code; no runtime effect.
- **Constants.LOD_DISTANCES_M vs chunk_manager LOD_DISTANCES_M:** config/constants.gd has LOD_DISTANCES_M [0, 10k, 25k, 50k, 100k]. chunk_manager.gd defines its own const LOD_DISTANCES_M [0, 50000, 75000, 200000, 500000]. So the engine uses the chunk_manager values (continental scale); Constants is not used for LOD distances. Fragile: two sources of truth.

---

## Section 4: Fragile Code / Technical Debt

1. **LOD distance and grid constants duplicated:** ChunkManager has its own LOD_DISTANCES_M, INNER_RADIUS_M, etc. Constants.gd has different LOD_DISTANCES_M and streaming-related constants. Changing one does not change the other; continental tuning is in ChunkManager only.
2. **Shared material via first chunk in group:** Camera gets terrain material with get_first_node_in_group("terrain_chunks"). Order is undefined; if the “first” chunk is unloaded or hidden, the next frame a different chunk may be first. So far all chunks share the same material, so it works, but it’s fragile if chunks ever get different materials or if visibility/order changes.
3. **Height cache key is LOD 0 path only:** get_height_at uses LOD 0 chunk path; cache is populated when LOD 0 chunks complete async load. If the user selects a hex in an area where only LOD 1+ is loaded, get_height_at returns -1 and slice uses fallback 0 or boundary average. So slice is fragile at coarse LOD or before LOD 0 has loaded.
4. **Error handling gaps:** TerrainLoader load_chunk returns null if file not found or heights empty; ChunkManager sync load path (_load_chunk) push_errors but async path only drops the chunk (computed.is_empty() or !last_desired.has(chunk_key) → continue). Missing PNG or decode failure for one chunk does not crash but leaves a hole. No retry or user-facing message. Overview plane: if overview texture file missing, push_warning and skip; scene runs without overview.
5. **Per-frame allocations:** _update_chunks builds to_load, to_unload_candidates, cell_min_lod dict, and various temp arrays each run. For 500+ desired chunks and 44–75 loaded, this is acceptable but could be optimized (reuse arrays, reduce dict allocations).
6. **Assumptions about data format:** TerrainLoader assumes 16-bit grayscale PNG; raw parser expects exact IHDR/IDAT structure. If a chunk is 8-bit or different format, fallback to Image.load and 8-bit path with push_error. process_terrain.py outputs 16-bit; any other pipeline must match.
7. **Debug prints not gated:** Many print() calls are behind DEBUG_STREAMING_TIMING or DEBUG_DIAGNOSTIC, but e.g. "ChunkManager: LOD0 grid...", "Initial Load (async)", "Overview plane added", "Terrain metadata loaded", "TerrainLoader: Unified terrain shader loaded.", "Camera initialized...", "DEBUG: Left Click Detected", "DEBUG: Could not find hex overlay material" are ungated. Left-click and "Could not find hex overlay" can spam or appear in production.
8. **Dead shader files:** overview.gdshader and hex_overlay.gdshader remain in the repo; PROGRESS says they were removed. Can cause confusion or accidental use.

---

## Section 5: What's Actually Working Well

1. **Async load pipeline:** Phase A in TerrainWorker (static, no node refs) avoids “previously freed” and editor freeze. Phase B micro-steps (MESH → SCENE → COLLISION) with frame budget and minimum 1 step per frame keep loading responsive. Height cache is filled from worker result on main thread, so get_height_at works after LOD 0 loads.
2. **LOD visibility rule:** “Hide coarse if all four finer children are loaded” is simple and correct in principle; the only issue is timing (visibility updated on timer, not immediately when a child is added).
3. **Unified terrain + overview:** One shader for all LODs with altitude-based overview blend; overview plane at Y=-20 fills gaps. Same world extent in metadata, ChunkManager plane, and shader overview_origin/size avoids misalignment.
4. **Hex overlay decoupled:** Hex logic is entirely in hex_grid.gdshader (next_pass). Selection is physical slice in HexSelector using height cache. No terrain vertex modification; clear separation.
5. **Continental scale parameters:** LOD distances 0–50 km, 50–75 km, … 500 km+ and altitude gate (no LOD 0 above 70 km) avoid load-then-unload flash and match zoom-out feel. Deferred unload with “covered by finer” check avoids holes; burst unload spread avoids hitches.
6. **Camera and collision:** Terrain clearance raycast keeps camera above terrain. Collision only LOD 0–1; LOD 2+ skip collision (finish_load_step_collision returns early). Hex raycast uses same collision; LOD 3+ selection disabled with message.
7. **Constants and metadata:** resolution_m, chunk_size_px, grid dimensions from terrain_metadata.json support different regions (Europe 90 m, Alps 30 m). process_terrain.py and engine share SEA_LEVEL_UINT16 and overview coloring logic.

---

## Section 6: Recommended Fix Order

1. **Multiple hex grids visible** — Why first: Directly visible bug; users see double grid. Fix: call _update_chunk_visibility() after each Phase B chunk add (and/or every frame while streaming). Risk: low. Complexity: small.
2. **Ungated debug prints** — Why: Reduces console noise and avoids “DEBUG: Left Click” in production. Remove or gate “DEBUG: Left Click”, “Could not find hex overlay”, and other always-on prints. Risk: low. Complexity: small.
3. **LoadingScreen progress label** — Why: Pass current chunk key or “…” from ChunkManager to update_progress so label shows “Loading lod0_12_34 (44/529)”. Risk: low. Complexity: small.
4. **Single source of truth for LOD distances** — Why: Prevents drift between Constants and ChunkManager; makes tuning one place. Move continental LOD_DISTANCES_M and related constants to Constants or to an autoload/config; ChunkManager reads them. Risk: medium (must verify all reads). Complexity: small.
5. **Hex overlay when two LODs visible** — Why: Even after visibility is updated promptly, there can be a frame or two where both coarse and fine are visible; or keep one-coarse-one-fine by design at boundaries. To avoid double overlay: consider single full-screen hex pass or “primary LOD” mask. Risk: medium. Complexity: medium–large.
6. **Terrain transparent / grid through terrain** — Why: If still reported, verify ALPHA and draw order; add explicit alpha=0 for “no overlay” in shader. Risk: low. Complexity: small.
7. **Dead code removal** — Why: Delete or stop tracking overview.gdshader and hex_overlay.gdshader; optionally remove _verify_no_overlaps or call it in debug. Risk: low. Complexity: small.
8. **Height cache / slice at coarse LOD** — Why: Better UX when only LOD 1 is loaded: either sample from LOD 1 height (if cached) or show a clear “Load detail to select” message. Risk: medium. Complexity: medium.

---

## Section 7: Code Metrics

- **Total lines of GDScript:** Sum of .gd files: 1318 + 957 + 291 + 396 + 612 + 174 + 44 + 43 + 298 + 117 = **4,250** (excluding .gdshader and other).
- **Total lines of shader code:** terrain.gdshader 127 + hex_grid.gdshader 176 + overview.gdshader 46 + hex_overlay.gdshader 154 = **503** (active: 127 + 176 = 303).
- **Exported variables:** 7 total — ChunkManager: DEBUG_STREAMING_TIMING, DEBUG_DIAGNOSTIC; TerrainLoader: DEBUG_CHUNK_TIMING, DEBUG_HEX_GRID; basic_camera: DEBUG_DIAGNOSTIC; diagnostic_camera_driver: enabled; profiling_camera_driver: enabled.
- **Debug/diagnostic flags:** 5 (DEBUG_STREAMING_TIMING, DEBUG_DIAGNOSTIC x2, DEBUG_CHUNK_TIMING, DEBUG_HEX_GRID); plus enabled on the two drivers.
- **TODO/FIXME/HACK comments:** 0 found in .gd, .gdshader, .py.
- **Print statements:** ~60+ in .gd files total. Gated (behind DEBUG_* or enabled): most ChunkManager [Stream]/[LOD]/[TIME]/[DIAG]/[FRAME] prints, TerrainLoader [TIME]/[HEX]/[CACHE]/[ASYNC], TerrainWorker [HEIGHT]/[VERIFY], basic_camera [SHADER]/[VERIFY]/[HEX]/COLLISION, fps_counter [PERF], diagnostic and profiling drivers. Ungated: ChunkManager (e.g. “ChunkManager: LOD0 grid…”, “Initial Load (async)”, “Overview plane added”, “Initial load complete”, “Dynamic chunk streaming active”, “Loading %d chunks”, debug dump, some [Stream] Loaded/Unloaded when DEBUG_STREAMING_TIMING); TerrainLoader (“TerrainLoader: Hex overlay…”, “Overview texture loaded”, “Unified terrain shader loaded”, “Terrain metadata loaded”, “Generating mesh…”, “Generated %d vertices/triangles” when verbose); basic_camera (“Camera initialized…”, “DEBUG: Left Click Detected”, “DEBUG: Could not find hex overlay material”). So roughly ~25+ ungated prints, ~35+ gated.

---

*End of audit. No code was modified.*
