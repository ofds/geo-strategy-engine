# GeoStrategy Engine - Progress Tracker

**Last Updated:** February 15, 2026

## 📂 Project Structure & Key Files

| File | Status | Description |
|------|--------|-------------|
| **`core/terrain_loader.gd`** | ✅ Stable | Stateless utility. Loads 16-bit PNGs via raw PNG parse (bypasses Godot 8-bit downcast), decimated meshes (LOD 0-4), collision & materials. |
| **`core/chunk_manager.gd`** | ✅ Stable | Dynamic streaming system. Manages load/unload queues, LOD hysteresis, and distance-based priority. |
| **`rendering/basic_camera.gd`** | ✅ Stable | Orbital camera (WASD/Zoom/Orbit) with terrain collision avoidance and speed boosting. |
| **`scenes/terrain_demo.tscn`** | ✅ Stable | Main entry point. Contains the chunk manager, camera, and lighting setup. |
| **`ui/loading_screen.gd`** | ✅ Stable | Simple progress bar for initial bulk chunk loading. |
| `config/constants.gd` | ✅ Stable | Global configuration (LOD distances, chunk sizes, memory budgets). |
| `tools/process_terrain.py` | ✅ Stable | Python CLI pipeline. Downloads SRTM data, merges, and tiles into 512px 16-bit PNGs. |
| **`rendering/hex_overlay.gdshader`** | ⚠️ Deprecated | Previous overlay approach. Replaced by unified `terrain.gdshader`. |
| **`rendering/terrain.gdshader`** | ✅ Stable | **Unified Shader**. Height/slope terrain coloring, distance fog, hex grid overlay, selection lift. |

## 🚀 Current System Status

**What works (Feb 15, 2026):**

- **Terrain**: 16-bit elevation, height/slope coloring (green valleys → rock → snow peaks), distance fog 50-200km, smooth slopes (no staircase banding).
- **Streaming**: Async chunk loading (WorkerThreadPool), 1 chunk/frame, height cache (100 FIFO), 4 concurrent background tasks. No multi-second freezes. 44-48 chunks loaded, 60+ FPS.
- **Hex grid**: Shader-based 1km flat-top hexes, hover highlight, click-to-select with terrain lift, F1 toggle. Unified single-pass shader.
- **Camera**: WASD pan, scroll zoom, middle-mouse orbit, terrain collision avoidance, Space for 10× speed boost.
- **Region**: Alps test region (45.5-48°N, 6-10.5°E). 576 LOD 0 chunks, 5 LOD levels, ~567MB on disk.

## 📊 Current Performance Benchmarks

**Platform:** AMD Radeon RX 9070 XT | **Region:** Alps Test

| Metric | Value |
|--------|-------|
| **FPS** | 60+ (smooth during streaming) |
| **Draw Calls** | ~55 |
| **Loaded Chunks** | 44-48 (stable) |
| **Initial Load** | ~10-15 frames (async, with loading screen) |

## 📋 Backlog — Bugs & Polish

### 🟡 Known Issues

- **LOD deformation**: Hex shapes distort on coarse LOD chunks (LOD 2+) because vertex density is too low to form hex edges. Options: disable hex interaction on coarse LODs, or investigate LOD-independent overlay (Decals or separate grid mesh).
- **Hex grid fade tuning**: Grid visibility at different zoom levels needs finer adjustment.
- **Hex selection = terrain modification**: Selection is implemented by modifying terrain (vertex lift, fragment overrides, discard). That can cause drip at boundaries and non-continuous hex borders. **Alternative design**: hex grid and selection as a **separate overlay** (e.g. decal layer or second mesh that draws hex outlines and selection effect without modifying terrain geometry) so borders stay continuous and the lift is a separate drawn layer.

## 📋 Backlog — Feature Ideas & Vision

### 🟣 Near-Term (Polish & Visual Impact)

These improve the look and feel of what already exists. No new systems required.

1. ~~**Hex selection UX overhaul**~~ **Done**: Flat plateau lift (140m, steep ramp in outer 10%), emissive golden edge glow, 22% golden tint + terrain pop (brightness/saturation boost on selected hex), surrounding darken 15%, floating oscillation only in interior (no border ondulations). Lift/glow/darken/tint staggered over ~0.3s. Deselect instant. Hover: thin white border + 8% tint.

2. **Europe-scale terrain**: Process all of Europe (35-72°N, -12-45°E) using SRTM3 (90m resolution) for continental coverage at ~7GB on disk. The streaming system already handles arbitrary region sizes — only the data pipeline needs to run. This transforms the zoom-out view from "edge of Alps" to "full continent with coastlines." Target: shareable GIF showing zoom from street-level Alps to continental Europe.

3. **Water/ocean shader**: Terrain at or near sea level currently renders as flat green. Add water rendering: blue color for elevation ≤ ~100m (sea level in normalized data), subtle wave animation, reflectance. Makes coastlines instantly visible at continental zoom. Critical for the Europe expansion to look good.

4. **Better lighting**: Time-of-day sun angle with long shadows across mountain ridges. Atmospheric scattering for golden-hour look. Dramatic improvement to screenshots and GIFs for near-zero code effort.

5. **Camera feel improvements**: Smooth acceleration/deceleration on WASD (currently instant). Edge-of-map soft boundaries. Zoom-to-cursor (like Google Maps — scroll wheel targets the point under the cursor, not just forward/back). Double-click hex to fly camera to it.

### 🔵 Medium-Term (New Systems)

These require new code and design but build directly on existing infrastructure.

6. **Terrain-adaptive cell tessellation (replaces hex grid)**: Instead of uniform 1km hexes stamped over terrain, generate irregular Voronoi cells whose boundaries follow natural terrain features (ridgelines, valleys, slope changes). Seed points placed at terrain features (valley floors, ridge peaks, plateau centers). Cells vary in size based on terrain complexity. Adjacency graph built from Voronoi neighbors. This is what makes Paradox game maps (EU4, CK3, Victoria 3) feel alive. **Approach**: Start with a visual prototype — generate cells and render as colored polygons to evaluate the look before rebuilding interaction systems. Three possible algorithms: (A) Voronoi with terrain-weighted seeds (recommended), (B) Watershed segmentation, (C) Hex merge/split based on terrain similarity.

7. **Hex/cell data layer**: Each cell gets a data struct: elevation, slope, biome (auto-computed from terrain), owner, resources. Lazy computation (only when hovered/selected). Foundation for all gameplay. Should be built AFTER the cell system is finalized (uniform hex or adaptive Voronoi).

8. **Info panel + minimap**: Side panel showing selected cell data. Minimap showing full region with camera viewport indicator. First real UI elements.

9. **River/road overlay**: Vector data (from OpenStreetMap or natural boundary datasets) rendered as lines on terrain. Rivers define natural borders. Roads connect settlements.

### 🟢 Long-Term (Gameplay)

These turn the engine into a game. Deferred until the visual/interaction layer is polished.

10. **Basic gameplay loop**: Place tokens (units, cities) on cells. Movement between adjacent cells. Turn system. This is where hex/cell size, camera feel, and interaction get validated against real gameplay.

11. **Region boundaries**: Country/province borders overlaid on terrain. Could use real-world GIS data or be player-defined.

12. **Texture splatting**: Actual grass/rock/snow textures layered on top of current color zones. Adds realism at close zoom.

13. **Cloud layer**: Subtle cloud shadows moving across terrain at high altitude. Atmospheric detail.

14. **Save/load**: Camera position, selected cell, game state persistence.

## 🗺️ Execution Priority

**Immediate (next session):**
- (Hex selection dramatic plateau/glow/darken and staggered animation completed.)

**Short-term (next few sessions):**
- Europe terrain processing (item 2)
- Water/ocean shader (item 3)
- Camera feel improvements (item 5)
→ Goal: shareable GIF of Europe zoom

**After GIF milestone:**
- Adaptive cell tessellation prototype (item 6)
- Better lighting (item 4)
- Cell data layer (item 7)

**Deferred until gameplay phase:**
- Items 8-14

## ⚡ Quick Start

1. **Run Demo**: **F5**.
2. **Controls**:
   - **WASD**: Move.
   - **Space (Hold)**: Speed Boost.
   - **Mouse Wheel**: Zoom.
   - **Middle Mouse**: Orbit.
   - **Left Click**: Select Hex.
   - **F1**: Toggle Hex Grid.