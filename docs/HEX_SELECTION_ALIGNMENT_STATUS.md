# Hex Selection Alignment — Current Status

**Last updated:** February 16, 2026

---

## What’s fixed

- **LOD:** Selection uses **visible LOD** (finest loaded at hit point), not the hit collider’s LOD. This removed the case where the ray hit a hidden coarser chunk and we sampled the wrong texture.
- **Centering:** With visible LOD + grid-cell center for the slice, the selected hex is **more centered** on the intended cell than before.
- **Green marker:** It is placed on the **terrain at the hit** (same XZ as raycast, Y = hit height), not on Y=0.

---

## What’s still off

### 1. Slice looks “rotated” vs the grid

- **Terrain grid:** Drawn in the shader where **cell_id ≠ neighbor** (N/S/E/W). So the “grid” is **pixel boundaries** — axis-aligned in texture/world XZ (horizontal and vertical lines in top-down view).
- **Slice (selected hex):** Drawn by `hex_selector` as a **pointy-top hexagon** (vertex at top, flat edges left/right, same as axial/selection math).

So the **grid is a square/pixel grid** and the **slice is a hexagon**. Their edges don’t match: the hexagon looks rotated (e.g. ~30°) relative to the axis-aligned grid. That’s expected with the current design, not a bug in one of them.

**Phase 1F fix (implemented):** Terrain grid now uses **8-direction neighbor sampling** (N, NE, E, SE, S, SW, W, NW) so diagonal edges (hex-like at ~60°) are detected as well as axis-aligned. Weighted boundary strength for smoother lines. Grid should look more hexagonal and align better with the slice. See `docs/PHASE_1F_HEX_BOUNDARY_REPORT.md` and PROGRESS.md Phase 1F.

### 2. Green marker “snaps” / not at hex center

- The green marker is the **projected 2D** point: same XZ as the **raycast hit**, on the terrain.
- So it is **not** the “center of the hex” — it’s the exact hit. It only moves when you click, so it can feel like it “snaps” to a new position each time.
- If it still looks like it snaps to a **grid** of positions (e.g. pixel centers), that could be from how the ray hits the mesh (e.g. hitting a pixel boundary or a specific vertex). No extra snapping is applied in code.

### 3. Slice still slightly off

- Centering is better but not perfect; small offset can remain from:
  - Pixel vs hex center (we use grid-cell center for the slice; true hex center can differ slightly).
  - Mesh/UV vs chunk (e.g. mesh extent or interpolation at edges).

---

## Summary

| Item              | Status |
|-------------------|--------|
| Use visible LOD   | Done   |
| Slice more centered | Improved |
| Grid vs slice rotation | Known: grid = pixel boundaries (axis-aligned), slice = pointy-top hex. Fix = draw grid as hexagons. |
| Green marker      | On terrain at hit; not hex center by design. |
| Small offset      | May need hex-aligned grid + optional hex-center slice to fully align. |

---

## Suggested next steps (for architect)

1. **Grid drawing:** Change terrain grid from “pixel boundary” lines to **hex boundaries** (pointy-top, same as slice) so grid and slice orientation match.
2. **Optional:** Use **hex center** (metadata/analytical) for the slice again and rely on hex-aligned grid for visual match; or keep grid-cell center and accept a small center offset for stability.
3. **Green marker:** Optionally add a second marker for “slice center” (yellow already) vs “hit” (red) so “projected 2D” (green) is clearly “hit on terrain” and not “cell center”.
