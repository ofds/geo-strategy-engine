# GeoStrategy Engine - Progress Tracker

**Last Updated:** February 16, 2026

---

## Session February 16, 2026 — Hex Grid Overhaul & Architecture Decision

### What was done (chronological)

**Phase 1: Codebase Cleanup**
- Deleted dead files: `rendering/hex_grid_OLD.gdshader`, `node_3d.tscn`
- Removed/gated 40+ debug print statements across all scripts
- Consolidated duplicated constants (`INNER_RADIUS_M`, `VISIBLE_RADIUS_ALTITUDE_FACTOR`) into single source in `config/constants.gd`
- Fixed loading screen empty chunk name
- Archived old findings docs to `docs/archive/`
- Produced comprehensive `docs/CODEBASE_AUDIT.md`

**Phase 2: Hex Grid Rendering Fix**
- Diagnosed Star of David artifacts in terrain shader hex grid
- Root cause 1: vertex winding was clockwise, but `edge_side` expects CCW → `inside` mask failed, producing triangles instead of hexagons
- Root cause 2: `show_hex_grid` uniform wasn't reaching the shader at high altitude because visible terrain was the overview plane (StandardMaterial3D), not chunk meshes
- Fixed winding (CCW vertices) but seg_dist + inside mask approach still produced artifacts at 3-way hex junctions
- **Replaced entire line rendering approach with hex SDF** based on research:
  - Old: `seg_dist` to 6 edge segments + `inside` mask + `fwidth` smoothstep (fragile, artifacts at vertices)
  - New: `hex_sdf` computes continuous signed distance to hex boundary; `abs(sdf)` gives distance to nearest edge; `smoothstep` for anti-aliased lines. No inside mask needed.
- Added **chunk-local coordinates** for precision: each chunk passes `chunk_origin_xz` as instance uniform; shader computes hex math in local space instead of 2M+ meter world coordinates

**Phase 3: Hex Grid SDF Orientation Fix**
- SDF was oriented for flat-top while axial coordinate system is pointy-top
- SDF at top vertex (0, 577.35) returned 77.35 instead of 0 → grid shape didn't match selection
- Fixed: `max(dot(p, vec2(0.866, 0.5)), p.y)` → `max(dot(p, vec2(0.5, 0.866)), p.x)`

**Phase 4: Hex Slice Unification**
- Slice was flat-top geometry (width 1000m) while grid/selection are pointy-top (radius 577.35m)
- Added `HEX_RADIUS_M = HEX_SIZE_M / sqrt(3.0)` to `constants.gd`
- Rewrote `hex_selector.gd`: pointy-top corners, updated `_hex_row_intersection_x`, `_is_inside_hex`
- Fixed `_is_inside_hex` SDF threshold: was using apothem, needed radius
- Fixed bounding box: max.x was 547.65 instead of 500 due to SDF threshold error

**Phase 4e: Selection-Grid Alignment**
- Selection used world-space hex math, grid used chunk-local → float32 precision caused ~(201, -360)m offset between them
- Added `get_chunk_origin_at()` to `chunk_manager.gd`
- Selection now uses chunk-local hex math matching the shader: get chunk origin → subtract → axial math → add back
- Cube component order unified with shader: `(q, -q-r, r)`, extract axial as `(rounded.x, rounded.z)`
- F7 comparison test confirms zero offset between grid and selection

**Architectural Decision: Cell System**
- After extensive debugging, concluded that scattered hex math (magic numbers in shader, camera, selector, compositor) is the root cause of recurring alignment/orientation bugs
- Researched spatial tessellation patterns (Paradox province maps, JFA Voronoi, Delaunay duality, watershed segmentation)
- **Decision: Build a Cell System with precomputed textures**
  - Cell ID texture + boundary distance texture per chunk
  - Shader reads textures for grid lines (no SDF, no axial math)
  - Selection reads cell ID texture (no world_to_axial, no cube_round)
  - One backend generates both textures (HexBackend now, VoronoiBackend later)
  - Three-layer architecture: Cell Query API → Topology Graph → Geometry Backend

### Current state

**What works:**
- Terrain streaming (LOD 0-4, 16-bit elevation, Europe region) ✅
- Camera (WASD, orbit, zoom 500m-5000km) ✅
- Hex grid rendering (SDF-based in terrain shader, chunk-local) ⚠️ Star of David artifact returned after SDF orientation fix
- Hex selection (chunk-local math, aligned with grid) ✅
- Hex slice (pointy-top, correct bounding box, lifts on selection) ✅

**Known issues:**
- Star of David / triangle artifacts visible in hex grid — SDF orientation and axial coordinate system not fully consistent. Will be resolved by cell texture approach (eliminates all analytical hex math from shader).
- Overview plane doesn't show hex grid (uses StandardMaterial3D, not terrain shader)
- Compositor `hex_dist` uses only 2 axes for grid lines (3 needed for full hex)

**Next: Cell System Architecture (Phase A)**
- Exploration: examine chunk texture pipeline, determine texture format/resolution for cell ID + boundary distance
- Implementation: generate cell textures per chunk, shader reads textures for grid lines, selection reads cell ID

---

## 📂 Project Structure & Key Files

| File | Status | Description |
|------|--------|-------------|
| **`core/terrain_loader.gd`** | ✅ Stable | Stateless chunk loading: 16-bit PNG, LOD mesh/collision, shared terrain material (terrain.gdshader), height cache. |
| **`core/terrain_worker.gd`** | ✅ Stable | Phase A worker: PNG decode + mesh arrays on WorkerThreadPool; no node refs. |
| **`core/chunk_manager.gd`** | ✅ Stable | Terrain streaming: desired set, async Phase A/B, visibility, deferred unload. Sets `chunk_origin_xz` instance uniform per chunk. `get_chunk_origin_at()` for selection alignment. Overview plane at Y=-20 for gap filling. |
| **`core/hex_selector.gd`** | ✅ Working | Physical hex slice: pointy-top geometry (HEX_RADIUS_M), mesh from height cache, walls, lift + oscillation. Rim drawn in compositor. |
| **`rendering/terrain.gdshader`** | ⚠️ Grid artifacts | Terrain: elevation/slope color, water, overview blend, fog, edge fade. Hex grid via SDF (chunk-local coords). SDF orientation issue causing Star of David — to be replaced by cell texture approach. |
| **`rendering/hex_overlay_screen.glsl`** | ✅ Stable | Screen-space compositor: depth unproject, selection rim/cutout/darken, hover. Grid drawing disabled (draw_grid_lines = false). |
| **`rendering/hex_overlay_compositor.gd`** | ✅ Stable | CompositorEffect: loads GLSL, packs params, dispatches compute. |
| **`rendering/basic_camera.gd`** | ✅ Working | Orbital camera, hex hover/selection via chunk-local math, terrain + compositor uniforms, F1-F7 debug keys. |
| **`config/constants.gd`** | ✅ Stable | Central constants: HEX_SIZE_M, HEX_RADIUS_M, LOD, camera, paths. |
| **`scenes/terrain_demo.tscn`** | ✅ Stable | Main scene: TerrainLoader, ChunkManager, HexSelector, Camera3D, WorldEnvironment, UI. |
| `tools/process_terrain.py` | ✅ Stable | Python CLI: SRTM → chunks + overview + metadata. |

**Documentation:**
- `docs/PROGRESS.md` — This file (living progress tracker)
- `docs/CODEBASE_AUDIT.md` — Comprehensive project audit (Feb 16)
- `docs/GeoStrategy_Engine_SSOT.md` — Design document
- `docs/PHASE_4D_GRID_COMPARISON_REPORT.md` — Grid vs selection comparison data
- `docs/archive/` — Historical findings (overlay, decal, selection diagnostics)

---

## 🌍 Vision: Planetary-Scale Playground

**Core Concept:** The entire Earth is an explorable, interactive playground where real terrain shapes the experience. Not building a specific game yet — building the **system that could support many games**.

### What Makes This Unique

1. **Real-World Terrain as Foundation**
   - SRTM satellite data (30m resolution) for anywhere on Earth
   - Geography matters: mountains, valleys, coasts, plains affect everything
   - Terrain isn't decoration — it's the primary constraint and opportunity

2. **Nested Scale Interaction (Macro/Micro)**
   - **Macro view** (continental): World as hex/cell grid. Each cell is a ~1km tile. Strategic decisions, regional planning, exploration.
   - **Micro view** (street-level): Click into a cell, it physically lifts out — geological cross-section visible on sides. Place buildings, plan roads, develop on real terrain.
   - **World mode vs Edit mode**: World running (seamless, things flow between cells) vs world paused (one cell lifted, you're the planner, neighbors visible for context).
   - Inspired by SimCity 4 regions + Transport Fever connectivity.

3. **Intelligent Spatial Organization (Cell System)**
   - Three-layer architecture: Cell Query API → Topology Graph → Geometry Backend
   - **Phase 1 (current):** HexBackend — regular hex grid, analytical
   - **Phase 2 (future):** VoronoiBackend — terrain-aware cells following natural boundaries (ridgelines, rivers, watersheds)
   - Cell boundaries as precomputed textures (ID map + boundary distance field)
   - Same rendering/selection code works for both hex and Voronoi — backend is pluggable

### Potential Applications

- **Transport/city builder on real terrain** (cells as macro planning, real terrain constrains building)
- **Historical simulation** (e.g., Capitania: colonization of 1532 Brazil on real terrain)
- **4X strategy** (terrain = tactical advantage, not decoration)
- **Exploration/education** (interactive atlas, discover why geography shaped history)
- **Climate planning** (real watersheds, real flood zones, real terrain constraints)

---

## 🚀 Current System Status

**What works (Feb 16, 2026):**

- **Terrain**: 16-bit elevation, height/slope coloring, fog (altitude-adaptive), desaturation at altitude, water (elevation < 5m), edge fade, overview texture blend (15-180km altitude). Continental scale (LOD 0-4, Europe region).
- **Streaming**: Async Phase A (TerrainWorker) + Phase B (main thread, 8ms budget, min 1 step/frame). Height cache for LOD 0. Overview plane at Y=-20 for gap filling.
- **Hex grid**: SDF-based in terrain shader, chunk-local coordinates for precision. Pointy-top hexes, ~1km cells. ⚠️ Star of David artifact present — to be replaced by cell texture approach.
- **Hex selection**: Chunk-local math matching shader grid. Click → raycast → chunk origin → local axial math → world center. Aligned with visible grid (F7 verified, zero offset).
- **Hex slice**: Pointy-top geometry (HEX_RADIUS_M), height-sampled mesh, walls, lift animation (0→150m, ±3m oscillation). Rim in compositor.
- **Camera**: WASD pan, scroll zoom (500m-5000km), middle-mouse orbit, terrain clearance. Hex hover/selection via chunk-local raycast.

## 📊 Current Performance Benchmarks

**Platform:** AMD Radeon RX 9070 XT | **Region:** Europe (11,390 LOD 0 chunks)

| Metric | Value |
|--------|-------|
| FPS target | 180 (5.5 ms frame budget) |
| FPS actual | 180 avg, 1% low tracked |
| Draw Calls | ~21-38 |
| Loaded Chunks | 44-75 (continental zoom) |
| Initial Load | Stepped Phase B with loading screen |

---

## 📋 Backlog

### 🔴 Immediate (Cell System Foundation)

1. **Cell System Architecture — Phase A**
   - Generate cell ID texture + boundary distance texture per chunk (hex grid, analytical)
   - Terrain shader reads textures for grid lines (replaces SDF math)
   - Selection reads cell ID texture (replaces analytical axial math in shader)
   - Fixes Star of David artifact permanently
   - Establishes texture-based pattern for Voronoi transition

### 🟣 Near-Term (Polish & Visual Impact)

2. **Texture splatting** — Elevation and slope-based material blending (grass → rock → snow)
3. **Region system** — Load any part of Earth dynamically
4. **Better lighting** — Time-of-day, atmospheric scattering
5. **Camera improvements** — Smooth acceleration, zoom-to-cursor, double-click fly-to

### 🔵 Medium-Term (Intelligent Systems)

6. **Cell System — Phase B: Cell Query API + Topology**
   - Formal API: `cell_id_at()`, `neighbors()`, `cell_center()`, `distance_to_boundary()`
   - HexBackend implements API
   - Game systems depend on API, not hex math

7. **Cell System — Phase C: Voronoi Backend**
   - Terrain-aware seed generation (dense in mountains, sparse in plains)
   - JFA or CPU Voronoi → same texture format
   - Boundaries follow ridgelines, rivers, watersheds
   - Swap backend, nothing else changes

8. **Macro/micro drill-down** — Camera zoom into cell, interior detail, state machine
9. **Cell metadata** — Elevation stats, biome, area per cell
10. **Terrain analysis layers** — Heatmaps, slope, watershed visualization
11. **Info panel + minimap**
12. **River/road overlay**

### 🟢 Long-Term (Game Direction)

13. **Basic gameplay loop** — Tokens, movement, turn system
14. **Region boundaries** — GIS data
15. **Cloud layer** — Moving shadows at altitude
16. **Save/load** — Camera, cell state, persistence

**No gameplay commitment yet.** Engine stays game-agnostic until cell system and visual layer are polished.

---

## ⚡ Quick Start

1. **Run Demo**: **F5**
2. **Controls**:
   - **WASD**: Move
   - **Space (Hold)**: Speed Boost
   - **Mouse Wheel**: Zoom
   - **Middle Mouse**: Orbit
   - **Left Click**: Select Hex
   - **F1**: Toggle Hex Grid
   - **F7**: Grid comparison test (debug builds)
3. **Hex grid**: SDF-based in terrain shader (chunk-local). Selection uses matching chunk-local math.