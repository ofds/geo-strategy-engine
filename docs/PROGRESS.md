# GeoStrategy Engine - Progress Tracker

**Last Updated:** February 15, 2026

## 📂 Project Structure & Key Files

| File | Status | Description |
|------|--------|-------------|
| **`core/terrain_loader.gd`** | ✅ Stable | Stateless utility. Loads 16-bit PNGs via raw PNG parse, decimated meshes (LOD 0-4). Phase B split into micro-steps (MESH → SCENE → COLLISION). Collision only for LOD 0–1. **Two terrain materials:** LOD 0–1 use `shared_terrain_material` (with hex next_pass); LOD 2+ use `shared_terrain_material_lod2plus` (no overlay). In group `terrain_loader` for camera. LOD 4 uses normal 32×32 mesh (ultra path removed). |
| **`core/terrain_worker.gd`** | ✅ Stable | **Phase A worker (static class).** PNG decode + mesh data computed here so WorkerThreadPool never references scene nodes; avoids "previously freed" and editor freeze on stop. LOD 4 ultra path disabled; all LODs use full mesh path. Used via `Callable(TerrainWorker, "compute_chunk_data").bind(args)`. |
| **`core/chunk_manager.gd`** | ✅ Stable | Dynamic streaming. **Overview plane (safety net)**: if metadata has `overview_texture`, adds a single quad at Y = -20 m with unlit albedo texture to fill gaps where no mesh chunk exists; mesh chunks use the **unified terrain shader** which samples the same overview texture for continental color. Phase B: 8 ms budget; **at least 1 step per frame** when pending. DEBUG_DIAGNOSTIC (default off). Chunks in group `terrain_chunks`. |
| **`rendering/basic_camera.gd`** | ✅ Stable | Orbital camera (WASD/Zoom/Orbit) with terrain collision avoidance and speed boosting. |
| **`scenes/terrain_demo.tscn`** | ✅ Stable | Main entry point. Contains the chunk manager, camera, and lighting setup. |
| **`ui/loading_screen.gd`** | ✅ Stable | Simple progress bar for initial bulk chunk loading. |
| `config/constants.gd` | ✅ Stable | Single source of truth: LOD_DISTANCES_M, INNER_RADIUS_M, VISIBLE_RADIUS_ALTITUDE_FACTOR, LOD_HYSTERESIS, chunk sizes, memory budgets. ChunkManager reads these. |
| `tools/process_terrain.py` | ✅ Stable | Python CLI pipeline. Downloads SRTM data, merges, tiles into 512px 16-bit PNGs, then **generates continental overview texture** (4096×aspect PNG, elevation-based coloring) and writes `overview_texture.png` + metadata fields. |
| **`rendering/hex_grid.gdshader`** | ✅ Stable | **Hex overlay (next_pass).** Grid lines, hover highlight, selection cutout 15 m larger than slice (cut line), golden border, pulsed glow (rim breath), surrounding darken. Uses `depth_test_disabled` (grid visible; see-through possible). **View-angle fade:** overlay fades on back-facing surfaces (e.g. far side of mountains) via `camera_position` + `v_world_normal` and `smoothstep(-0.2, 0.35, facing)` so grid is much weaker through terrain. Two materials (LOD 0–1 with overlay, LOD 2+ without). |
| **`rendering/terrain.gdshader`** | ✅ Stable | **Terrain only.** Height/slope coloring, overview texture (15–180 km blend), fog, desaturation, water, edge fade. No hex code. |
| **`core/hex_selector.gd`** | ✅ Stable | **Physical hex slice.** Rebuilt with **clipped rectangular grid** (50 m step, hex boundary snap per row) for correct hex shape; polar grid removed (had caused spiral/twisted geometry). Top: grid triangulation + smooth normals; walls from ordered boundary (25 m step along 6 edges); golden rim at top. get_height_at(-1) uses fallback from boundary average; >20% fail triggers warning. Lifts 0→150 m, ±3 m oscillation. Cutout in hex_grid 15 m larger for cut line. |

## 🚀 Current System Status

**What works (Feb 15, 2026):**

- **Terrain**: 16-bit elevation (sea level stored as non-zero in PNG, mapped back to 0m in loader), height/slope coloring (green valleys → rock → snow peaks). **Fog**: fog end = max(1,200 km, altitude×4); fog color transitions to space-blue (200–1,200 km); fog start scales 50–250 km with altitude so mid-high view stays readable. High-altitude appearance: terrain desaturates and darkens; water becomes deeper blue. Edge-of-terrain fades into atmosphere (no hard rectangle). Smooth slopes (no staircase banding).
- **Streaming**: Async Phase A in **TerrainWorker** (static, no node refs); Phase B on main thread. Phase B: 8 ms budget, **guaranteed 1 step/frame** when queue non-empty (fixes “only 26 chunks load”). One micro-step per chunk (MESH → SCENE → COLLISION). Terrain visible after SCENE; collision only LOD 0–1. LOD 4 uses normal 32×32 mesh (ultra path removed to fix flat green planes). Initial load uses stepped Phase B with same guarantee. ChunkManager `_exit_tree` clears pending. Chunks in group `terrain_chunks`; camera hover raycast throttled to every 3rd frame. DEBUG_DIAGNOSTIC gated (default off).
- **Hex grid**: Shader-based 1km flat-top hexes, hover highlight, click-to-select. **Scale-aware selection**: above 20 km altitude = fragment-only (strong gold tint + thick border + darken); 5–20 km = blend to full lift; below 5 km = full dramatic lift + glow. Border/glow width and intensity scale with altitude so selection stays visible at continental zoom. Selection disabled on LOD 3+ terrain with “Zoom in to select” message. F1 toggle. Unified single-pass shader.
- **Camera**: WASD pan, scroll zoom (15% per step, proportional from 1 km to 5,000 km), middle-mouse orbit, terrain collision avoidance, Space for 10× speed boost. **Zoom out to 5,000 km** (continental view, e.g. all of Europe). Dynamic far plane: 2,000 km below 1,000 km altitude, 10,000 km above to avoid z-fighting at extreme zoom.
- **Region**: Europe (35-71°N, -12-45°E) at SRTM3 90m resolution. **Processed**: 68,400×43,200 master, 11,390 LOD 0 chunks (15,260 total), ~5 min with stream merge. Pipeline uses download+merge in one pass (one tile in RAM at a time); Alps (SRTM1) unchanged.
- **Streaming (Feb 2026):** Diagnostic driver in `tools/diagnostic_camera_driver.gd`. Europe-scale fixes applied: altitude-scaled visible radius, tiered inner/outer LOD, batched completions, smart deferred unload on region change, LOD-priority queue sort.
- **Water**: Ocean/sea (elevation < 5m) renders as blue; coastlines stable between zoom levels; low-lying land (5–50m) renders as land.
- **Integrated overview**: One rendering pipeline for all zoom levels. TerrainLoader loads the pre-rendered overview texture (4096×aspect PNG) and passes it to the **unified terrain shader** as a uniform. Every mesh chunk (LOD 0–4) samples it: overview blend 15–180 km altitude (full overview by 180 km so coarse LOD 3/4 is masked). One fog and one desaturation apply to the blended result. **At 3,000 km**: continental coloring from overview; **at 10 km**: full mesh detail and hex grid. A minimal **overview plane** at Y = -20 (unlit StandardMaterial3D, same texture) fills gaps where no chunk exists; it is rarely visible. No separate overview shader; camera updates only terrain material uniforms. Regions without an overview texture (e.g. Alps) fall back to mesh-only coloring (`use_overview` = false).
- **Continental scale (Google Earth–style)**: LOD distances 0–25 km, 25–75 km, 75–200 km, 200–500 km, 500 km+; **above 70 km altitude** finest LOD is 1 (no LOD 0) to avoid load-then-unload flash. Chunk scale-in 0.97→1.0 over 0.4 s for softer pop-in. Fog and terrain coloring scale with altitude; hex grid fades out by ~20 km.

## 📊 Current Performance Benchmarks

**Platform:** AMD Radeon RX 9070 XT | **Region:** Europe (11,390 LOD 0 chunks)

| Metric | Value |
|--------|-------|
| **FPS goal** | 180 (5.5 ms frame budget) |
| **FPS (actual)** | Target 120+ normal movement, 90+ during fast pan/zoom; 1% low tracked (worst of last 100 frames). Phase B: 8 ms/frame, min 1 step when pending. |
| **Draw Calls** | ~55 |
| **Loaded Chunks** | 44–75 (continental zoom); LOD 2–4 no collision |
| **Streaming** | Terrain shader samples overview texture at high altitude; Phase B micro-steps (MESH/SCENE/COLLISION) fill in mesh; overview plane at Y=-20 fills edge gaps. |
| **Initial Load** | Stepped Phase B (16 ms budget) so no one-frame spike; loading screen. |
| **FPS counter** | Rolling 60-frame average + 1% low; `[PERF]` warning if 1% low &lt; 60. |

## 📋 Session summary (Feb 15, 2026)

**Code audit fixes (top-priority, Feb 15):**
- **Fix 1 (multiple hex grids):** `_update_chunk_visibility()` is called immediately after each chunk completes Phase B step 2 (COLLISION) and is added to `loaded_chunks`, so coarse parents hide as soon as children exist. Also called every frame in `_process` while `_pending_phase_b` or `load_queue` is non-empty, so the grid stays single during active streaming. When both queues are empty, per-frame visibility is skipped.
- **Fix 2 (ungated prints):** basic_camera: "DEBUG: Left Click Detected" and "DEBUG: Could not find hex overlay material" gated behind DEBUG_DIAGNOSTIC. terrain_loader: "Generating mesh...", "Generated X vertices", "Generated X triangles" gated behind DEBUG_CHUNK_TIMING. ChunkManager per-chunk/per-frame prints were already behind DEBUG_STREAMING_TIMING or DEBUG_DIAGNOSTIC; startup prints kept.
- **Fix 3 (loading label):** ChunkManager passes current chunk key to `update_progress(current, total, chunk_key)` so the loading screen shows e.g. "Loading lod0_x12_y34 (44/529)". `_last_phase_b_completed_chunk_key` set when a chunk completes Phase B.
- **Fix 4 (single source LOD):** Continental LOD distances and streaming radii moved to `config/constants.gd`: `LOD_DISTANCES_M` [0, 50k, 75k, 200k, 500k], `INNER_RADIUS_M` 500000, `VISIBLE_RADIUS_ALTITUDE_FACTOR` 2.5. ChunkManager now uses `Constants.LOD_DISTANCES_M`, `Constants.INNER_RADIUS_M`, etc.; local constants removed.
- **Fix 5 (dead shaders):** Deleted `rendering/overview.gdshader` and `rendering/hex_overlay.gdshader` (and their `.uid` files). Overview plane uses StandardMaterial3D; hex overlay is `hex_grid.gdshader`.
- **Fix 6 (overlay alpha):** At the start of `hex_grid.gdshader` fragment(), `ALPHA = 0.0` and `ALBEDO = vec3(0.0)` are set explicitly so the overlay is transparent by default; only grid/hover/selection branches override. Reduces risk of future changes breaking transparency.

**Height pipeline diagnostics and flat-terrain investigation:**
- **Problem:** Terrain looked "sanded down" at LOD 0 (flat, featureless) when zoomed in below 10 km.
- **Diagnostics added (all gated behind DEBUG_DIAGNOSTIC):**
  - **Stage 1 (TerrainWorker):** When Alps center chunk (lod0 x67 y35) is loaded with DEBUG_DIAGNOSTIC, print `[HEIGHT] Raw uint16: min=X max=X sample=[...]` after PNG decode. Confirms raw 16-bit range (Alps expect wide range, e.g. 1000–50000+).
  - **Stage 2:** `[HEIGHT] Elevation meters: min=Xm max=Xm range=Xm` — elevation after uint16→meters conversion (Alps LOD 0 expect hundreds–thousands of meters range).
  - **Stage 3:** `[HEIGHT] Vertex Y: min=X max=X range=X (LOD=N, vertices=N)` — mesh vertex Y range; if range is tiny, heights are squashed.
  - **Stage 4:** `[HEIGHT] Normal sample: (x,y,z)...` — center normals; if all (0,1,0), normal computation is broken.
  - **Stage 5 (basic_camera.gd):** With Camera DEBUG_DIAGNOSTIC, once per second `[SHADER] altitude=X overview_blend=X`. At 5 km altitude, overview_blend should be 0.0 (pure mesh color).
  - **Stage 6 (ChunkManager):** With DEBUG_DIAGNOSTIC, `[MESH] Nearest chunks: lod0_x67_y35 (dist=Xkm verts=N)...` — LOD 0 should show ~262k vertices (512×512).
- **Verification prints:** `[VERIFY] Alps chunk... vertex_Y range=...`, `[VERIFY] Normal variance: X (expected > 0.1)`, `[VERIFY] At 5km altitude: overview_blend=0.0, mesh color active`.
- **Fix applied:** Shader altitude uniform now uses **orbit_distance** (when available) instead of **position.y**, so the terrain shader’s overview blend and LOD/visibility logic in ChunkManager use the same notion of altitude. Ensures at 5 km zoom, overview_blend = 0 and mesh-based terrain color is used.
- **TerrainWorker vs TerrainLoader verified:** Sea level (Constants.SEA_LEVEL_UINT16) and height formula match. Max elevation from args (metadata 4810 m). LOD 0 decimation: step = 1 (512×512 vertices). PNG filter reconstruction (_png_reconstruct_row, _paeth) identical. Result keys (vertices, normals, indices, height_data) match Phase B expectations.
- **How to use:** Enable **DEBUG_DIAGNOSTIC** on ChunkManager (Inspector) and **DEBUG_DIAGNOSTIC** on the Camera (basic_camera). Fly to the Alps so chunk lod0_67_35 loads to see worker diagnostics. Check console for `[HEIGHT]`, `[SHADER]`, `[MESH]`, `[VERIFY]`. After verification, leave DEBUG_DIAGNOSTIC off (default).
- **Log analysis (user run):** Shader and altitude behave correctly (overview_blend=0 at 4–5 km, LOD 0 chunks have 262k vertices). No `[HEIGHT]` worker lines appeared because the Alps center chunk (lod0 x67 y35) was never loaded—session used (66,42) and (57,57). **Root cause of “flat” feel:** Only **one** LOD 0 chunk is desired at low altitude (L0=1). With LOD 0 radius 25 km, only the chunk whose center is within 25 km gets LOD 0; neighbors (centers ~46 km) stay LOD 1 (65k verts). So most of the view is LOD 1 or coarser; the single LOD 0 chunk can be at the edge (nearest 19.9 km). **Fix:** LOD 0 distance increased to 50 km so a 3×3 of LOD 0 chunks loads when zoomed in (~46 km chunk size).
- **LOD stacking fix (zoom-in low-res / "snow" overlay):** Coarse chunks only hide when all 4 finer children are loaded. Expanding only LOD 0 to 2×2 hid LOD 1 but the LOD 2 parent still had only 1 of 4 LOD 1 children, so LOD 2 stayed visible and drew on top of LOD 0. **Fix:** `_expand_lod0_to_full_blocks(desired)` now expands **every** LOD 0–3 to a complete 2×2 block at that level; missing siblings are added so each coarse parent gets all 4 children and is hidden. Zoomed-in view shows only the finest requested LOD (no LOD 2/3 overlay).

**LOD diagnostics and terrain polish (same day):**
- **Problem A (LOD 0 at low altitude):** Added DEBUG_DIAGNOSTIC (ChunkManager, default off). When enabled, once per second: `[LOD]` lines print camera alt, nearest chunk, desired LOD counts, queue front, Phase B backlog, min LOD allowed, and altitude gate (above70km=Y/N). **LOD 0 priority:** When altitude < 70 km, load queue is sorted so finer LOD loads first (priority += lod * 2.0). When altitude < 15 km and Phase B backlog > 2, do at least 3 Phase B steps per frame so LOD 0 chunks complete faster. Visibility: coarse chunks hide when all 4 finer children are loaded.
- **Problem B (visual polish):** (1) **Water threshold**: 50 m → 5 m in `terrain.gdshader` and `process_terrain.py`; coastlines stable. (2) **Flat terrain:** Low-elev micro-detail only (0–50 m coastal, 50–150 m plains, 150–300 m low hills in shader and overview). **(Rollback)** Hash noise and latitude tint were removed—they caused visible grid lines (“Interstellar” effect) and possible positioning confusion; overview reverted to elevation-only coloring (noise/latitude removed from Python). **Overview plane alignment:** Replaced centered PlaneMesh with explicit quad: vertices (0,0,0)–(overview_w, 0, overview_h), node at (0, -20, 0), UV (0,0)=world (0,0). Macro view (Europe) now aligns with chunk grid.

**Unified terrain + overview (one pipeline):**
- **TerrainLoader**: Load overview texture from `terrain_metadata.json`; set shader params `overview_texture`, `overview_origin`, `overview_size`, `use_overview`. Fallback world size = grid × chunk_size × resolution (matches pipeline).
- **terrain.gdshader**: Sample overview texture; blend with mesh color by altitude (smoothstep 15–180 km). Single fog/desaturation applied to blended color. Overview UV: no Y flip; clamp to [0,1] for correct stitching.
- **ChunkManager**: Overview plane at Y = -20 with unlit `StandardMaterial3D` (safety net only). No custom overview shader.
- **basic_camera.gd**: Removed per-frame overview shader updates; camera updates only terrain material.
- **Removed**: `rendering/overview.gdshader` and `.uid`.

**Fog and visibility:**
- Fog end floor 1,200 km, altitude×4; fog color → space blue 200–1,200 km; fog start 50–250 km by altitude (clearer center at high altitude).

**Seamless loading/transitions:**
- Overview blend 15–180 km (aligned with LOD so coarse mesh is masked by overview).
- Altitude-based min LOD: above 70 km do not use LOD 0 (avoids load-then-unload flash).
- Chunk scale-in: 0.97 → 1.0 over 0.4 s (softer pop-in).

**Hex overlay decoupling (Feb 2026):**
- **Terrain shader**: All hex logic removed (no grid, no hover, no selection lift). Terrain only: elevation, slope, fog, overview, water, edge fade.
- **Hex overlay**: New `rendering/hex_grid.gdshader` with `depth_draw_never`, `depth_test_read`, `render_priority = 1` as terrain material `next_pass`. Grid lines, hover (white border + tint), selection: dark cutout (shadow beneath slice), golden border/tint/glow, surrounding darken. Vertex offset +5 m to avoid z-fighting.
- **Physical slice**: `core/hex_selector.gd` on selection calls `ChunkManager.get_height_at()` (TerrainLoader height cache). Builds top surface (grid inside hex) + 6 side walls, vertex colors (terrain + earth brown). Lifts 0→150 m over 0.3 s ease-out, then ±3 m oscillation; golden emissive rim. Deselect removes slice. Cutout in overlay gives "hole" effect.
- **Camera**: Updates hex overlay material (next_pass) for altitude, hovered_hex_center, selected_hex_center, selection_time, show_grid; terrain material only for altitude, camera_position, terrain_center_xz, terrain_radius_m.
- **Removed**: `rendering/hex_overlay.gdshader` (deprecated). Vertex lift removed in favour of fragment-only overlay + independent slice mesh.

**Hex grid lines fix (Feb 2026):**
- **Problem:** Hex grid lines were invisible at all altitudes (F1 toggle on, below 20 km). Overlay shader `hex_grid.gdshader` is applied as `next_pass` on the shared terrain material.
- **Cause:** The overlay used `depth_test_read` and a vertex offset `VERTEX.y += 5.0` so the overlay geometry was 5 m above the terrain. Fragments were therefore *further* from the camera than the depth buffer (terrain), so they failed the depth test and were discarded—the entire overlay never drew.
- **Fix (first):** Switched to `depth_test_disabled` and removed the vertex offset. The overlay drew on the same geometry and blended on top. Grid lines became visible, but **overlapping chunks** (LOD transitions, boundaries, coarse+fine briefly both visible) caused double/thick grid lines and grid visible "through" terrain (transparency).
- **Fix (depth test, Feb 2026):** Tried `depth_test_read` (no offset, then NORMAL*0.5, then view-dir offset)—grid stayed invisible (Godot depth/next_pass behavior). **Fallback applied:** Reverted to `depth_test_disabled` and **two materials**: LOD 0–1 with overlay, LOD 2+ without. Grid visible but **grid could show through the ground** (depth_test_disabled draws on all chunks).
- **Fix (grid through ground, Feb 2026):** Overlay must **never** use `depth_test_disabled`—it causes grid to draw through terrain. Tried fragment `DEPTH = FRAGCOORD.z - 0.0001`; grid disappeared again (Godot may not use fragment DEPTH for the test when `depth_draw_never`). **Stable solution:** Use `depth_test_read` and **vertex offset toward camera** (world-space view direction × bias in meters) so overlay geometry is strictly closer than terrain; tune bias so grid is visible and no see-through. Rule: `.cursor/rules/hex-overlay-depth.mdc`.

**Hex overlay depth — why we get “either visible or correct, never both” (root causes):**
- **Constraint A (no see-through):** Overlay must use `depth_test_read`. With `depth_test_disabled`, every chunk draws its grid; back chunks’ grids appear through front terrain.
- **Constraint B (visibility):** Overlay must be *closer* than terrain depth. Godot’s depth test is strict (fragment depth < buffer depth). Same depth (same geometry via next_pass) fails → grid invisible.
- **Why fragment DEPTH failed:** With `depth_draw_never`, the depth used for the test may be the rasterizer depth, not our `DEPTH` write; or next_pass runs in a different pipeline (e.g. transparent) where DEPTH is ignored for the test. So fragment bias is unreliable.
- **Working approach:** Move overlay *geometry* toward the camera in the vertex shader (world position += view_dir × bias_m). That changes the rasterized depth so we pass the test. Bias must be large enough to be visible in depth (non-linear; at 10 km, 2 m can be sub-pixel); too large and grid floats. Tune `depth_bias_m` (e.g. 10–20 m) so both: grid visible, no see-through.

**Hex slice polish and selection enhancements (Feb 2026):**
- **Slice borders (Task A):** Slice rebuilt with **polar grid**: 6 rings (0%, 20%, 40%, 60%, 80%, 100% of hex), 60 angular steps; outermost ring exactly on hex boundary. Top surface triangulated with smooth normals from height differences (terrain-like lighting). Side walls use same boundary vertices, flat bottom at min terrain height in hex − 40 m. Cutout in `hex_grid.gdshader` made 15 m larger than slice (CUTOUT_MARGIN_M) so a thin dark "cut line" is visible. Slice at ground level (lift_t=0) is visually seamless with terrain; per-pixel shading and normals used.
- **Slice geometry fix (same day):** Polar grid caused spiral/twisted slice mesh. **Reverted to clipped rectangular grid**: bounding box 2R×2R (R = hex_size/√3), 50 m grid step; per-row hex containment and boundary snap (left/right X from hex–row intersection); regular grid triangulation (no polar indexing). Boundary: walk 6 edges at 25 m step for walls and rim. Top normals from face accumulation; walls earth-brown, CCW winding; golden rim unchanged. get_height_at(-1) handled with 0 m fallback; warning if >20% of samples fail.
- **Enhancement ideas (Task B1):** "Hex Selection Enhancement Ideas" added to backlog in PROGRESS.md: particles, god rays, energy line, slice shadow, slice saturation, rim pulse, ripple, neighbor dimming — with difficulty, cost, and aesthetic notes.
- **Two enhancements implemented (Task B2):** (1) Slice surface gets subtle warm emission when lifted (StandardMaterial3D emission driven by lift factor in hex_selector `_process`). (2) Golden rim glow in hex_grid.gdshader uses a clearer pulse (0.7 + 0.3*sin(TIME*1.5)) so the selection "breathes".

## 🟢 Fixed Issues

- **Hex grid doubling/see-through (Feb 15, 2026):** Replaced `next_pass` overlay with screen-space compositor effect. Grid now renders in a single fullscreen compute pass using depth buffer reconstruction. Guarantees single draw per pixel, depth-correct rendering. Files: `rendering/hex_overlay_screen.glsl`, `rendering/hex_overlay_compositor.gd`. Old `hex_grid.gdshader` archived.

## 📋 Backlog — Bugs & Polish

### 🟡 Known Issues

- **FPS vs 180 goal**: Phase B 8 ms budget and min 1 step/frame, LOD 4 normal mesh, and DEBUG_DIAGNOSTIC (default off) are in place. If 1% low drops below 60, `[PERF]` reports Phase B time for tuning.
- **Terrain streaming fix (Feb 2026)**: After Phase A/B + TerrainWorker refactor, terrain was broken: only ~26 chunks loaded, flat green planes at horizon, FPS 6–14, LODs not upgrading. **Fixes applied:** (1) Phase B: 8 ms budget and **at least 1 step per frame** when pending (chunks always make progress). (2) LOD 4 ultra path **disabled**; LOD 4 uses normal 32×32 mesh (no flat planes). (3) Chunks added to group `terrain_chunks` so camera finds shared material without recursive search. (4) Camera hover raycast throttled to every 3rd frame. (5) DEBUG_DIAGNOSTIC (ChunkManager, default off): when enabled, [LOD] and [DIAG]/[FRAME] once per second; use to verify LOD 0 at low altitude, then set false.
- **Flat/sanded terrain at LOD 0 (Feb 2026)**: If terrain looks flat when zoomed in below 10 km, enable DEBUG_DIAGNOSTIC on ChunkManager and on Camera; fly to Alps and check [HEIGHT], [SHADER], [MESH], [VERIFY] in console. **Fix applied:** Shader altitude uniform now uses orbit_distance so overview_blend = 0 below 15 km. If diagnostics show raw uint16 range < 1000 or vertex Y range < 100 m, the issue is in data or decode (e.g. 8-bit PNG); otherwise LOD/decimation or normals.
- **`_add_to_height_cache` type (if it persists)**: Worker returns plain `Array` for `heights_for_cache`; if runtime still complains about typed array, convert at call site in ChunkManager before calling (e.g. build `Array[float]` from `computed.get("heights_for_cache", [])` and pass that), or have TerrainWorker return a typed array where supported.
- **LOD 3+ hex interaction**: Hex selection is disabled on LOD 3+ chunks (user sees “Zoom in to select”); hex shapes still distort on coarse LODs. Possible future: LOD-independent overlay (decals or separate grid mesh).
- **Hex grid fade tuning**: Grid visibility at different zoom levels can be refined (fade 5–20 km is in constants).
- **Hex grid through terrain (mitigated)**: With `depth_test_disabled`, grid can show through where chunks overlap (especially on mountains). **Mitigation:** view-angle fade (back-facing surfaces get less overlay). **Proper fix (backlog):** Screen-space hex overlay — one compositor/fullscreen pass that samples scene depth, reconstructs world XZ, draws grid only on frontmost surface.
- **Terrain loading feel**: Loading can look chaotic (chunks appear in arbitrary order). **Backlog:** Give loading visible logic — e.g. chunks fade in or scale in from center, load in a spiral/ring order from camera, or a subtle "wave" of detail so it feels intentional.
- ~~**Hex selection = terrain modification**~~ **Resolved (Feb 2026):** Hex grid and selection moved to `hex_grid.gdshader` (next_pass). Selection uses physical slice (`hex_selector.gd`) from height cache; no terrain vertex modification.

### Hex Selection Enhancement Ideas

Ideas for making the hex selection more visually striking while keeping the "piece of earth being examined" feel. Documented for discussion; two implemented this session (slice saturation boost, subtle rim pulse).

1. **Particle effects (dust/debris from lifted slice edges)** — GPUParticles3D/CPUParticles3D along hex boundary, falling when slice lifts. *Difficulty:* Medium. *Cost:* Low–medium. *Fit:* Enhances "lifting earth" drama.
2. **Volumetric light beam / god rays from above** — Soft cone of light on selected hex. *Difficulty:* Medium–high. *Cost:* Medium. *Fit:* Strong "divine examination" vibe.
3. **Energy/electricity along the cut line** — Animated line or emissive along hex edge. *Difficulty:* Low. *Cost:* Very low. *Fit:* Sci-fi "activated" feel.
4. **Slice casting real shadow on terrain below** — Slice in shadow pass so it casts shadow into the hole. *Difficulty:* Low. *Cost:* Negligible. *Fit:* Strongly reinforces depth and "real piece lifted".
5. **Slice surface saturation/vibrance when lifted** — Slightly increase saturation or tint on slice material with lift progress. *Difficulty:* Low. *Cost:* Negligible. *Fit:* "Activated" piece without changing shape. **Implemented.**
6. **Subtle rim pulse / glow intensity over time** — Golden rim emission oscillates gently (e.g. sin(TIME)). *Difficulty:* Low. *Cost:* Negligible. *Fit:* Selection "breathes". **Implemented.**
7. **Ripple/wave expanding from cut point** — Circular or hex ripple in overlay, expanding from center over ~0.5 s. *Difficulty:* Low–medium. *Cost:* Very low. *Fit:* "Impact" cue.
8. **Nearby hexes slightly dimming** — Neighbor hexes get slight darken (extend current surrounding darken to neighbors only). *Difficulty:* Medium. *Cost:* Low. *Fit:* Focuses attention.

## 📋 Backlog — Feature Ideas & Vision

### 🟣 Near-Term (Polish & Visual Impact)

1. ~~**Hex selection UX overhaul**~~ **Done**: Dramatic plateau lift with emissive golden edge glow, golden tint, surrounding darken, staggered animation. Deselect instant. Hover: thin white border + faint tint.

2. ~~**Europe-scale terrain**~~ **In progress**: Pipeline running for europe region (35-71°N, -12-45°E) at SRTM3 90m. Target: shareable GIF of full continent zoom.

3. ~~**Water/ocean shader**~~ **Done (basic)**: Elevation < 50m renders as blue. Coastlines visible. No wave animation yet.

4. **Better lighting**: Time-of-day sun angle with long shadows. Atmospheric scattering for golden-hour look.

5. **Camera feel improvements**: ~~Continental zoom (5,000 km max, dynamic far plane, altitude-scaled fog/terrain, edge fade)~~ done. Still to do: smooth WASD acceleration/deceleration, zoom-to-cursor (Google Maps style), double-click hex to fly camera to it.

6. **Terrain loading feel**: Make chunk loading look intentional rather than chaotic — e.g. fade-in or scale-in when chunks appear, load in a logical order (spiral from center, ring by distance), or a subtle "wave" of detail so the player senses the system has logic.

### 🔵 Medium-Term (New Systems)

7. **Screen-space hex overlay (fix grid through terrain)**: Replace next_pass overlay with a single fullscreen/compositor pass: sample scene depth, unproject to world XZ, run existing hex logic, draw grid only where fragment is frontmost. Eliminates see-through; requires compositor effect or equivalent (Forward+).

8. **Terrain-adaptive cell tessellation (replaces hex grid)**: Irregular Voronoi cells following natural terrain features (ridgelines, valleys, slope changes). Three possible algorithms: (A) Voronoi with terrain-weighted seeds (recommended), (B) Watershed segmentation, (C) Hex merge/split. Start with visual prototype before rebuilding interaction.

9. **Macro/micro drill-down system**: Hex selection becomes a *scale transition*. Click a hex → it lifts → camera dives inside → full LOD 0 detail (30m) revealed. Inside: individual ridges, flat buildable areas, slopes that constrain construction. Zoom out → camera pulls back → hex settles → contents abstracted. Uses existing LOD streaming (force LOD 0 for selected hex), hex selection animation, and async loading (detail loads during lift animation). Macro = strategic planning, micro = tactical building.

10. **Cell data layer**: Each cell gets elevation, slope, biome (auto-computed), owner, resources. Lazy computation. Foundation for gameplay. Build AFTER cell system finalized.

11. **Info panel + minimap**: Side panel for selected cell data. Minimap with camera viewport indicator.

12. **River/road overlay**: Vector data rendered as lines on terrain. Rivers as natural borders.

### 🟢 Long-Term — Game Direction

The engine's unique strength: **real-world elevation as a game mechanic**, not decoration. Height, slope, and geography directly affect gameplay.

**Most promising direction: Transport/city builder on real terrain.** Hexes are the macro planning layer (which regions to connect). Inside a hex, real terrain constrains building (slopes limit construction, valleys are routes, passes are expensive). Inspired by Transport Fever but on real-world geography where terrain difficulty comes from actual elevation data.

**Other viable concepts:**
- **Alpine tactical strategy**: High ground = vision/defense, valleys = supply, passes = chokepoints. Elevation IS the mechanic.
- **Climate/disaster simulator**: Water flows downhill using real elevation. Flood propagation through actual valleys. Sea level rise on real coastlines.
- **Trade route empire**: Historical networks where route cost = real slope. Players discover why real trade routes existed where they did.
- **Exploration/cartography**: Start blank, reveal real terrain through exploration. The zoom from hex to continent is the reward.
- **Contemplative map tool**: Beautiful interactive globe with handcrafted aesthetic. Ambient, explorative, shareable. Not a game.

**No commitment yet.** Engine stays game-agnostic until visual/interaction layer is polished enough to prototype.

### 🟢 Long-Term (Deferred)

11. **Basic gameplay loop**: Tokens, movement, turn system.
12. **Region boundaries**: Country/province borders from GIS data.
13. **Texture splatting**: Grass/rock/snow textures over color zones.
14. **Cloud layer**: Moving cloud shadows at high altitude.
15. **Save/load**: Camera position, cell state, persistence.

## 🏗️ Architecture Vision — Extensibility

### Current Problem: Everything Is Tangled

The hex grid, cell selection, and terrain rendering are all baked into one shader (`terrain.gdshader`). The hex math computes cell membership, draws the lines, AND handles selection in one block of GLSL. If the cell system changes (e.g., Voronoi, variable-size hexes, hand-painted regions), the entire shader must be rewritten. Selection logic shouldn't care about cell shape, and cell shape shouldn't care about selection effects.

### Target Architecture: Three Decoupled Concerns

**1. Cell Definition — "What are the cells?"**
- Pure data: cell ID, center point, boundary edges, neighbor list
- Currently: uniform 1km flat-top hex math
- Future: Voronoi, variable hexes, rectangles, hand-painted regions
- Abstracted behind a CellProvider interface:
  - `get_cell_at(world_x, world_z) → cell_id`
  - `get_cell_center(cell_id) → Vector2`
  - `get_distance_to_edge(world_x, world_z) → float`
  - `get_neighbors(cell_id) → Array[cell_id]`
- Implementations: HexCellProvider (current), VoronoiCellProvider (future), CustomCellProvider (hand-defined)

**2. Cell Rendering — "How do I draw the boundaries?"**
- Takes cell definition, draws outlines on terrain
- Doesn't care if cells are hexes or irregular polygons
- Just needs: "what cell is this point in?" and "how far to nearest edge?"
- Could be shader-based (current), decal-based, or separate mesh overlay

**3. Cell Selection — "What happens when I interact?"**
- Takes a cell ID from rendering/picking
- Applies visual effects (lift, glow, darken, tint)
- Doesn't care about cell shape — just needs center and boundary
- Emits signals: `cell_selected(cell_id)`, `cell_deselected(cell_id)`
- Future: multi-select, selection groups, lasso select

### GPU/CPU Bridge

The shader (GPU) needs: "am I inside the selected cell?" and "how far to nearest edge?" Currently this is computed inline with hex math. With a CellProvider on CPU, two options:
- **Uniform-based**: Pass cell center + radius to shader (works for simple shapes, current approach)
- **Texture-based**: Bake cell IDs into a texture (UV = world XZ). Shader samples texture to get cell ID. Works for any cell shape, scales to thousands of irregular cells. CPU prepares the texture when cells change, GPU reads it every frame.

### Configurability (Do First)

Before the architectural refactor, move hardcoded values to configurable resources:
- Terrain color zones (elevation thresholds + colors) → Resource file or exported vars
- LOD distance thresholds → exported on ChunkManager
- Hex size → runtime adjustable
- Fog distances → exported
- Camera speeds, zoom limits, clearance → exported on Camera
- Region selection → dropdown or config, not JSON editing

This is one session of work and makes everything easier to tune without touching code.

### Guiding Principle

When building new features, build them into the decoupled structure from the start. Don't add more logic to terrain.gdshader — instead, build the CellProvider interface and have the shader consume it. Each new cell type (Voronoi, merged hexes, etc.) becomes a new CellProvider, and rendering + selection just work.

**This is a design target, not an immediate task.** Implement gradually as new features are built.

## 🗺️ Execution Priority

**Short-term (next few sessions):**
- Verify Europe terrain loads and looks good at continental scale
- Camera feel improvements (item 5)
→ Goal: shareable GIF of Europe zoom

**After GIF milestone:**
- Adaptive cell tessellation prototype (item 6)
- Better lighting (item 4)
- Macro/micro drill-down prototype (item 7)

**Deferred until gameplay phase:**
- Items 8-15

## ⚡ Quick Start

1. **Run Demo**: **F5**.
2. **Controls**:
   - **WASD**: Move.
   - **Space (Hold)**: Speed Boost.
   - **Mouse Wheel**: Zoom.
   - **Middle Mouse**: Orbit.
   - **Left Click**: Select Hex.
   - **F1**: Toggle Hex Grid.
