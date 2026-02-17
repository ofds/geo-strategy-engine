# Phase 1F — Hex Boundary Rendering Report

**Date:** February 16, 2026  
**Status:** Test results from Otto (Feb 16).

---

## Terminology (what we mean in the tests)

- **Boundary (Test 3)** = the **terrain hex grid lines** (the lines drawn on the terrain by the shader where cell IDs change). *Not* the slice: the slice (golden elevated hex) has smooth borders; Test 3 is about the grid lines on the ground.
- **Chunk boundaries (Test 4)** = where two **terrain chunks** meet (each chunk is one 512×512 cell texture). The shader currently **hides the hex grid** in a narrow strip along each chunk edge (to avoid wrong lines from clamped sampling). So the grid is **not continuous** across chunks—there’s a visible “width” where no grid is drawn. Separately, you may see **terrain seams or holes** (see-through, mesh gaps) at chunk transitions; that can be mesh placement or LOD, not just the grid.

---

## Implementation Summary

**What was changed**

- **File:** `rendering/terrain.gdshader`
  - Replaced 4-direction neighbor sampling (N/S/E/W) with **8-direction** (N, NE, E, SE, S, SW, W, NW).
  - Boundary strength is a **weighted sum**: axis-aligned neighbor differing → +1.0, diagonal differing → +0.707; then `clamp(boundary_strength, 0.0, 1.0)`.
  - Same edge-threshold and slope fade as before; chunk boundary handling = **clamp** (neighbor coords clamped to texture; edge threshold suppresses lines at chunk seams).
  - Comments added: shape-agnostic design, future merge_group_id, chunk clamp limitation.

**Approach**

- 8-direction sampling (no hex SDF).
- Chunk boundary: clamp; no cross-chunk sampling.
- Line rendering: weighted boundary strength (smooth blend); existing `hex_grid_strength` and `hex_line_color` unchanged.

**Code**

- 8 texelFetch samples per fragment (center already sampled; 8 neighbors).
- Unrolled (no loop) for compatibility.

---

## Test Results (Otto)

| Test | Result | Notes |
|------|--------|------|
| 1. Visual hex shape | [x] **Improved** | Hexagonal grid looks a little better visually. |
| 2. Slice alignment | [x] **Still off** | More centered than before, but still off-grid. |
| 3. Boundary smoothness | [x] **Blocky** | *Terrain grid lines* (not the slice) are really blocky, 8-bit style. Slice borders are smooth. |
| 4. Chunk boundaries | [x] **Severe** | Visible seams between chunks; can see through terrain (holes). Hex grid is **not continuous**—a strip/width at chunk transitions where the grid is not drawn on the terrain. |
| 5. Performance | **Good** | No concern. |

**Summary:** 8-direction sampling improved hex shape slightly; slice still off; **terrain grid lines are very blocky**. **Chunk boundaries:** grid gap (we intentionally hide grid near edges) + terrain seams/holes (possible mesh/LOD issue). Edge threshold narrowed in shader (1.5→0.5 px) to reduce grid gap; full fix needs cross-chunk sampling or mesh alignment.

---

## Architectural

- **Shape-agnostic:** Yes — same logic for any cell texture (hex, Voronoi, merged).
- **Future merge:** Comment in shader: compare `merge_group_id` instead of `cell_id` when merging is added.
- **Chunk boundary:** Clamp only; cross-chunk sampling would need architect decision.

---

## Recommendations

- **Slice still off:** Alignment is a coordinate/selection issue; Phase 1F was about grid *shape*. Continue with coordinate/docs work if needed.
- **Blocky grid lines:** Future polish: anti-aliasing or higher-res textures.
- **Chunk boundaries (grid gap):** We suppress the grid in a strip along chunk edges so clamped neighbor sampling doesn’t draw wrong lines. **Change made:** edge threshold reduced from 1.5 to 0.5 (in “pixel width” terms), so the strip is narrower and the grid gap smaller. If artifact lines appear at the seam, we can tune or revert. **Proper fix:** cross-chunk sampling (shader would need neighbor chunk’s cell texture), or ensure mesh/chunk edges align so no strip is needed—architectural.
- **Terrain holes/seams (see-through):** Likely separate from grid: mesh placement, LOD transition, or chunk positioning. Worth a separate check (e.g. chunk node positions, mesh extent, no double-sided or backface cull issues).
