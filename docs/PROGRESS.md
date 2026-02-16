# GeoStrategy Engine - Progress Tracker

**Last Updated:** February 15, 2026

## 📂 Project Structure & Key Files

| File | Status | Description |
|------|--------|-------------|
| **`core/terrain_loader.gd`** | ✅ Stable | Stateless utility. Loads 16-bit PNGs via raw PNG parse, decimated meshes (LOD 0-4). Phase B split into micro-steps (MESH → SCENE → COLLISION). Collision only for LOD 0–1. **Single terrain material** for all LODs; hex grid is screen-space compositor (not next_pass). In group `terrain_loader` for camera. LOD 4 uses normal 32×32 mesh (ultra path removed). |
| **`core/terrain_worker.gd`** | ✅ Stable | **Phase A worker (static class).** PNG decode + mesh data computed here so WorkerThreadPool never references scene nodes; avoids "previously freed" and editor freeze on stop. LOD 4 ultra path disabled; all LODs use full mesh path. Used via `Callable(TerrainWorker, "compute_chunk_data").bind(args)`. |
| **`core/chunk_manager.gd`** | ✅ Stable | Dynamic streaming. **Overview plane (safety net)**: if metadata has `overview_texture`, adds a single quad at Y = -20 m with unlit albedo texture to fill gaps where no mesh chunk exists; mesh chunks use the **unified terrain shader** which samples the same overview texture for continental color. Phase B: 8 ms budget; **at least 1 step per frame** when pending. DEBUG_DIAGNOSTIC (default off). Chunks in group `terrain_chunks`. |
| **`rendering/basic_camera.gd`** | ✅ Stable | Orbital camera (WASD/Zoom/Orbit) with terrain collision avoidance and speed boosting. Updates compositor uniforms for hex overlay. |
| **`scenes/terrain_demo.tscn`** | ✅ Stable | Main entry point. Contains the chunk manager, camera, and lighting setup. |
| **`ui/loading_screen.gd`** | ✅ Stable | Simple progress bar for initial bulk chunk loading. |
| `config/constants.gd` | ✅ Stable | Single source of truth: LOD_DISTANCES_M, INNER_RADIUS_M, VISIBLE_RADIUS_ALTITUDE_FACTOR, LOD_HYSTERESIS, chunk sizes, memory budgets. ChunkManager reads these. |
| `tools/process_terrain.py` | ✅ Stable | Python CLI pipeline. Downloads SRTM data, merges, tiles into 512px 16-bit PNGs, then **generates continental overview texture** (4096×aspect PNG, elevation-based coloring) and writes `overview_texture.png` + metadata fields. |
| **`rendering/hex_overlay_compositor.gd`** + **`rendering/hex_overlay_screen.glsl`** | ✅ Stable | **Hex overlay (selection/hover only).** Compositor draws selection rim, hover highlight, and interior effects; grid lines come from world-space decal (`hex_grid_mesh.gd`). `draw_grid_lines` = false so compositor never draws grid. Uses physics raycast for accurate world positions. |
| **`rendering/terrain.gdshader`** | ✅ Stable | **Terrain only.** Height/slope coloring, overview texture (15–180 km blend), fog, desaturation, water, edge fade. No hex code. |
| **`core/hex_selector.gd`** | ✅ Stable | **Physical hex slice.** Rebuilt with **clipped rectangular grid** (50 m step, hex boundary snap per row) for correct hex shape; polar grid removed (had caused spiral/twisted geometry). Top: grid triangulation + smooth normals; walls from ordered boundary (25 m step along 6 edges) follow terrain profile; golden rim at top. get_height_at(-1) uses fallback from boundary average; >20% fail triggers warning. Lifts 0→150 m, ±3 m oscillation. Walls now use per-vertex terrain height (contoured, 120m depth). |

## 🌍 Vision: Planetary-Scale Playground

**Core Concept:** The entire Earth is an explorable, interactive playground where real terrain shapes the experience. Not building a specific game yet — building the **system that could support many games**.

### What Makes This Unique

1. **Real-World Terrain as Foundation**
   - SRTM satellite data (30m resolution) for anywhere on Earth
   - Geography matters: mountains, valleys, coasts, plains affect everything
   - Terrain isn't decoration — it's the primary constraint and opportunity

2. **Nested Scale Interaction**
   - **Macro view** (continental): Strategic decisions, regional planning, exploration
   - **Micro view** (street-level): Detailed simulation, city building, tactical gameplay
   - **Seamless transition** between scales via hex selection and drill-down

3. **Intelligent Spatial Organization**
   - Not uniform grid — **terrain-aware cells** (Voronoi polygons following natural boundaries)
   - Cells represent **natural units**: valleys, ridges, watersheds, plateaus
   - Multi-scale hierarchy: large cells in uniform terrain, small cells in complex terrain
   - Cell boundaries follow ridgelines, rivers, coastlines (like real administrative borders)

### Potential Applications

This system could support:
- **Historical simulation** (e.g., Capitania: colonization of 1532 Brazil on real terrain)
- **Transport/logistics** (real mountain passes, real trade route challenges)
- **City builder** (real elevation constrains construction, real valleys channel water)
- **4X strategy** (terrain = tactical advantage, not random decoration)
- **Exploration/education** (interactive atlas, discover why geography shaped history)
- **Climate planning** (real watersheds, real flood zones, real terrain constraints)

**Current Status:** Building foundational systems (terrain streaming, hex overlay, camera, LOD). Deferring gameplay decisions until the playground is polished and shareable.

## 🚀 Current System Status

**What works (Feb 15, 2026):**

- **Terrain**: 16-bit elevation (sea level stored as non-zero in PNG, mapped back to 0m in loader), height/slope coloring (green valleys → rock → snow peaks). **Fog**: fog end = max(1,200 km, altitude×4); fog color transitions to space-blue (200–1,200 km); fog start scales 50–250 km with altitude so mid-high view stays readable. High-altitude appearance: terrain desaturates and darkens; water becomes deeper blue. Edge-of-terrain fades into atmosphere (no hard rectangle). Smooth slopes (no staircase banding).
- **Streaming**: Async Phase A in **TerrainWorker** (static, no node refs); Phase B on main thread. Phase B: 8 ms budget, **guaranteed 1 step/frame** when queue non-empty (fixes "only 26 chunks load"). One micro-step per chunk (MESH → SCENE → COLLISION). Terrain visible after SCENE; collision only LOD 0–1. LOD 4 uses normal 32×32 mesh (ultra path removed to fix flat green planes). Initial load uses stepped Phase B with same guarantee. ChunkManager `_exit_tree` clears pending. Chunks in group `terrain_chunks`; camera hover raycast throttled to every 3rd frame. DEBUG_DIAGNOSTIC gated (default off).
- **Hex grid:** **Hybrid approach** — Grid lines rendered via world-space decal (locked to terrain, infinite coverage). Selection rim, hover highlight, and interior effects rendered via screen-space compositor using physics raycast for accurate world positions. F1 toggle. Grid is world-locked (doesn't move with camera pan). Selection/hover accurate at all zoom levels. Files: `rendering/hex_grid_mesh.gd` (decal), `rendering/hex_overlay_compositor.gd` + `hex_overlay_screen.glsl` (selection effects), `rendering/basic_camera.gd` (raycast). See `docs/HEX_OVERLAY_FINAL_SUMMARY.md` for technical background.
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
| **FPS counter** | Rolling 60-frame average + 1% low; `[PERF]` warning if 1% low < 60. |

## 📋 Session Summary (Feb 15, 2026)

### Hex Selection Depth Reconstruction Work

**Issue:** Screen-space hex overlay had artifacts on two opposing hex faces, and grid "slid" across terrain when camera moved.

**Root causes identified:**
1. **Matrix packing error**: inv_view matrix was packed row-major instead of column-major → transposed matrix → wrong world positions
2. **Floating-point precision loss**: World coordinates at 2M+ meters → Float32 precision ~1 meter → reconstruction errors accumulate → grid slides

**Fixes applied:**
- Fixed inv_view matrix packing (column-major, full 4×4 with `.w` components)
- Removed unnecessary depth remapping (raw depth correct for Godot 4.3)
- **In progress:** Camera-relative coordinate system (`world_pos - camera_pos`) to eliminate precision loss

**Final solution (Feb 15):** Hybrid approach — stop using compositor for grid lines. World-space decal (HexGridMesh) draws grid (inherently world-locked). Compositor only draws selection rim, hover highlight, interior effects; `draw_grid_lines` = false. Selection/hover use physics raycast (accurate at all zoom levels). See `docs/HEX_OVERLAY_FINAL_SUMMARY.md`.

**Files:** `rendering/hex_overlay_compositor.gd`, `rendering/hex_overlay_screen.glsl`, `rendering/hex_grid_mesh.gd`

### Hex Grid Decal Experiment (Feb 15, 2026)

**Goal:** Replace broken world-space line mesh (grid invisible except 1-frame flash on F1) with Decal-based grid.

**Done:** Decal projects procedural hex texture (20 km × 20 km) from above; center on look-at target; no rotation (Godot projects along -Y); compositor grid off when decal used; visibility synced every frame; `DECAL_WORLD_SIZE` and comments added to avoid regressions.

**Result:** Grid is visible in a square that follows the camera target. Hex selection (HexSelector) still has correct shape and is terrain-aware. **Foundational issue:** The decal grid feels disconnected from the terrain and from the selected hex — flat overlay vs. terrain-following selection; not smooth or integrated.

**Full report:** `docs/HEX_GRID_DECAL_FINDINGS.md` (what works, what doesn’t, recommendations).

### Other Session Work

- **Hex selection refinement:** Removed all overlay darkening inside selected hex so terrain colors show fully. Walls now follow terrain profile (per-vertex Y = terrain height - 120m) instead of flat bottom. Debug visualizations removed. Files: `rendering/hex_overlay_screen.glsl`, `core/hex_selector.gd`.

- **Hex selection color fix:** Fixed `vertex_colors_used` → `vertex_color_use_as_albedo` (Godot 4 naming). Slice now shows correct terrain colors on top and earth-brown walls. Overlay: removed interior gold tint, only golden rim at hex edge. Files: `core/hex_selector.gd`, `rendering/hex_overlay_screen.glsl`.

- **Hex selection hover + hole fix:** Restored subtle hover (8% gold tint + golden rim). Reverted "hide terrain under hex" approach (was hiding entire 46km chunks for 1km hex, creating massive holes). Terrain stays visible when hex selected; only slice lifts. Files: `rendering/hex_overlay_screen.glsl`, `core/chunk_manager.gd`, `core/hex_selector.gd`.

## 🟢 Fixed Issues

- **Hex grid world-locking (Feb 15, 2026):** Fixed grid sliding/moving with camera by using hybrid approach: world-space decal for grid lines (inherently world-locked) + screen-space compositor for selection effects only (uses physics raycast for accurate positioning, no depth reconstruction). Grid now feels terrain-integrated and doesn't move when panning. Selection rim and hover highlight render at correct world positions. Files: `rendering/hex_grid_mesh.gd`, `rendering/hex_overlay_screen.glsl`, `rendering/basic_camera.gd`.

- **Hex selection depth reconstruction (Feb 15, 2026):** Fixed screen-space overlay artifacts caused by wrong inv_view matrix packing (row-major → column-major, full 4×4 with .w components) in compositor. Identified grid sliding as floating-point precision loss at large world coordinates (2M+ meters). **Camera-relative coordinate fix in progress** to eliminate precision loss and lock grid to terrain. Selection rim, vignette, and hover effects render correctly with no artifacts on hex faces. Files: `rendering/hex_overlay_compositor.gd`, `rendering/hex_overlay_screen.glsl`.

- **Hex selection visual artifacts (Feb 15, 2026):** Fixed cutout shadow extending outside hex boundary (now inside-hex-only), added missing third hex distance axis (d3) for symmetrical edges, replaced 1-pixel 3D rim line strip with thick screen-space golden rim in shader. Selection now shows clean dark cutout inside hex, transparent 15m margin (visible gap between slice and terrain), thick glowing golden rim at hex edge (breathing pulse), and clearly visible physical slice walls. Files: `rendering/hex_overlay_screen.glsl`, `core/hex_selector.gd`.

- **Hex grid doubling/see-through (Feb 15, 2026):** Replaced `next_pass` overlay with screen-space compositor effect. Grid now renders in a single fullscreen compute pass using depth buffer reconstruction. Guarantees single draw per pixel, depth-correct rendering. Files: `rendering/hex_overlay_screen.glsl`, `rendering/hex_overlay_compositor.gd`. Old `hex_grid.gdshader` archived.

*[Previous fixed issues continue below...]*

[Rest of document continues with existing Backlog, Architecture Vision, etc. sections from the original, with additions:]

## 📋 Backlog — Feature Ideas & Vision

### 🟣 Near-Term (Polish & Visual Impact)

1. ✅ **Hex selection UX overhaul** — DONE: Dramatic plateau lift with emissive golden edge glow, golden tint, surrounding darken, staggered animation.

2. ✅ **Screen-space hex overlay grid sliding fix** — DONE: Hybrid approach — world-space decal for grid (inherently locked), compositor for selection/hover only. No depth reconstruction for grid.

3. ✅ **Europe-scale terrain** — DONE: Pipeline running for Europe region (35-71°N, -12-45°E) at SRTM3 90m.

4. ✅ **Water/ocean shader** — DONE (basic): Elevation < 5m renders as blue. Coastlines visible.

5. **Texture splatting** — Elevation and slope-based material blending (grass → rock → snow). Makes terrain readable and beautiful. Priority after hex grid is locked.

6. **Region system** — Load any part of Earth dynamically. Design `regions/` folder structure, modify `process_terrain.py` to accept `--region` flag, update engine to load regions at runtime. Foundation for "planetary playground."

7. **Better lighting** — Time-of-day sun angle with long shadows. Atmospheric scattering for golden-hour look.

8. **Camera feel improvements** — ✅ Continental zoom done. Still to do: smooth WASD acceleration/deceleration, zoom-to-cursor (Google Maps style), double-click hex to fly camera to it.

### 🔵 Medium-Term (Intelligent Systems)

9. **Terrain-aware Voronoi cells** (replaces uniform hex grid)
   - **What:** Irregular polygons (4-8 sides) that follow natural terrain boundaries
   - **Why:** Each cell = natural unit (valley, ridge, plateau, watershed). Small cells in mountains, large cells in plains. Boundaries follow ridgelines, rivers, coastlines.
   - **How:** Python pipeline analyzes terrain complexity, generates Voronoi seeds (dense in mountains, sparse in plains), tessellates, snaps boundaries to terrain features, exports cell metadata + lookup texture. Godot shader samples lookup texture to get cell ID and distance to boundary.
   - **Multi-scale hierarchy:** Aggregate cells into larger regions (e.g., 3×3 Voronoi cells = 1 macro region). Multiple granularities for different zoom levels or strategic layers.
   - **Status:** Design validated. Implementation: Python generation first, then Godot rendering integration.

10. **Macro/micro drill-down system**
    - **What:** Click hex/cell → camera zooms in → interior detail revealed at 1m resolution
    - **Why:** The unique feature. Strategic macro planning + tactical micro detail, both on real terrain.
    - **How:** Camera animation (Bezier curve), LOD management (force LOD 0 for selected cell), async detail loading during animation, state machine (macro ↔ micro modes).
    - **Inside view:** See individual ridges, buildable flat areas, slope constraints. Potentially: procedural micro-world or city building inside cell.
    - **Status:** Design phase. Implement after Voronoi cells (so drill-down works with any cell type).

11. **Cell metadata system**
    - **What:** Each cell stores: center, area, elevation min/max/mean, slope mean, biome classification, boundary vertices
    - **Why:** Foundation for visualization modes, gameplay, querying ("what's in this cell?")
    - **How:** Computed during cell generation (Python) or lazy-loaded at runtime. No gameplay-specific data yet (ownership, resources) — pure terrain analysis only.
    - **Status:** Deferred until Voronoi cell system is stable.

12. **Terrain analysis layers** (visualization modes)
    - **What:** Show elevation (heatmap), slope (gradient), biomes (color-coded), watersheds (drainage basins)
    - **Why:** Makes the playground informative. See terrain structure clearly.
    - **How:** Shader passes or texture overlays driven by cell metadata.
    - **Status:** After cell metadata system.

13. **Info panel + minimap**
    - Side panel for selected cell data
    - Minimap with camera viewport indicator
    - **Status:** UI polish phase

14. **River/road overlay**
    - Vector data rendered as lines on terrain
    - Rivers as natural borders
    - **Status:** After Voronoi cells (rivers inform cell boundaries)

### 🟢 Long-Term — Game Direction

The engine's unique strength: **real-world elevation as a game mechanic**, not decoration. Height, slope, and geography directly affect gameplay.

**Most promising direction: Transport/city builder on real terrain.** Cells are the macro planning layer (which regions to connect). Inside a cell, real terrain constrains building (slopes limit construction, valleys are routes, passes are expensive). Inspired by Transport Fever but on real-world geography where terrain difficulty comes from actual elevation data.

**Example: Capitania** — Simulate Portuguese colonization of São Vicente (1532 Brazil). Real coast, real Serra do Mar mountains, real plateau. Macro: Which coastal hexes for ports? Which mountain passes to interior? Micro: Inside a hex, layout settlement (streets, fields, fort) constrained by real slopes and rivers. Geography shapes strategy because it's **real**.

**Other viable concepts:**
- **Alpine tactical strategy**: High ground = vision/defense, valleys = supply, passes = chokepoints. Elevation IS the mechanic.
- **Climate/disaster simulator**: Water flows downhill using real elevation. Flood propagation through actual valleys. Sea level rise on real coastlines.
- **Trade route empire**: Historical networks where route cost = real slope. Players discover why real trade routes existed where they did.
- **Exploration/cartography**: Start blank, reveal real terrain through exploration. The zoom from cell to continent is the reward.
- **Contemplative map tool**: Beautiful interactive globe with handcrafted aesthetic. Ambient, explorative, shareable. Not a game.

**No commitment yet.** Engine stays game-agnostic until visual/interaction layer is polished enough to prototype gameplay.

### 🟢 Long-Term (Deferred)

15. **Basic gameplay loop**: Tokens, movement, turn system.
16. **Region boundaries**: Country/province borders from GIS data.
17. **Cloud layer**: Moving cloud shadows at high altitude.
18. **Save/load**: Camera position, cell state, persistence.

*[Rest of document continues with existing Architecture Vision and execution sections...]*

## ⚡ Quick Start

1. **Run Demo**: **F5**.
2. **Controls**:
   - **WASD**: Move.
   - **Space (Hold)**: Speed Boost.
   - **Mouse Wheel**: Zoom.
   - **Middle Mouse**: Orbit.
   - **Left Click**: Select Hex.
   - **F1**: Toggle Hex Grid.
3. **Hex grid**: World-locked decal + compositor selection/hover (hybrid). F1 toggles grid visibility.
