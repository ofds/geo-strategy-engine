# Phase 1C LOD Fix — Selection Uses Hit Chunk's LOD

**Status:** SUCCESS (implementation complete)

## Changes Made

- **LOD detection:** Reuse existing `get_lod_at_world_position(hit_pos)` in ChunkManager; no mesh metadata. Camera gets `hit_lod` once per click/hover and passes it into the cell query.
- **Cell texture loading:** `get_cell_id_at_position(world_pos, lod_hint)` now takes `lod_hint` (default -1). When `lod_hint >= 0` that LOD is used; when -1, LOD comes from `get_lod_at_world_position(world_pos)`. Texture is loaded for `(chunk_x, chunk_y, hit_lod)`; TerrainLoader cache key already includes LOD (`"lod%d_%d_%d"`).
- **LOD-specific mesh extent:** Added `_get_mesh_extent_for_lod(lod)`: `(512 >> lod)` vertices, spacing `_resolution_m * (1 << lod)`, extent = `(mesh_res - 1) * vertex_spacing`. LOD 0: 45990 m, LOD 1: 45900 m, LOD 2: 45720 m.
- **Chunk origin at hit LOD:** Chunk indices and origin are computed at the hit LOD: `chunk_size = _get_chunk_world_size(hit_lod)`, `cx/cy = floor(world_pos / chunk_size)`, `chunk_origin = (cx, cy) * chunk_size`. Grid bounds at LOD: `grid_lod_x = (_lod0_grid.x + (1<<lod) - 1) >> lod` (same for y).
- **Fallback center:** When metadata is empty, center comes from `get_hex_center_at_lod(hit_pos, hit_lod)` instead of LOD 0 only. `get_hex_center_lod0` now calls `get_hex_center_at_lod(world_pos, 0)`.
- **No LOD 0–only path:** Selection and hover both use the hit chunk’s LOD for texture, extent, and center; no hardcoded LOD 0 for the visible grid.

## Codebase Architecture

- **Chunk indexing:** Scenario B (LOD-specific). At LOD 0, chunk (cx, cy) has size 512×90 m; at LOD 1, chunk (cx, cy) has size 92160 m; indices are per-LOD.
- **LOD tracking:** No per-mesh metadata. LOD is derived from `get_lod_at_world_position(world_pos)` (which loaded chunk contains the point; finest LOD wins).
- **Cell texture naming:** `res://data/terrain/cells/lod{L}/chunk_{x}_{y}_cells.png`; x,y are the chunk indices at that LOD.

## Files Touched

- `core/chunk_manager.gd`: `_get_mesh_extent_for_lod`, `get_cell_id_at_position(world_pos, lod_hint)`, `get_hex_center_at_lod(world_pos, lod)`, `get_hex_center_lod0` → delegates to `get_hex_center_at_lod(..., 0)`.
- `rendering/basic_camera.gd`: Click path uses `hit_lod` and `get_cell_id_at_position(hit_pos, hit_lod)`, fallback center via `get_hex_center_at_lod(hit_pos, hit_lod)`. Hover path uses `hit_lod_hover` and same LOD for query and center.

## Rule Documented

**Cell system / selection LOD:** Selection and rendering use the same LOD, same texture, same mesh extent, and same chunk origin so that the selected hex and the visible grid stay aligned. Selection always uses the hit chunk’s LOD (from `get_lod_at_world_position`).

## Test Recommendations

1. **LOD 0 (street):** ~500 m altitude, grid on, click hex → green circle on center, lifted slice matches grid.
2. **LOD 1 (regional):** ~5–10 km altitude, click hex → same.
3. **LOD 2:** ~50 km if visible → same.
4. **LOD boundary:** Altitude where LOD 0 and LOD 1 both visible; click in each → both align.

## Evidence

After running the game: green circle and lifted hex should align with the hex grid at all tested zoom levels.
