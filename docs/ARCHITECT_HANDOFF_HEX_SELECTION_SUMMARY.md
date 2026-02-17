# Architect Handoff — Hex Grid Selection Alignment (Summary)

**Date:** February 16, 2026  
**Purpose:** Summary of work done and current state so the architect can decide next steps.

---

## 1. Goal & Original Problem

- **Goal:** Fix hex grid selection misalignment — the “lifted” hex slice should line up with the visible grid.
- **Observed:** Misalignment depended on terrain height (flat ~100 m vs mountains ~500 m); parallel line artifacts; blocky hex borders (lower priority).
- **Original hypothesis:** Mixing 3D terrain positions with 2D cell space (e.g. elevation affecting XZ or wrong LOD/chunk used for selection).

---

## 2. What Was Done (Phase 1D & This Chat)

### 2.1 Root cause #1: Wrong LOD for cell lookup (Phase 1D)

- **Finding:** Selection was using the **collision shape’s LOD** (LOD 0–1 only) to pick which chunk texture to sample. The **visible** terrain at that (x, z) could be LOD 2 when zoomed out or on mountains. So we sampled LOD 0/1 cell while the user saw the LOD 2 grid → height-dependent misalignment.
- **Conclusion:** Cell math was already XZ-only. The bug was **which LOD** was used, not 3D/2D mixing.
- **Fix:** Use **chunk from hit collider name** when available (`HeightMap_LOD%d_%d_%d` → cx, cy, lod). If the ray doesn’t hit a named collider (e.g. no collision for that LOD), fall back to **visible LOD** at hit position (`get_lod_at_world_position(hit_pos)`) and `floor(cell_xz / chunk_size)` for chunk indices. Project to 2D cell space right after raycast (`project_to_cell_space(world_pos)` → Vector2(x, z)).

### 2.2 Code changes (Phase 1D + follow-ups)

- **core/chunk_manager.gd**
  - `project_to_cell_space(world_pos)` → `Vector2(world_pos.x, world_pos.z)`.
  - `run_selection_offset_test(num_samples)` for automated testing (F12).
  - `_get_cell_id_at_chunk_impl`: pixel from `round(local_x/z / chunk_size * (w-1))`; optional **V-flip** via `CELL_TEXTURE_V_FLIP` (see below).
- **rendering/basic_camera.gd**
  - Selection: get chunk from hit collider name first; else visible LOD + floor(cell_xz / chunk_size). Use `cell_xz = project_to_cell_space(hit_pos)` and `pos_2d = Vector3(cell_xz.x, 0, cell_xz.y)` for cell query.
  - **F12:** Run selection offset test (min/max/mean/std of metadata vs analytical center). F8 reserved by debugger.
  - **F9:** Toggle coordinate debug viz (red = hit, green = proj 2D, blue = chunk origin, yellow = cell center). Viz applied deferred and parented to scene root to avoid freeze.

### 2.3 Selection overlay not drawing

- **Cause:** Compositor treated “no selection” as `selected_hex_center.x < 900000`. World X is in the millions (e.g. 3_079_385), so the condition was always false and the golden rim/tint never drew.
- **Fix:** Raised sentinel to `999999999` in `config/constants.gd` and `rendering/hex_overlay_screen.glsl` so normal selection centers pass and the overlay draws.

### 2.4 F12 offset test returning 0 samples

- **Cause:** Test used random points in the union AABB of all loaded chunks; many fell in LOD 3+ (no cell textures) or had empty metadata, so samples were skipped.
- **Fix:** Test now builds a list of **loaded LOD 0–2 chunks only**, picks random points inside those chunks (20–80% along each axis), and uses analytical center when metadata is empty so samples still count.

---

## 3. Persistent Issue: Half-Hex Shift (Fixed Direction, ~Diagonal)

After the above, a **fixed** shift in the **same direction** remains — about **half a hex** — so the slice still doesn’t align with the grid. User reports the shift is **more diagonal** (not purely along one axis).

### 3.1 How we’re thinking about the pipeline

We documented the full path in **`docs/CELL_SELECTION_DATA_PIPELINE.md`**:

- **Python:** Pixel (i, j) ↔ world `(origin + (i/511)*chunk_size, origin + (j/511)*chunk_size)`; cell from axial at that world point; texture row 0 = north (local_z = 0).
- **Mesh:** UV = local / chunk_size; vertices span 0..chunk_world_size.
- **Shader:** `pixel_coord = floor(v_uv * (tex_size - 1) + 0.5)` (round to 0..511), then `texelFetch`.
- **Selection:** local = world − chunk_origin; `px/py = round(local_x/z / chunk_size * 511)`; `get_pixel(px, py)` → cell_id → metadata center → slice.

So in theory **world → chunk → local → pixel → cell_id** is consistent across Python, shader, and selection.

### 3.2 What we tried for the half-hex shift

| Attempt | Rationale | Result |
|--------|-----------|--------|
| **V-flip (texture row 0)** | If Godot/GPU treats texture row 0 as bottom, we’d read the wrong row → offset in Z. | Added `CELL_TEXTURE_V_FLIP` in `chunk_manager.gd`; when true, selection uses `py = (h - 1) - py_raw`. **Not tried in-game yet;** user said shift is diagonal, so V-flip alone is unlikely to fix it. |
| **Pixel convention (round vs floor)** | Round can sample the neighboring pixel at boundaries → wrong cell. | Discussed using `floor(local / chunk_size * (w-1))` for “pixel that contains point”; **not implemented.** Would need to align with Python/shader convention (pixel center vs pixel extent). |

### 3.3 Suspected causes (from pipeline doc)

- **Pixel convention:** round vs floor (or “pixel center” vs “pixel corner”) so we sometimes sample the neighbor pixel → wrong cell → half-hex shift. A **diagonal** shift could mean both X and Z have a one-pixel or half-pixel bias (e.g. at chunk edges or specific parity).
- **Texture V flip:** Would typically cause a shift mostly in one axis (Z). User said shift is diagonal, so this is a secondary candidate unless there is also an X convention issue.
- **Chunk origin / mesh extent:** Already verified; mesh spans full chunk_size; chunk from collider or visible LOD is used consistently.

---

## 4. Current State

- **Working:** LOD/chunk fix (selection uses correct chunk and LOD); selection overlay draws; F9 debug viz and F12 offset test; pipeline documented.
- **Remaining:** **Fixed ~half-hex shift in a consistent direction, described as diagonal.** No code change has been applied yet that targets a diagonal bias (floor convention or coordinated X/Z fix).

---

## 5. Recommendations for Architect

1. **Decide next step for the half-hex shift:**
   - **Option A:** Try **floor** for pixel indexing in selection (`px/py = floor(local / chunk_size * (w-1))`) and confirm Python texture generation uses the same “pixel contains point” convention; re-check shader so grid and selection stay in sync.
   - **Option B:** Add **diagnostics:** e.g. log at click (local_xz, px, py, cell_id, metadata_center) and compare with the same (local_xz → pixel) in Python or in the shader for a known chunk, to see if the drift is in world→pixel or in pixel→cell_id→center.
   - **Option C:** Revisit **Python texture pipeline** (and any export/import) for consistent “first pixel” convention (e.g. pixel (0,0) = which world corner, row 0 = top or bottom in file vs runtime).

2. **Optional:** If parallel line artifacts or blocky hex borders are still visible, treat as separate LOD-boundary / texture-seam / visual-refinement tasks after alignment is fixed.

3. **Reference:** Full data path and candidate causes are in **`docs/CELL_SELECTION_DATA_PIPELINE.md`**. Runtime toggle for V-flip: **`CELL_TEXTURE_V_FLIP`** in `core/chunk_manager.gd` (default `false`).

---

## 6. Key Files

| Area | File(s) |
|------|--------|
| Selection / click / F9 / F12 | `rendering/basic_camera.gd` |
| Cell lookup, offset test, V-flip | `core/chunk_manager.gd` |
| Pipeline & half-hex causes | `docs/CELL_SELECTION_DATA_PIPELINE.md` |
| Overlay sentinel | `config/constants.gd`, `rendering/hex_overlay_screen.glsl` |
| Phase 1D report | `docs/PHASE_1D_COORDINATE_FIX_REPORT.md` |
| Progress | `docs/PROGRESS.md` (Phase 1D section) |
