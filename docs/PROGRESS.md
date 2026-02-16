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
- **Cell textures (Phase 1A)** — per-chunk RGBA cell ID textures and cell_metadata.json generated for Europe ✅

**Known issues:**
- ~~Star of David / triangle artifacts~~ Resolved by Phase 1B (shader reads cell texture; no SDF).
- Overview plane doesn't show hex grid (uses StandardMaterial3D, not terrain shader)
- Compositor `hex_dist` uses only 2 axes for grid lines (3 needed for full hex)

**Phase 1B — Shader integration:** Complete. **Phase 1C — Selection integration:** Complete. Selection uses texture-based cell query + metadata; analytical hex kept as fallback when metadata not loaded. **Next:** "Easy Wins" (elevation, lighting, camera); grid visual refinement.

---

### Phase 1C — Selection integration (Feb 16, 2026)

- **Implemented:** Texture-based cell queries for selection. ChunkManager loads `cell_metadata.json` once at startup (skips if file > 400 MB to avoid OOM on Europe). `get_cell_id_at_position(world_pos)` samples LOD 0 cell texture at chunk UV; `get_cell_info(cell_id)` returns center and axial from metadata. basic_camera click/hover use texture + metadata for center; axial for labels from metadata when available.
- **Preserved:** Raycast and hex_selector interface unchanged. Analytical hex (`_hex_center_from_hit_chunk_local`, `_axial_round`, `_cube_round_shader`) retained for fallback and Phase 4d report.
- **Decisions:** Metadata in ChunkManager; texture cache reused from TerrainLoader via `get_cell_texture_for_selection`. LOD 0 only for queries. UV = chunk-local / chunk_size.
- **Status:** Phase 1 complete; cell system foundation in place. Full report: `docs/PHASE_1C_IMPLEMENTATION_REPORT.md`.

---

### Phase 1B — Shader integration (Feb 16, 2026)

- **Implemented:** Terrain shader uses cell ID textures instead of analytical hex SDF. Per-chunk RGBA texture sampled at fragment UV; RGBA decoded to 32-bit cell ID; boundaries detected by comparing center with four neighbors; grid lines where IDs differ. UVs added to terrain mesh (sync and async paths) and in terrain_worker.gd for async. Cell texture load only for LOD 0–2; `filter_nearest` on sampler.
- **Removed:** All analytical hex code from shader: `world_to_axial`, `axial_to_center`, `cube_round`, `hex_sdf`, `hex_grid_distance`; varying `v_local_xz`.
- **Decisions:** Cell texture in TerrainLoader (`_load_cell_texture`), FIFO cache 200; set per instance. LOD > 2 skip load (no warning).
- **Resolved:** Grid visibility fixed (per-chunk material for cell texture; camera updates all materials). Grid is functional but very pixelated; next steps should consider visual refinement (anti-aliasing, line softness).
- **Status:** Phase 1B complete. Full report: `docs/PHASE_1B_IMPLEMENTATION_REPORT.md`.

---

## Session 1: Terrain Color Refactor & Cell System Foundation (Feb 16, 2026)

Session 1 (Feb 16, ~7:00 AM–12:15 PM) had two major accomplishments: a data-driven terrain color system and the full Phase 1A cell texture generation pipeline.

### Terrain color system (data-driven)

Terrain coloring is now fully data-driven with a single source of truth.

- **`tools/generate_elevation_palette.py`** — Generates a 256×1 gradient PNG from shader color constants.
- **`rendering/terrain.gdshader`** — Removed hardcoded `COLOR_*` constants; added `elevation_palette` uniform sampler; terrain colors are sampled from the texture.
- **`core/terrain_loader.gd`** — Loads `data/terrain/elevation_palette.png` and sets the shader uniform.
- **`tools/process_terrain.py`** — Overview generation uses the same palette for consistency.

Artists can change terrain colors by editing the palette or the generator; no shader code changes required. Chunk meshes and the overview plane share the same colors.

### Cell texture generation (Phase 1A)

**Architecture decision:** After debugging hex grid SDF artifacts, we switched from analytical hex math to a texture-based cell system using the Paradox “province map” pattern (EU4, CK3, Imperator: Rome). Three-layer architecture: **Cell Query API** (game-facing, stable) → **Cell Textures** (per-chunk RGBA PNGs) → **Geometry Backend** (pluggable: HexBackend now, VoronoiBackend later).

**What was implemented:**

- **`tools/generate_cell_textures.py`**
  - **Pass 1 — Sparse cell collection:** Iterate all chunks at LOD 0–2; collect unique axial (q, r) in a single set (one ID per geometric hex across all LODs).
  - **Pass 2 — Compact IDs:** Sort cells by (r, q), assign sequential IDs 1..N; build id_map and cell registry.
  - **Pass 3 — Texture generation:** 32-bit RGBA encoding per pixel: R=(id>>24), G=(id>>16), B=(id>>8), A=id&0xFF (supports up to 4.2B cells).
- **Cell metadata:** `data/terrain/cell_metadata.json` — cell centers, axial coords, six neighbors per cell.
- **Pipeline:** Integrated with `process_terrain.py` (optional `--skip-cells`); can also run standalone with `--metadata` and `--output-dir`.
- **Verification:** Boundary alignment tests (shared edges between adjacent chunks); save/load round-trip test.
- **`tools/terrain_status.py`** — Quick status report (chunk counts, cell count from metadata without loading the full 8GB JSON).

**Issues encountered & solutions:**

| Issue | Problem | Solution |
|-------|---------|----------|
| Cell ID overflow (formula-based) | Encoding (q,r) directly produced IDs in millions for Europe, exceeded 65K | Compact sequential IDs 1..N from actual cells present |
| Bounding box overflow | Rectangular bounds counted empty space (e.g. Alps 322K in box vs 175K real) | Sparse collection: only cells that appear in loaded chunks |
| 16-bit limit | Alps at 30m has 175K cells > 65,535 | 24-bit RGB encoding (16M capacity) |
| Europe exceeds 24-bit | Europe at 90m has 29.4M cells > 16M | 32-bit RGBA encoding (4.2B capacity) |
| Pass 1 memory | `_ArrayMemoryError` allocating 2MB (fragmentation) | float32 in coordinate path + gc every 1000 chunks |
| Pass 1 progress | No feedback during long run | Progress per LOD (tqdm or 500-chunk print) |

**Key architectural lessons:**

- **Global coordinate mapping prevents seams:** All chunks use the same world-space cell coordinate system → perfect boundary alignment.
- **Sparse collection is essential:** Bounding-box count includes empty space; sparse collection counts only cells that appear in chunks.
- **32-bit RGBA is future-proof:** Continent-scale regions (e.g. Europe 29M cells) fit; no need for a larger encoding for foreseeable use.
- **Verification must be automated:** Save/load round-trip and boundary tests catch export/encoding bugs immediately.

**Cell count investigation:** Europe’s 29,358,100 cells were verified correct (not a bug). One global ID per geometric hex; ~2,500 unique cells per LOD0 chunk (46,080 m side); terrain area / hex area ≈ 29M. See `docs/CELL_COUNT_INVESTIGATION.md`.

### Session 1 current status

- **Europe terrain:** 11,390 LOD0 chunks, 90 m resolution, `terrain_metadata.json`, `elevation_palette.png`.
- **Cell textures:** 15,019 RGBA PNGs (LOD 0: 11,390; LOD 1: 2,881; LOD 2: 748) in `data/terrain/cells/lod{0,1,2}/chunk_*_cells.png`.
- **Cell metadata:** `data/terrain/cell_metadata.json` — 29,358,100 cells (centers, axial coords, neighbors).
- **Verification:** Passed (boundary alignment, save/load round-trip).
- **Status script:** `python tools/terrain_status.py` — fast summary including cell count (reads `total_cells` from JSON head, does not load full file).

### Next steps (after Session 1)

- **Phase 1B — Shader integration:** Replace hex SDF in `terrain.gdshader` with cell texture sampling; decode RGBA to cell_id in fragment shader; use for grid lines / cell boundaries. Eliminates Star of David artifact.
- **Phase 1C — Selection integration:** Selection reads cell ID from texture (or query API) instead of analytical world_to_axial; texture-based cell queries.

---

## 📂 Project Structure & Key Files

| File | Status | Description |
|------|--------|-------------|
| **`core/terrain_loader.gd`** | ✅ Stable | Stateless chunk loading: 16-bit PNG, LOD mesh/collision, shared terrain material (terrain.gdshader), height cache. |
| **`core/terrain_worker.gd`** | ✅ Stable | Phase A worker: PNG decode + mesh arrays on WorkerThreadPool; no node refs. |
| **`core/chunk_manager.gd`** | ✅ Stable | Terrain streaming: desired set, async Phase A/B, visibility, deferred unload. Sets `chunk_origin_xz` instance uniform per chunk. `get_chunk_origin_at()` for selection alignment. Overview plane at Y=-20 for gap filling. |
| **`core/hex_selector.gd`** | ✅ Working | Physical hex slice: pointy-top geometry (HEX_RADIUS_M), mesh from height cache, walls, lift + oscillation. Rim drawn in compositor. |
| **`rendering/terrain.gdshader`** | ✅ Phase 1B | Terrain: elevation/slope color, water, overview blend, fog, edge fade. Hex grid via cell texture sampling (decode RGBA → cell_id; boundary = neighbor ID differs). No analytical hex math. |
| **`rendering/hex_overlay_screen.glsl`** | ✅ Stable | Screen-space compositor: depth unproject, selection rim/cutout/darken, hover. Grid drawing disabled (draw_grid_lines = false). |
| **`rendering/hex_overlay_compositor.gd`** | ✅ Stable | CompositorEffect: loads GLSL, packs params, dispatches compute. |
| **`rendering/basic_camera.gd`** | ✅ Working | Orbital camera, hex hover/selection via chunk-local math, terrain + compositor uniforms, F1-F7 debug keys. |
| **`config/constants.gd`** | ✅ Stable | Central constants: HEX_SIZE_M, HEX_RADIUS_M, LOD, camera, paths. |
| **`scenes/terrain_demo.tscn`** | ✅ Stable | Main scene: TerrainLoader, ChunkManager, HexSelector, Camera3D, WorldEnvironment, UI. |
| `tools/process_terrain.py` | ✅ Stable | Python CLI: SRTM → chunks + overview + metadata. Optional cell texture step (or use generate_cell_textures.py). |
| `tools/generate_cell_textures.py` | ✅ Stable | Phase 1A: 3-pass sparse cell collection, 32-bit RGBA textures, cell_metadata.json. Europe: 29.4M cells, 15,019 textures. |
| `tools/terrain_status.py` | ✅ Stable | Status report: chunk counts, cell texture counts, cell count (without loading full metadata). |
| `tools/generate_elevation_palette.py` | ✅ Stable | Generates 256×1 elevation_palette.png from color constants; single source of truth for terrain colors. |

**Documentation:**
- `docs/PROGRESS.md` — This file (living progress tracker)
- `docs/CODEBASE_AUDIT.md` — Comprehensive project audit (Feb 16)
- `docs/GeoStrategy_Engine_SSOT.md` — Design document
- `docs/CELL_COUNT_INVESTIGATION.md` — Cell count analysis (Europe 29M cells, LOD/shared IDs, encoding)
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
- **Hex grid**: SDF-based in terrain shader, chunk-local coordinates for precision. Pointy-top hexes, ~1km cells. ⚠️ Star of David artifact present — Phase 1B will replace with cell texture sampling.
- **Cell textures (Phase 1A)**: Per-chunk RGBA cell ID textures and cell_metadata.json for Europe (29.4M cells, 15,019 textures). Verification passed. Not yet used in shader or selection (Phase 1B/1C).
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

1. **Phase 1A — Cell texture generation** ✅ *Done (Session 1)*
   - Cell ID textures (RGBA) per chunk, cell_metadata.json, sparse collection, 32-bit encoding. Europe: 29.4M cells, 15,019 textures.

2. **Phase 1B — Shader integration**
   - Terrain shader samples cell texture (replace SDF); decode RGBA → cell_id; grid lines from texture.
   - Fixes Star of David artifact permanently; establishes texture-based pattern for Voronoi.

3. **Phase 1C — Selection integration**
   - Selection reads cell ID from texture (or Cell Query API); replace analytical world_to_axial in selection path.

### 🟣 Near-Term (Polish & Visual Impact)

4. **Texture splatting** — Elevation and slope-based material blending (grass → rock → snow)
5. **Region system** — Load any part of Earth dynamically
6. **Better lighting** — Time-of-day, atmospheric scattering
7. **Camera improvements** — Smooth acceleration, zoom-to-cursor, double-click fly-to

### 🔵 Medium-Term (Intelligent Systems)

8. **Cell System — Phase B: Cell Query API + Topology**
   - Formal API: `cell_id_at()`, `neighbors()`, `cell_center()`, `distance_to_boundary()`
   - HexBackend implements API
   - Game systems depend on API, not hex math

9. **Cell System — Phase C: Voronoi Backend**
   - Terrain-aware seed generation (dense in mountains, sparse in plains)
   - JFA or CPU Voronoi → same texture format
   - Boundaries follow ridgelines, rivers, watersheds
   - Swap backend, nothing else changes

10. **Macro/micro drill-down** — Camera zoom into cell, interior detail, state machine
11. **Cell metadata** — Elevation stats, biome, area per cell
12. **Terrain analysis layers** — Heatmaps, slope, watershed visualization
13. **Info panel + minimap**
14. **River/road overlay**

### 🟢 Long-Term (Game Direction)

15. **Basic gameplay loop** — Tokens, movement, turn system
16. **Region boundaries** — GIS data
17. **Cloud layer** — Moving shadows at altitude
18. **Save/load** — Camera, cell state, persistence

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