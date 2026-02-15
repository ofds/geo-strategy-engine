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

## 🚀 Current System Status (Phase 7 Complete)

*   **16-bit elevation**: Terrain loader parses PNG via FileAccess (IHDR/IDAT, zlib/deflate, PNG row filters) so elevation uses full 16-bit range—smooth slopes, no staircase banding.
*   **Terrain coloring**: Shader colors by elevation (lowland green → foothills → alpine → rock → snow) with ~200m smoothstep transitions, plus steep-slope rock override (normal.y &lt; 0.7).
*   **Distance fog**: Fog from 50km to 200km (blue-gray), camera position passed from `basic_camera.gd` each frame.
*   **Unified shader**: Single-pass terrain + hex grid; grid lines, hover, and selection raise unchanged on top of colored terrain.
*   **Known issues**:
    *   **LOD Deformation**: Hex shapes distorted on high-LOD (low-res) chunks.
    *   **Fade Tuning**: Hex grid visibility at zoom could be refined.

## 📊 Current Performance Benchmarks

**Platform:** AMD Radeon RX 9070 XT
**Region:** Alps Test

| Metric | Value | Notes |
|--------|-------|-------|
| **FPS** | **120 - 180+** | Excellent performance (Single-pass is faster than overlay). |
| **Draw Calls** | **~55** | Minimal overhead. |
| **Loaded Chunks** | **44 - 48** | Stable. |

## 📋 Backlog

### 🔴 High Priority
*   **LOD-Independent Overlay**: Investigate Decals or a separate high-res grid mesh to fix hex deformation on low-LOD terrain.

## 🔮 What To Do Next

1.  **Texture Splatting**: Add texture detail on top of current height/slope coloring (optional).
2.  **Hex Data Layer**: Attach gameplay data to hexes (biome, owner, unit count).

## ⚡ Quick Start

1.  **Run Demo**: **F5**.
2.  **Controls**:
    *   **WASD**: Move.
    *   **Space (Hold)**: Speed Boost.
    *   **Mouse Wheel**: Zoom.
    *   **Middle Mouse**: Orbit.
    *   **Left Click**: Select Hex (Pop-up).
    *   **F1**: Toggle Hex Grid.
