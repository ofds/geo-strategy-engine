# Session Summary for Architect — Hex Selection & Grid Alignment

**Date:** February 16, 2026  
**Purpose:** Convey what we did, what we tried, and the main finding that points to an architectural decision.

---

## 1. What We Did Today (This Chat)

### Selection & coordinates

- **Visible LOD only:** Selection no longer uses the hit collider’s LOD. We always use `get_lod_at_world_position(hit_pos)` and `floor(cell_xz / chunk_size)` so we sample the same chunk texture as the one drawn. This fixed “selection on wrong chunk when ray hit a hidden coarser collider.”
- **Grid-cell center for slice:** Added `USE_GRID_CELL_CENTER_FOR_SLICE` (default true). Slice is placed at the **pixel center** in world space `(px+0.5)/512 * chunk_size` so it aligns with the **drawn** cell (texture pixel), not the metadata/analytical hex center. Slice is more centered on the visible cell.
- **Selection constraint:** Added `SELECTION_MAX_DISTANCE_FROM_CENTER_M` (apothem). We only confirm selection when the click is within that distance of the cell center; otherwise we treat as miss. Selection is no longer “free” everywhere.
- **Green marker (F9):** Still “projected 2D” = hit XZ on terrain. Only updates on **click**. (Separate from hover green below.)

### Terrain grid (Phase 1F)

- **8-direction neighbor sampling:** Replaced 4 (N/S/E/W) with 8 (N, NE, E, SE, S, SW, W, NW) in the shader so diagonal boundaries are detected. Grid looks a bit more hexagonal; still blocky.
- **Weighted boundary strength:** Axis-aligned neighbor +1.0, diagonal +0.707, then clamp; lines blend a bit.
- **Chunk edge:** Narrowed the strip where we hide the grid from 1.5 to 0.5 (in pixel-width terms) so the gap at chunk boundaries is smaller. Grid still not continuous across chunks; terrain seams/holes at chunk transitions reported.

### Debug visuals (clarified)

- **Two systems:** (1) **F9 selection viz:** red = hit, green = projected 2D (hit), blue = chunk origin, yellow = slice/cell center. Only updates **on click**. (2) **Hover viz:** red = hit, **green = hex center** (metadata or analytical). Updates **every frame** (every 3rd) as the cursor moves. So the green that “snaps as you move” is the **hover** green = computed hex center, not the hit.

---

## 2. What We Tried

| Change | Result |
|--------|--------|
| Pixel convention (Phase 1E): floor + texture_size in selection and shader | Slice a bit more centered; half-hex shift reduced but not gone. |
| V-flip option in chunk_manager | Added constant; not confirmed in-game; user said shift was diagonal so V-flip alone unlikely. |
| Grid-cell center for slice | Slice more aligned with visible cell; still “rotated” vs grid (see below). |
| Always use visible LOD (ignore hit collider) | Selection and grid from same chunk; clear improvement. |
| 8-direction sampling in shader | Grid slightly more hexagonal; still blocky; slice still off. |
| Selection constraint (apothem) | Selection only when click inside hex; “free” selection removed. |
| Narrower edge threshold at chunk | Grid gap at boundaries smaller. |

---

## 3. Main Finding: Two Different Grids

We ended up with a clear structural explanation for the mismatch.

**Terrain grid (what you see on the ground)**  
- Shader draws where **cell_id ≠ neighbor** (pixel boundaries).  
- So the “grid” is the **raster**: boundaries between **texture pixels** (axis-aligned in texture/world).  
- The “center” of each visible “cell” is the **pixel center** in world space.

**Computed hex (selection, hover, metadata)**  
- We use **hex centers** from axial/metadata (true hex geometry).  
- One point per hex in the **hexagonal lattice** (pointy-top, 60°).  
- That is precise for the hex definition.

So we have:

- **Pixel grid** = 512×512 samples, axis-aligned “cells,” centers = pixel centers.  
- **Hex lattice** = hexagons, centers = hex centers from (q,r).

They are **different coordinate systems**. The texture is a **rasterization** of the hex map; the drawn “cells” are rectangles (pixels), not hexagons. So:

- **Slice** can use pixel center (grid-cell) → aligns with the **drawn** cell but not with true hex edges.  
- **Hover green** uses hex center (metadata/analytical) → snaps to the **hex** grid, which does not match the **visible** pixel grid.  
- **Terrain grid lines** = pixel edges, so they look axis-aligned / blocky and “rotated” relative to the slice (hexagon).

So the mismatch is not a small bug; it’s **which grid is the source of truth**: the **pixel raster** (what we draw) or the **hex lattice** (what we compute for selection/hover).

---

## 4. Current State (for Architect)

- **Selection:** Constrained (apothem), uses visible LOD, slice at grid-cell center. More centered; still “off” and rotated vs the drawn grid.
- **Terrain grid:** 8-direction, weighted strength; looks a bit more hexagonal; still blocky; gap at chunk edges (narrower than before). Chunk seams/holes (terrain) still an issue.
- **Hover:** Already implemented (raycast → `_hovered_hex_center` → compositor). Green hover marker = hex center (metadata/analytical), so it snaps to the **hex** grid, not the **visible** pixel grid.
- **Yellow marker (F9):** Slice center at terrain height; often hard to see because the slice mesh sits on top of it.

---

## 5. What Feels Like an Architectural Decision

We’ve reached a point where fixing “grid and selection/hover all align” requires choosing:

1. **Which grid is canonical for drawing and interaction?**  
   - **Option A:** **Pixel grid** — treat the texture raster as truth. Draw grid as now (pixel boundaries); selection/hover use pixel center; no hex geometry in the shader. Slice and markers align with what you see; “hex” is the pixel blob.  
   - **Option B:** **Hex lattice** — treat axial/hex as truth. Draw the **terrain grid as hexagons** (hex edges in the shader, same orientation as slice); selection/hover use hex center. Then terrain grid, slice, and hover all use the same geometry.

2. **Chunk boundaries:** Grid continuity and terrain seams need either cross-chunk texture sampling (and/or neighbor chunk data) or mesh/placement fixes. Scope and approach are architectural.

3. **Hover highlight:** Already there; may need to be made more visible and aligned with whichever grid is chosen above.

We did not make these choices in this chat; we documented the cause and the options for the architect.

---

## 6. References

- **Handoff (earlier):** `docs/ARCHITECT_HANDOFF_HEX_SELECTION_SUMMARY.md`  
- **Alignment status:** `docs/HEX_SELECTION_ALIGNMENT_STATUS.md`  
- **Phase 1E (pixel convention):** `docs/PHASE_1E_PIXEL_CONVENTION_REPORT.md`, `docs/PHASE_1E_PIXEL_CONVENTION_AUDIT.md`  
- **Phase 1F (boundary rendering):** `docs/PHASE_1F_HEX_BOUNDARY_REPORT.md`  
- **Pipeline (world → pixel → cell):** `docs/CELL_SELECTION_DATA_PIPELINE.md`  
- **Progress:** `docs/PROGRESS.md` (Phases 1D, 1E, 1F)
