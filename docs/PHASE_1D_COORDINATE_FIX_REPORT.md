# Phase 1D — Coordinate System Investigation & Fix Report

**Date:** February 16, 2026  
**Status:** SUCCESS (implementation complete; in-game verification by Otto)

---

## Copy-paste block for architect

```
Status: SUCCESS (implementation complete; verification by Otto)

Investigation Findings:
- Coordinate flow in selection path: Raycast → hit_pos; LOD came from collision shape (LOD 0–1 only); get_cell_id_at_chunk used only world_pos.x/z; metadata center (2D) → hex_selector; slice Y from get_height_at(center). All cell math was already XZ-only.
- Coordinate flow in shader path: v_uv from mesh (grid indices → 0..1 over chunk XZ); texelFetch at pixel from v_uv; no Y. chunk_origin_xz set but not used for sampling. Already 2D.
- Where 3D→2D projection was missing/incorrect: Projection was correct (only XZ used). The bug was using the wrong LOD: selection used collision shape LOD (0 or 1), while visible terrain at that (x,z) can be LOD 2 → wrong chunk texture → wrong cell.
- Why misalignment depended on terrain height: At low altitude we often see LOD 0/1 so collider LOD matched visible LOD; at mountains/zoom-out we see LOD 2 but ray hit LOD 0/1 collider → we sampled LOD 0/1 cell while grid was LOD 2 → large offset.
- Contradiction to hypothesis: The issue was not Y leaking into XZ math; it was LOD choice (collision LOD vs visible LOD).

What Was Implemented:
- core/chunk_manager.gd: project_to_cell_space(world_pos) → Vector2(x,z). run_selection_offset_test(20) for F8.
- rendering/basic_camera.gd: Selection uses visible LOD (get_lod_at_world_position) and project_to_cell_space; chunk (cx,cy) at that LOD; get_cell_id_at_chunk(pos_2d, cx, cy, hit_lod). F12 = offset test print (F8 reserved). F9 = debug viz (red=hit, green=proj 2D, blue=chunk origin, yellow=cell center at terrain).

Codebase Discoveries:
- Collision only for LOD 0–1; LOD 2+ terrain still hit LOD 0/1 colliders. get_lod_at_world_position returns finest loaded LOD containing point (XZ). Mesh UVs span full chunk; selection uses same chunk_size for pixels.

Deviations from Architectural Guidance: None.

Verification Test Results: (To be filled by Otto)
- Test 1 (Flat): ___
- Test 2 (Mountain): ___
- Test 3 (Elevation independence): ___
- Test 4 (Parallel lines): ___
- Test 5 (Debug viz): ___
- Automated (F12): ___

Evidence: Otto to attach screenshots and F12 console output.

Parallel Lines Status: Unverified; if unchanged, treat as separate LOD-boundary/texture-seam issue.

Recommendations for Next Step: If verification passes, consider blocky borders and parallel-line follow-up. Phase 1D section added to PROGRESS.md.
```

---

## Investigation Findings

### Coordinate flow in selection path

1. **Raycast** → `hit_pos` (Vector3: x, elevation_y, z).
2. **LOD** → `get_lod_at_world_position(hit_pos)` (uses only XZ AABB of loaded chunks; no Y).
3. **Previously (bug):** Chunk indices and LOD came from the **collision shape name** (`HeightMap_LOD0_66_42` → LOD 0, chunk (66, 42)). Collision exists only for **LOD 0 and LOD 1** (TerrainLoader skips collision for LOD ≥ 2).
4. **Cell lookup** → `get_cell_id_at_chunk(world_pos, cx, cy, lod)`:
   - `chunk_origin_x/z = (cx, cy) * chunk_size` (2D).
   - `local_x = world_pos.x - chunk_origin_x`, `local_z = world_pos.z - chunk_origin_z` (only XZ used).
   - Pixel: `px = round(local_x / chunk_size * (w-1))`, same for py (2D).
   - Texture sample → cell_id → `get_cell_info(cell_id)` → `center = (center_x, center_z)` (2D).
5. **Hex slice** → `hex_selector.set_selected_hex(center)`; slice position `(center_x, 0, center_z)`; terrain height at center from `get_height_at(center_x, center_z)` for mesh vertices (correct).

**Conclusion:** Selection math already used only XZ. The bug was **which LOD** was used: we used the collision shape’s LOD (always 0 or 1), while the **visible** terrain at that (x, z) could be LOD 2 when zoomed out or in mountain regions. So we sampled the wrong LOD’s texture → wrong cell → misalignment. That explains “misalignment depends on terrain height”: at high altitude or on mountains, visible LOD is often 2, but we were still using LOD 0/1 from the collider.

### Coordinate flow in shader path

- **Vertex:** `v_world_pos = MODEL_MATRIX * VERTEX`, `v_uv = UV`. Mesh UVs are set from grid indices (x, y) in terrain_worker: `UV = (x/(mesh_res-1), y/(mesh_res-1))`; vertex positions are (local_x, height, local_z) with `local_x = x * vertex_spacing`, so UV maps 0..1 over the chunk’s XZ extent. No Y in UV.
- **Fragment:** `pixel_coord = floor(v_uv * (tex_size-1) + 0.5)`; `texelFetch(cell_id_texture, pixel_coord)`; boundary = neighbor ID differs. All 2D.
- **chunk_origin_xz** is set per instance but not used in the current cell sampling (UV is from mesh). So shader path is already XZ-only.

### Where 3D→2D projection was missing/incorrect

- **Projection itself was not wrong:** All cell/chunk math used only `world_pos.x` and `world_pos.z`. Y was not used in cell identity.
- **Wrong LOD was used:** Selection used the LOD of the **collision shape** we hit (LOD 0 or 1 only), instead of the LOD of the **visible** chunk at that (x, z). So we effectively queried “cell at (x,z) in LOD 0” while the user saw “grid at LOD 2” → wrong cell, height-dependent misalignment.

### Why misalignment depended on terrain height

- **Not** because elevation Y was mixed into XZ math.
- **Because** at low altitude / flat terrain we often see LOD 0 (or 1), so the collider’s LOD matched the visible LOD; at high altitude or mountains we often see LOD 2, but the ray still hit a LOD 0/1 collider (finer chunks are still in the scene, just hidden). So we sampled LOD 0/1 cell while the visible grid was LOD 2 → large apparent offset.

### Contradictions to original hypothesis

- The hypothesis was “3D terrain positions mixed with 2D cell positions” and “elevation Y incorrectly affects XZ.” In code, XZ was already used consistently for cell/chunk. The real issue was **LOD choice** (collision LOD vs visible LOD), not 3D/2D mixing.

---

## What Was Implemented

- **core/chunk_manager.gd**
  - Added `project_to_cell_space(world_pos: Vector3) -> Vector2`: returns `Vector2(world_pos.x, world_pos.z)`. Documented as flat-mode vertical projection; future sphere mode would use lat/lon.
  - Added `run_selection_offset_test(num_samples: int = 20) -> Dictionary`: samples random world positions (within loaded extent), uses visible LOD + 2D projection for cell lookup, compares metadata center vs analytical center, returns min/max/mean/std offset and pass (max < 10 m, std < 5 m).
- **rendering/basic_camera.gd**
  - **Selection (click):** Use **visible LOD** only: `hit_lod = get_lod_at_world_position(hit_pos)`. Project to 2D: `cell_xz = project_to_cell_space(hit_pos)`. Chunk at visible LOD: `sel_cx = floor(cell_xz.x / chunk_size)`, `sel_cy = floor(cell_xz.y / chunk_size)`. Call `get_cell_id_at_chunk(pos_2d, sel_cx, sel_cy, hit_lod)` with `pos_2d = Vector3(cell_xz.x, 0, cell_xz.y)`.
  - **Diagnostics:** DEBUG_DIAGNOSTIC print block updated to “Phase 1D: visible LOD + 2D projection” and uses `sel_cx`/`sel_cy` and `cell_xz`.
  - **F8:** Runs `ChunkManager.run_selection_offset_test(20)` and prints min/max/mean/std and PASS.
  - **F9:** Toggles `_debug_selection_viz`. When on and a hex is selected, shows: red = raycast hit, green = projected 2D (Y=0), blue = chunk origin, yellow = cell center at terrain elevation. `_update_selection_debug_viz()` / `_hide_selection_debug_viz()`.
- **Projection layer:** Explicit `project_to_cell_space()` in ChunkManager; selection uses it and passes a position with Y=0 into the cell query so the pipeline is clearly “3D hit → 2D cell space → cell ID → metadata center → display at terrain height.”

---

## Codebase Discoveries

- Collision is only created for LOD 0 and 1 (`finish_load_step_collision` returns early for `lod >= 2`). So any raycast hit on terrain is always on a LOD 0 or 1 shape, even when the visible mesh at that location is LOD 2 (coarse chunk visible, fine chunks hidden).
- `get_lod_at_world_position` returns the **finest** loaded LOD whose chunk AABB contains the point (XZ only). So it correctly identifies the “visible” LOD when multiple LODs cover the same area.
- Mesh UVs in terrain_worker span the full chunk (vertex spacing = chunk_world_size / (mesh_res-1)); UV 0..1 = 0..chunk_size. Selection uses the same chunk_size for pixel mapping, so no extent mismatch.
- Hex slice Y is already correct: `hex_selector.set_selected_hex(center)` and slice uses `get_height_at(center_x, center_z)` for terrain height; no change needed there.

---

## Deviations from Architectural Guidance

- **No deviations.** We added explicit projection and use visible LOD as specified. We did not change cell metadata format, texture format, or chunk-local approach. Hex slice still uses 2D center + terrain height for display.

---

## Verification Test Results

(To be filled by Otto after running the game.)

- **Test 1 (Flat terrain):** [ ] PASS / [ ] FAIL — offset ____ m, notes: ____
- **Test 2 (Mountain slope):** [ ] PASS / [ ] FAIL — offset ____ m, notes: ____
- **Test 3 (Elevation independence):** [ ] PASS / [ ] FAIL — correlation: ____
- **Test 4 (Parallel lines):** [ ] improved / [ ] unchanged — notes: ____
- **Test 5 (Debug visualization F9):** [ ] markers align as expected
- **Automated test (F8):** [ ] PASS / [ ] FAIL — min ____ max ____ mean ____ std ____

---

## Evidence

Otto should attach:

- Screenshot of flat terrain selection (hex slice + visible grid aligned).
- Screenshot of mountain slope selection (hex slice + visible grid aligned).
- Screenshot of F9 debug viz with all markers aligned.
- Console output from F8 (offset statistics).
- Any SELECTION DEBUG print from a click (with DEBUG_DIAGNOSTIC on if desired).

---

## Parallel Lines Status

- **Current state:** Unverified in this session (no in-game run).
- **If unchanged:** May be LOD-boundary or texture-seam artifact; recommend separate pass (chunk edges, 512-pixel boundaries).
- **If reduced:** Would support that some artifact was due to LOD/visibility inconsistency, now reduced by using visible LOD.

---

## Recommendations for Next Step

- **If SUCCESS after Otto’s verification:** Consider blocky hex borders (anti-aliasing) and any parallel-line follow-up. Document Phase 1D as complete in PROGRESS.md (already added).
- **If PARTIAL:** If offset test still fails in some regions, report which LOD/area and whether F9 markers show a consistent mismatch (e.g. chunk origin vs mesh).
- **If FAILED:** Re-evaluate whether another LOD or coordinate path (e.g. mesh pick vs raycast) is needed; architect to decide.

---

## PROGRESS.md Update

Phase 1D section has been added to `docs/PROGRESS.md` under “Phase 1D — Coordinate System Fix (Feb 16, 2026)” with problem, investigation, solution, file changes, results, status, and next step.
