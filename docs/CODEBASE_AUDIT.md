# GeoStrategy Engine — Codebase Audit

## Date: February 16, 2026

**Scope:** Read-only audit. No code was modified.  
**Purpose:** Explore, document, and report for architect decisions. Hex grid and selection pipeline documented in detail.

---

## 1. File Inventory

Excludes: `.godot/`, `.import/`, binary assets (PNG, .hgt, etc.). Data chunk PNGs and tools/cache omitted.

| Path | Type | Lines | Purpose (one line) |
|------|------|-------|--------------------|
| `project.godot` | Config | 17 | Godot 4.5 project config; main scene = terrain_demo. |
| `.gitignore` | Config | 10 | Ignores .godot/, data/, tools/, profiling output. |
| `.gitattributes` | Config | — | Git line endings / attributes. |
| `config/constants.gd` | GDScript | 175 | Central constants: LOD, hex (HEX_SIZE_M, grid fade), camera, paths, debug. |
| `config/regions.json` | JSON | 20 | Region definitions (alps_test, europe) for process_terrain.py; not loaded at runtime. |
| `core/chunk_manager.gd` | GDScript | 1328 | Terrain streaming: desired set, async Phase A/B, visibility, deferred unload, get_height_at / get_lod_at_world_position. |
| `core/terrain_loader.gd` | GDScript | 951 | Stateless chunk loading: 16-bit PNG, LOD mesh/collision, shared terrain material (no next_pass), height cache, get_height_at. |
| `core/terrain_worker.gd` | GDScript | 295 | Static Phase A worker: PNG decode + mesh arrays on WorkerThreadPool; no node refs. |
| `core/hex_selector.gd` | GDScript | 406 | Physical hex slice: mesh from height cache, walls, lift + oscillation; rim drawn in compositor. |
| `rendering/terrain.gdshader` | Shader | 187 | Terrain: elevation/slope color, water, overview blend, fog, edge fade; **hex grid lines** (world-space, pointy-top). |
| `rendering/hex_overlay_screen.glsl` | GLSL (compute) | 237 | Screen-space compositor: depth unproject, world XZ, grid (optional), hover, selection rim/cutout/darken. |
| `rendering/hex_overlay_compositor.gd` | GDScript | 196 | CompositorEffect: loads GLSL, packs Params (inv_proj, inv_view, hex_size, hover/selection), dispatches compute. |
| `rendering/hex_grid_OLD.gdshader` | Shader | 194 | Archived next_pass hex overlay (depth_test_disabled); replaced by terrain in-shader grid + compositor. |
| `rendering/basic_camera.gd` | GDScript | 698 | Orbital camera: WASD, zoom, orbit, terrain clearance; hex hover/selection raycast; terrain + compositor uniforms; F1–F6 hex debug. |
| `scenes/terrain_demo.tscn` | Scene | 99 | Main scene: TerrainLoader, ChunkManager, HexSelector, Camera3D, WorldEnvironment, LoadingScreen, FPS, ProfilingDriver, DiagnosticDriver. |
| `node_3d.tscn` | Scene | 37 | Minimal: TerrainLoader, ChunkManager, Camera3D, light, env; no LoadingScreen/HexSelector. |
| `ui/loading_screen.gd` | GDScript | 44 | Progress bar during initial chunk load; update_progress(current, total, chunk_name). |
| `ui/fps_counter.gd` | GDScript | 43 | Label: FPS, rolling avg, 1% low, draw calls; [PERF] if 1% low < 60. |
| `tools/process_terrain.py` | Python | 509 | CLI: download SRTM, merge, LOD/chunk, overview texture, terrain_metadata.json. |
| `tools/diagnostic_camera_driver.gd` | GDScript | 298 | Automated camera sequence; logs [DIAG]; get_diagnostic_snapshot(). |
| `tools/profiling_camera_driver.gd` | GDScript | 117 | Stress-test pan/zoom then quit; initial_load_complete. |
| `tools/visualize_heightmap.py` | Python | 29 | Visualize heightmap (small util). |
| `tools/generate_test_data.py` | Python | 125 | Generate test terrain data. |
| `tools/validate_output.py` | Python | 396 | Validate pipeline output. |
| `tools/validate_16bit.py` | Python | 80 | Validate 16-bit PNG. |
| `tools/README.md` | Docs | 138 | Tools usage. |
| `data/terrain/terrain_metadata.json` | JSON | ~91583 | Region metadata: bounding_box, resolution_m, chunks list, overview_texture path. |
| `docs/PROGRESS.md` | Docs | 229 | Progress tracker, backlog, architecture notes. |
| `docs/HEX_OVERLAY_FINAL_SUMMARY.md` | Docs | 81 | Compositor hex overlay summary. |
| `docs/HEX_GRID_DECAL_FINDINGS.md` | Docs | 78 | Decal/grid findings. |
| `docs/HEX_SELECTION_DIAGNOSTIC_REPORT.md` | Docs | 237 | Selection diagnostic. |
| `docs/GeoStrategy_Engine_SSOT.md` | Docs | 669 | Single source of truth / design. |
| `.vscode/settings.json` | Config | 3 | Editor settings. |

**Summary:** Hex grid is drawn in **terrain.gdshader** (world-space lines). Selection/hover/rim are in **hex_overlay_screen.glsl** (screen-space compositor). No `hex_grid.gdshader` next_pass; `hex_grid_OLD.gdshader` is archived. No `hex_grid_mesh.gd` in repo (PROGRESS refers to it; current design uses terrain shader for grid).

---

## 2. Architecture Map

### 2.1 Scene Tree

- **Main scene:** `scenes/terrain_demo.tscn` (run/main_scene in project.godot).
- **Root:** `Node3D` "TerrainDemo".
  - **ProfilingDriver** (Node) — script: profiling_camera_driver.gd.
  - **DiagnosticCameraDriver** (Node) — script: diagnostic_camera_driver.gd.
  - **TerrainLoader** (Node) — script: terrain_loader.gd; loads metadata, creates shared_terrain_material (terrain.gdshader), shared_terrain_material_lod2plus; no next_pass.
  - **ChunkManager** (Node3D) — script: chunk_manager.gd; owns TerrainChunks (Node3D), TerrainCollision (StaticBody3D), overview plane (if metadata has overview_texture).
  - **HexSelector** (Node3D) — script: hex_selector.gd; builds slice mesh on selection, adds MeshInstance3D as child.
  - **Camera3D** — script: basic_camera.gd; orbit, pan, zoom; raycast for hover/selection; updates terrain material and HexOverlayCompositor.
  - **DirectionalLight3D**
  - **WorldEnvironment** — environment (sky, tonemap); **Compositor** is created/updated by camera (_ensure_hex_compositor) and holds HexOverlayCompositor effect.
  - **FPSCounter** (CanvasLayer) — Label, fps_counter.gd.
  - **LoadingScreen** (CanvasLayer) — loading_screen.gd.
- Chunk nodes: MeshInstance3D "Chunk_LOD{l}_{x}_{y}" under TerrainChunks; LOD 0–1 use shared_terrain_material, LOD 2+ use shared_terrain_material_lod2plus. Both use same terrain.gdshader (with in-shader hex grid). Collision shapes under TerrainCollision (LOD 0–1 only).

### 2.2 Data Flow

1. **SRTM → processed chunks:** `tools/process_terrain.py` downloads SRTM (.hgt), merges, builds LOD pyramid, writes PNGs to `data/terrain/chunks/lod{N}/chunk_{x}_{y}.png` and `terrain_metadata.json`.
2. **Engine load:** TerrainLoader._ready loads metadata, creates shared ShaderMaterial from `terrain.gdshader`. ChunkManager._ready reads resolution_m and LOD0 grid from loader, sets up overview plane, starts _initial_load().
3. **Desired set:** ChunkManager._determine_desired_chunks(camera_pos): inner ring LOD 0 within INNER_RADIUS_M, per-cell LOD from LOD_DISTANCES_M + hysteresis; outer ring LOD 4; _expand_lod0_to_full_blocks ensures 2×2 blocks.
4. **Phase A (async):** TerrainWorker.compute_chunk_data on WorkerThreadPool: decode PNG → heights, build vertices/normals/indices, return result with heights_for_cache/path_for_cache.
5. **Phase B (main thread):** _drain_completed_async_to_phase_b pushes to _pending_phase_b. _do_one_phase_b_step: MESH → finish_load_step_mesh; SCENE → finish_load_step_scene (MeshInstance3D, material, add to chunks_container); COLLISION → finish_load_step_collision (LOD 0–1 only). Height cache updated from result in Phase B.
6. **Rendering:** Each chunk MeshInstance3D uses shared_terrain_material (terrain.gdshader). Shader receives altitude, camera_position, terrain_center_xz, terrain_radius_m, show_hex_grid, hex_size (pointy-top radius). Hex grid lines are drawn in fragment via hex_edge_and_inside. After opaque pass, HexOverlayCompositor runs (PRE_TRANSPARENT): reads depth, reconstructs world XZ (camera-relative for precision), draws selection/hover/optional grid on color image.

### 2.3 Hex System Overview

- **Coordinates:** Axial (q, r); cube (q, r, -q-r). **Pointy-top** orientation: vertex up (world X = horizontal, Z = vertical in XZ plane).
- **HEX_SIZE_M (constants.gd):** 1000.0 m = **flat-to-flat** width. Pointy-top “radius” (center to vertex) = HEX_SIZE_M / √3 ≈ 577.35 m.
- **Where hex is defined/used:**
  - **basic_camera.gd:** world_to_axial and axial_to_world for raycast hit → hex center; hex_size = Constants.HEX_SIZE_M / sqrt(3.0) (pointy-top radius). Sends to terrain shader as hex_size (pointy-top) and to compositor (compositor uses HEX_SIZE_M = 1000 internally).
  - **terrain.gdshader:** world_to_axial, axial_to_center, cube_round, seg_dist, edge_side, hex_edge_and_inside; draws grid lines (hex_line_mask) in fragment. Operates in world XZ; hex_size uniform = pointy-top radius.
  - **hex_overlay_screen.glsl:** world_to_axial(pos, width), cube_round, axial_round, hex_dist; works in camera-relative XZ; params.hex_size = 1000 (flat-to-flat), size = width/SQRT_3, hex_radius = width*0.5.
  - **hex_selector.gd:** _axial_round, _hex_corners_local (flat-top corners), _is_inside_hex; uses Constants.HEX_SIZE_M; R = hex_size / SQRT3 for grid.
- **Hex selection:** Camera left-click → raycast → hit position → world_to_axial → axial_round → axial_to_world → hex center. If same as current → clear; else set_selected_hex(center). HexSelector builds slice mesh (height cache), adds slice node. Camera sets compositor selected_hex_center and selection_time. Compositor shader draws cutout, golden rim, hover.
- **Hex grid rendering:** **Terrain shader** draws grid (world-space, one pass per chunk). **Compositor** can draw grid when draw_grid_lines = true (default false); grid is normally only in terrain shader.

### 2.4 Camera System

- **Movement:** WASD → _pan (forward/right from basis, target_position += movement). Speed = pan_speed * (orbit_distance/1000), × speed_boost with Space. Zoom: scroll → target_orbit_distance *= (1 ± 0.15), clamped 500–5,000,000 m. Orbit: middle mouse → orbit_yaw, orbit_pitch (clamped 10–89°).
- **Transform:** position = target_position + spherical offset; raycast down for terrain height; if position.y < terrain_height + min_camera_clearance, push camera up and adjust orbit_distance. look_at(target_position, UP).
- **Far plane:** orbit_distance > 1,000,000 → far = 10,000,000 else 2,000,000.
- **Hex:** Hover raycast every 3rd frame; hit → hex center → compositor.hovered_hex_center. Left click → _handle_hex_selection_click → selected_hex_center, HexSelector.set_selected_hex/clear_selection, _update_hex_selection_uniform. LOD ≥ 3 at hit shows “Zoom in to select”.
- **Uniforms:** _update_hex_grid_interaction sets terrain material (altitude, camera_position, terrain_center_xz, terrain_radius_m, show_hex_grid, hex_size = HEX_SIZE_M/sqrt(3)) and compositor (altitude, camera_position, selection_time, selected_hex_center, show_grid). F1 toggles grid; F2/F3/F4/F6 hex debug.

### 2.5 Rendering Pipeline

- **Terrain:** terrain.gdshader — spatial, blend_mix, depth_draw_opaque. Vertex: world pos, elevation, world normal. Fragment: water/terrain color, overview blend, desaturation, edge fade, fog, **hex grid** (hex_edge_and_inside → hex_line_mask, fwidth/smoothstep, mix with hex_line_color).
- **Hex overlay:** HexOverlayCompositor (CompositorEffect, PRE_TRANSPARENT). Compute shader hex_overlay_screen.glsl: reads resolved/raw depth, inv_projection + inv_view → world position; camera-relative XZ; grid (if draw_grid_lines), hover, selection (cutout, rim, glow, darken). Single fullscreen pass; no per-chunk overlay.
- **Overview plane:** ChunkManager creates quad with StandardMaterial3D (overview texture) at Y = -20 when metadata has overview_texture.

---

## 3. Hex Grid Shader — Deep Dive

Two places implement hex logic: **terrain.gdshader** (grid lines on terrain) and **hex_overlay_screen.glsl** (compositor: selection/hover, optional grid). Both are documented below.

### 3.1 Terrain shader (terrain.gdshader)

#### Uniforms (hex-related and main)

| Name | Type | Default | Purpose |
|------|------|---------|--------|
| hex_size | float | 577.35 | Pointy-top radius (center to vertex); comment: HEX_SIZE_M/sqrt(3). |
| hex_line_width | float | 22.0 | Line width for grid (world units). |
| hex_line_softness | float | 5.0 | Anti-alias (fwidth scale). |
| hex_grid_strength | float | 0.55 | Mix strength for grid. |
| hex_line_color | vec3 | (0.10, 0.12, 0.08) | Grid line color. |
| show_hex_grid | bool | true | Toggle grid. |
| altitude, camera_position, terrain_center_xz, terrain_radius_m, overview_texture, overview_origin, overview_size, use_overview | (various) | — | Terrain/fog/overview. |

#### Vertex shader

```gdshader
void vertex() {
	vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_world_pos = world_pos.xyz;
	v_elevation = world_pos.y;
	v_world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}
```

No hex-specific vertex logic; world position and normal passed to fragment.

#### Fragment shader flow (hex part)

1. Compute terrain/water and overview blend, desaturation, edge fade, fog → base_col.
2. If show_hex_grid: call `hex_edge_and_inside(v_world_pos.xz, hex_size)` → (edge_d, inside). Line mask: `hex_line_mask = (1.0 - smoothstep(hex_line_width - aa, hex_line_width + aa, d)) * inside` with `aa = fwidth(d) * hex_line_softness`. Optional: mask *= smoothstep(0.35, 0.65, n.y) (reduce on steep slopes). base_col is mixed with hex_line_color and darkening by hex_line_mask * hex_grid_strength.
3. Output ALBEDO, ROUGHNESS, METALLIC, RIM, RIM_TINT; EMISSION = 0.

#### Hex functions in terrain.gdshader (exact code)

**world_to_axial:**

```gdshader
vec2 world_to_axial(vec2 xz, float size) {
	return vec2((2.0/3.0 * xz.x) / size, (-1.0/3.0 * xz.x + sqrt(3.0)/3.0 * xz.y) / size);
}
```

- Input: world XZ, pointy-top `size` (center-to-vertex).
- Output: axial (q, r). Coordinate space: world XZ; same formula as standard pointy-top axial (x along flat edge, y up in 2D = Z in world).

**axial_to_center:**

```gdshader
vec2 axial_to_center(vec2 axial, float size) {
	return vec2(size * (1.5 * axial.x), size * (sqrt(3.0)/2.0 * axial.x + sqrt(3.0) * axial.y));
}
```

- Converts axial (q, r) to world center XZ. Uses pointy-top layout: cx = size * 1.5*q, cy = size * (√3/2 * q + √3 * r).

**cube_round:**

```gdshader
vec3 cube_round(vec3 c) {
	vec3 r = round(c);
	vec3 d = abs(r - c);
	if (d.x > d.y && d.x > d.z) r.x = -r.y - r.z;
	else if (d.y > d.z) r.y = -r.x - r.z;
	else r.z = -r.x - r.y;
	return r;
}
```

- Cube coordinates (x,y,z) with x+y+z=0; tie-break by largest residual.

**seg_dist (point-to-segment distance):**

```gdshader
float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}
```

**edge_side (inside/outside edge):**

```gdshader
float edge_side(vec2 p, vec2 a, vec2 b) {
	vec2 e = b - a;
	return (p.x - a.x) * e.y - (p.y - a.y) * e.x;
}
```

- Positive = inside (left of directed edge a→b).

**hex_edge_and_inside:**

```gdshader
vec2 hex_edge_and_inside(vec2 world_xz, float size) {
	vec2 axial = world_to_axial(world_xz, size);
	vec3 r = cube_round(vec3(axial.x, -axial.x - axial.y, axial.y));
	vec2 center = axial_to_center(vec2(r.x, r.z), size);
	vec2 p = world_xz - center;
	float k = size;
	float c = 0.866025, s = 0.5;
	vec2 v0 = k * vec2(0.0, 1.0), v1 = k * vec2(c, s), v2 = k * vec2(c, -s);
	vec2 v3 = k * vec2(0.0, -1.0), v4 = k * vec2(-c, -s), v5 = k * vec2(-c, s);
	float d0 = seg_dist(p, v0, v1), d1 = seg_dist(p, v1, v2), d2 = seg_dist(p, v2, v3);
	float d3 = seg_dist(p, v3, v4), d4 = seg_dist(p, v4, v5), d5 = seg_dist(p, v5, v0);
	float edge_d = min(min(min(d0, d1), min(d2, d3)), min(d4, d5));
	float in0 = edge_side(p, v0, v1), in1 = edge_side(p, v1, v2), in2 = edge_side(p, v2, v3);
	float in3 = edge_side(p, v3, v4), in4 = edge_side(p, v4, v5), in5 = edge_side(p, v5, v0);
	float inside = (in0 >= 0.0 && in1 >= 0.0 && in2 >= 0.0 && in3 >= 0.0 && in4 >= 0.0 && in5 >= 0.0) ? 1.0 : 0.0;
	return vec2(edge_d, inside);
}
```

- Cube from axial: (q, -q-r, r); then axial from cube (r.x, r.z) = (q, r). Six vertices in pointy-top: (0,1), (c,s), (c,-s), (0,-1), (-c,-s), (-c,s) with c≈0.866, s=0.5. **All six edges** used for seg_dist and edge_side. Returns (min distance to any edge, 1 if inside cell else 0).

#### Line rendering (terrain)

- **Distance:** `edge_d` = minimum of the six seg_dist values (distance to nearest edge).
- **Inside:** Only draw line when `inside == 1.0` (no “gap triangles” outside cell).
- **Smoothing:** `aa = fwidth(d) * hex_line_softness`; `hex_line_mask = (1.0 - smoothstep(hex_line_width - aa, hex_line_width + aa, d)) * inside`.
- **Thickness:** Controlled by uniform `hex_line_width` (default 22).

---

### 3.2 Compositor shader (hex_overlay_screen.glsl)

#### Uniforms (Params UBO)

| Name | Type | Purpose |
|------|------|--------|
| inv_projection | mat4 | Clip → view. |
| inv_view | mat4 | View → world (camera transform). |
| hex_size | float | 1000 (flat-to-flat) in use. |
| show_grid | float | 1 = true. |
| altitude | float | For fade/scale. |
| depth_ndc_flip | float | Use (1-depth) as NDC z if needed. |
| camera_position | vec3 | For camera-relative XZ. |
| time | float | Rim pulse. |
| hovered_hex_center | vec2 | World XZ. |
| selected_hex_center | vec2 | World XZ. |
| selection_time | float | Fade-in. |
| debug_visualization | float | 0/1/2. |
| debug_depth | float | Depth debug view. |
| use_resolved_depth | float | Depth texture source. |
| draw_grid_lines | float | If false, grid only in terrain shader. |

#### Constants

- SQRT_3 = 1.73205080757
- LINE_WIDTH = 12.0
- CUTOUT_MARGIN_M = 15.0
- GRID_FADE_START/END = 5000, 20000
- HOVER_SENTINEL = -999990, SELECT_SENTINEL = 900000

#### Main flow (compute main())

1. uv = pixel; sample depth. If debug_depth → show depth quadrants and return.
2. If depth_raw >= 1 or < 1e-6 → skip (sky).
3. reconstruct_world_position(uv, depth) → world_pos; then camera-relative: world_xz = (world_pos - camera_xz).xz.
4. dist_from_edge = hex_dist(world_xz, params.hex_size). Hover/selection in camera-relative axial; is_hovered, is_selected, has_selection.
5. dist_from_sel_center = max(d1_sel, d2_sel, d3_sel) with d1=d_sel.y, d2=dot(d_sel,(√3/2,0.5)), d3=dot(d_sel,(√3/2,-0.5)) — **all three axes** (six edges).
6. Grid (if draw_grid_lines && show_grid): dist_from_edge < half_width → line with smoothstep.
7. Hover: is_hovered && !is_selected → line + 0.08 alpha.
8. Selection: inside_cutout darken; is_selected → gold tint, golden rim (rim_distance = abs(hex_radius - dist_from_sel_center)), pulse emission; !is_selected nearby → darken.
9. Blend to color_image; debug_visualization overwrites for depth or world XZ pattern.

#### Hex functions in hex_overlay_screen.glsl (exact code)

**world_to_axial:**

```glsl
vec2 world_to_axial(vec2 pos, float width) {
	float size = width / SQRT_3;
	float q = (2.0/3.0 * pos.x) / size;
	float r = (-1.0/3.0 * pos.x + SQRT_3/3.0 * pos.y) / size;
	return vec2(q, r);
}
```

- `width` = flat-to-flat (params.hex_size = 1000); `size` = pointy-top radius. Same formula as terrain in world (x,y) = (X, Z).

**cube_round:**

```glsl
vec3 cube_round(vec3 cube) {
	float rx = round(cube.x);
	float ry = round(cube.y);
	float rz = round(cube.z);
	float x_diff = abs(rx - cube.x);
	float y_diff = abs(ry - cube.y);
	float z_diff = abs(rz - cube.z);
	if (x_diff > y_diff && x_diff > z_diff) {
		rx = -ry - rz;
	} else if (y_diff > z_diff) {
		ry = -rx - rz;
	} else {
		rz = -rx - ry;
	}
	return vec3(rx, ry, rz);
}
```

**axial_round:**

```glsl
vec2 axial_round(vec2 axial) {
	return cube_round(vec3(axial.x, axial.y, -axial.x - axial.y)).xy;
}
```

**hex_dist:**

```glsl
float hex_dist(vec2 p, float width) {
	float size = width / SQRT_3;
	vec2 q = world_to_axial(p, width);
	vec2 center_axial = axial_round(q);
	float size_ax = size;
	float cx = size_ax * (3.0/2.0 * center_axial.x);
	float cy = size_ax * (SQRT_3/2.0 * center_axial.x + SQRT_3 * center_axial.y);
	vec2 center_world = vec2(cx, cy);
	vec2 d = p - center_world;
	float r = width * 0.5;
	d = abs(d);
	float d1 = d.y;
	float d2 = abs(dot(d, vec2(SQRT_3/2.0, 0.5)));
	float dist_from_center = max(d1, d2);
	return r - dist_from_center;
}
```

- Returns **signed distance**: positive inside hex, negative outside. `r = width*0.5` = half flat-to-flat = apothem (center to flat edge). For pointy-top, “distance from center” to edge is max(d1, d2) in the two perpendicular directions; here only **two** axes (d1, d2) are used. So **hex_dist** is a 2-axis “rounded rectangle” style distance (correct for flat-top hex when using half-width as radius). For full six-edge distance, terrain uses seg_dist to each edge; compositor uses this 2-axis formula for grid-line “near edge” and separately uses d1, d2, d3 for selection “inside hex” (see below).

#### Line rendering (compositor)

- Grid: `dist_from_edge < half_width` (LINE_WIDTH*0.5) → `line_alpha = (1.0 - smoothstep(half_width - 2.0, half_width, dist_from_edge)) * grid_fade_alpha`; albedo black, alpha max 0.6*line_alpha.
- No fwidth (compute shader, no screen-space derivatives); fixed 2.0 pixel soften.
- **Distance function:** hex_dist returns (r - max(d1,d2)) with r = width/2. So “distance from edge” is that value; near edges it becomes small/negative. For **six edges** the true distance would be min of six edge distances; this 2-axis max(d1,d2) is an approximation (flat-top hex as two-axis rounded shape). Terrain uses exact min-of-six seg_dist.

### 3.3 Suspected issues (hex)

1. **terrain.gdshader cube_round argument order:** `cube_round(vec3(axial.x, -axial.x - axial.y, axial.y))` uses (q, -q-r, r). Standard cube is (q, r, -q-r). So cube y = -q-r, cube z = r. Constraint holds. axial_from_cube = (r.x, r.z) = (q, r). Correct.
2. **Compositor hex_dist:** Uses only d1 and d2 (two axes); flat-top hex has three directions. For **selection** the shader uses d1_sel, d2_sel, d3_sel (all three), so selection boundary is correct. For **grid line** thickness, hex_dist’s 2-axis formula can slightly misestimate distance to the third pair of edges → possible minor asymmetry or line-width variation at 60° angles.
3. **Precision:** Compositor uses camera-relative world_xz to avoid large-world float precision loss; terrain uses absolute v_world_pos.xz (no camera-relative in terrain). At 2M+ m, terrain hex grid could show drift/sliding if precision is an issue.
4. **hex_radius in compositor:** hex_radius = params.hex_size * 0.5 = 500 when hex_size=1000. That matches center-to-flat for flat-to-flat 1000. Selection cutout/rim use dist_from_sel_center with three axes; consistent.

---

## 4. Hex Selection System

### 4.1 World-to-Hex Math (GDScript — basic_camera.gd)

**On raycast hit (hit_pos = result.position):**

```gdscript
var width = Constants.HEX_SIZE_M
var hex_size = width / sqrt(3.0)
var q = (2.0 / 3.0 * hit_pos.x) / hex_size
var r = (-1.0 / 3.0 * hit_pos.x + sqrt(3.0) / 3.0 * hit_pos.z) / hex_size
var hex_axial = _axial_round(Vector2(q, r))
var center_x = hex_size * (3.0 / 2.0 * hex_q)
var center_z = hex_size * (sqrt(3.0) / 2.0 * hex_q + sqrt(3.0) * hex_r)
var center = Vector2(center_x, center_z)
```

- **world_to_axial:** q = (2/3 * x) / size, r = (-1/3 * x + √3/3 * z) / size, with size = HEX_SIZE_M/√3 (pointy-top radius). So **same formula** as terrain and compositor (with terrain/compositor using “size” or “width” as documented).
- **axial_to_world (center):** cx = size * (3/2 * q), cz = size * (√3/2 * q + √3 * r). Matches terrain axial_to_center and compositor axial_to_world.

### 4.2 Cube Round (GDScript)

```gdscript
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
```

- _axial_round(axial) calls _cube_round(Vector3(axial.x, axial.y, -axial.x - axial.y)). Same tie-break rule as shaders.

### 4.3 Shader vs GDScript Consistency

| Item | Terrain shader | Compositor GLSL | GDScript (camera) |
|------|----------------|-----------------|--------------------|
| world_to_axial | (2/3*x)/size, (-1/3*x+√3/3*z)/size | Same, size=width/√3 | Same, size=HEX_SIZE_M/√3 |
| axial→world center | size*(1.5*q), size*(√3/2*q+√3*r) | size*(1.5*q), size*(√3/2*q+√3*r) | Same |
| cube_round | (q,-q-r,r); tie largest residual | (q,r,-q-r); same tie | (q,r,-q-r); same tie |
| hex “size” | pointy-top radius (577.35) | width=1000 → size=577.35 internally | hex_size=1000/√3 |

- **Same coordinate system:** pointy-top axial; world X = first axis, world Z = second axis. Terrain passes hex_size as pointy-top radius; compositor receives flat-to-flat 1000 and derives size = 1000/√3. So **selection and grid use the same hex layout**. Possible subtle: terrain uses absolute world XZ; compositor uses camera-relative XZ and subtracts camera from hovered/selected center for comparison. If camera position is large, that keeps precision; axial comparison is then in the same relative space.

### 4.4 Physical Slice Mechanism (hex_selector.gd)

- **Trigger:** basic_camera calls hex_selector.set_selected_hex(center) with world XZ of hex center.
- **Height:** _chunk_manager.get_height_at(world_x, world_z) → ChunkManager → TerrainLoader.get_height_at. Loader uses LOD 0 chunk path from world XZ, _height_cache[path], bilinear interpolation. Returns -1 if chunk not cached.
- **Slice mesh:** _build_slice_mesh(): (1) Boundary: 6 edges, step BOUNDARY_STEP_M (25 m), heights from get_height_at. (2) Rectangular grid step GRID_STEP_M (50 m), clipped to hex via _hex_row_intersection_x and _is_inside_hex; vertices only inside hex; heights from get_height_at (fallback 0 if -1). (3) Triangulate top (CCW); _compute_grid_normals for top. (4) Walls: quads between consecutive boundary points, top/bottom (bottom = height - WALL_DEPTH_M). Single ArrayMesh; StandardMaterial3D with vertex_color_use_as_albedo.
- **Rim:** No longer built as mesh; comment says rim is drawn in hex_overlay_screen.glsl (screen-space).
- **Animation:** _process: _lift_t 0→1 over LIFT_DURATION_S, position.y = ease_out * LIFT_TOP_M; then position.y = LIFT_TOP_M + OSCILLATION_AMP_M * sin(TAU * OSCILLATION_HZ * _selection_time). Emission driven by lift factor.

---

## 5. Cross-System Consistency

| Check | Result |
|-------|--------|
| hex_radius vs HEX_SIZE_M | Constants: HEX_SIZE_M = 1000 (flat-to-flat). Pointy-top radius = 1000/√3 ≈ 577.35. Terrain hex_size uniform = 577.35. Compositor hex_size = 1000, hex_radius = 500 (center to flat). HexSelector R = hex_size/SQRT3 ≈ 577.35 for grid. **Consistent.** |
| Pointy-top vs flat-top | All axial math is **pointy-top** (vertex up). HexSelector _hex_corners_local uses flat-top **geometry** (flat edges horizontal) for slice boundary; corners are (0.5*size, 0), (0.25*size, size*√3/4), etc. So slice shape is flat-top; axial rounding elsewhere is pointy-top. Flat-top corners in local coords match the same physical hex (flat-to-flat = HEX_SIZE_M). **Consistent.** |
| axial↔world in shader vs GDScript | Same formulas (see 4.3). **Consistent.** |
| sqrt(3) / 2 factors | Terrain: axial_to_center uses size*(√3/2*q+√3*r) for second component. Camera: center_z = hex_size*(√3/2*q+√3*r). Compositor: cy = size_ax*(SQRT_3/2*center_axial.x + SQRT_3*center_axial.y). **Consistent.** |
| Cube component order | Terrain: vec3(axial.x, -axial.x-axial.y, axial.y) = (q,-q-r,r). Compositor/camera: cube (q, r, -q-r); axial_round returns .xy so (q,r). Terrain cube_round returns vec3; then vec2(r.x, r.z) = (q,r). **Consistent.** |

**Potential inconsistency:** Terrain does not use camera-relative coordinates; at very large world coordinates (e.g. 2e6 m) floating-point could cause grid to drift relative to selection. Compositor avoids this by using camera-relative XZ.

---

## 6. Constants & Configuration

### 6.1 config/constants.gd

- **Hex:** HEX_SIZE_M = 1000, HEX_WIDTH_M = 1000, HEX_HEIGHT_M = 866.025, HEX_VERTICES = 7.
- **Grid visibility:** GRID_FADE_START_M = 5000, GRID_FADE_END_M = 20000, GRID_DEFAULT_VISIBLE = true.
- **LOD:** LOD_LEVELS = 5, LOD_RESOLUTIONS_M, LOD_DISTANCES_M (0, 50k, 75k, 200k, 500k), LOD_HYSTERESIS = 0.1, INNER_RADIUS_M = 500000, VISIBLE_RADIUS_ALTITUDE_FACTOR = 2.5.
- **Chunks:** CHUNK_SIZE_PX = 512, CHUNK_SIZE_M, TARGET_LOADED_CHUNKS, etc.
- **Camera:** CAMERA_MIN/MAX_ALTITUDE_M, CAMERA_SPEED_FACTOR, pitch/zoom constants.
- **Paths:** TERRAIN_DATA_PATH, CHUNK_PATH_PATTERN, METADATA_PATH, REGIONS_CONFIG_PATH.

### 6.2 ChunkManager (duplicated / overrides)

- INNER_RADIUS_M, VISIBLE_RADIUS_ALTITUDE_FACTOR duplicated (same values).
- LOD_DISTANCES_M: constants.gd has [0, 50k, 75k, 200k, 500k]; ChunkManager uses its own const (same values in code). So no conflict but two places to change.

### 6.3 Shader defaults

- **terrain.gdshader:** hex_size = 577.35, hex_line_width = 22, hex_line_softness = 5, hex_grid_strength = 0.55, show_hex_grid = true. Overridden by camera: hex_size = Constants.HEX_SIZE_M/sqrt(3), show_hex_grid = _grid_visible.
- **hex_overlay_screen.glsl:** LINE_WIDTH = 12, CUTOUT_MARGIN_M = 15, GRID_FADE_START/END = 5000/20000. Compositor: hex_size = Constants.HEX_SIZE_M (1000), draw_grid_lines = false.

### 6.4 Python pipeline (process_terrain.py)

- Region from config; resolution (srtm3 90 m); chunk_size 512; LOD levels; SEA_LEVEL_UINT16; output paths. Not loaded by engine; engine reads terrain_metadata.json.

---

## 7. Current State Assessment

### 7.1 What Works

- **Terrain streaming:** Phase A (worker) + Phase B (main thread) with frame budget; height cache for LOD 0; desired set and visibility logic clear.
- **Single terrain material:** One shader for all LODs; overview blend and fog; no next_pass hex (avoids double grid).
- **Hex overlay split:** Grid in terrain (world-space); selection/hover in compositor (one fullscreen pass, depth-reconstructed).
- **Hex math alignment:** world_to_axial, cube_round, axial_to_world consistent across camera, terrain shader, and compositor; pointy-top; HEX_SIZE_M as flat-to-flat and derived pointy-top radius used correctly.
- **Physical slice:** HexSelector builds mesh from height cache; lift and oscillation; rim in compositor.
- **Camera:** Orbit, pan, zoom, terrain clearance; F1–F6 for grid and hex debug.

### 7.2 What's Broken or Suspect

- **Compositor hex_dist:** Two-axis distance for grid (d1, d2 only); selection correctly uses d1, d2, d3. Grid line thickness could be slightly non-uniform at 60° directions.
- **Terrain at large world coordinates:** No camera-relative pass; possible precision drift at 2M+ m (documented in PROGRESS).
- **LoadingScreen chunk_name:** ChunkManager calls update_progress(..., "") so label shows "Loading  (44/529)".
- **LOD_DISTANCES_M / radius constants:** Defined in both constants.gd and ChunkManager; must be kept in sync manually.
- **Ungated prints:** e.g. "Camera initialized...", "DEBUG: Left Click Detected", "=== SLICE DIAGNOSTIC ===" in hex_selector.

### 7.3 Technical Debt

- **hex_grid_OLD.gdshader:** Left on disk; superseded by terrain in-shader grid + compositor.
- **HexSelector slice diagnostic:** Block of print() in set_selected_hex (lines 396–405) should be gated or removed.
- **Shared material from first chunk:** Camera gets terrain material via get_first_node_in_group("terrain_chunks"); order undefined.
- **Height cache:** Only LOD 0; get_height_at returns -1 if LOD 0 not loaded; slice can be flat or wrong in coarse regions.
- **ChunkManager _verify_no_overlaps:** Defined but never called.

### 7.4 Architecture Quality

- **Separation of concerns:** Terrain loader (stateless load + cache), chunk manager (streaming, visibility), camera (input + uniforms), hex selector (slice mesh), compositor (screen-space overlay). Clear.
- **Naming:** Scripts and nodes named by role; constants in one file with comments.
- **Hex single source of truth:** HEX_SIZE_M in constants; camera and compositor read it; terrain gets pointy-top radius from camera. One semantic size; two representations (flat-to-flat vs pointy-top radius) documented and consistent.
- **Documentation:** PROGRESS, HEX_OVERLAY_FINAL_SUMMARY, HEX_SELECTION_DIAGNOSTIC_REPORT, SSOT; useful for onboarding and hex pipeline.

---

*End of audit. No code was modified.*
