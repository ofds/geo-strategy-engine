# Phase 1C Selection Fix — Test Results

## Fix Applied

1. **511-scale fix (previous):** Changed `px`/`py` from `* w`/`* h` to `* (w-1)`/`* (h-1)` in `chunk_manager.gd` so selection uses the same 511-based mapping as Python texture generation and mesh UVs.

2. **V-flip fix (tried, then reverted):** Added vertical flip `py = (h - 1) - py_raw` to match possible shader V convention. **User re-test: unchanged.** V-flip has been reverted in code.

---

## Test Results

- **Test 1 (Street Level / LOD 0):** **FAIL** — Green circle not aligned with visible grid; lifted slice not on grid.
- **Test 2 (Regional LOD 1):** **FAIL** — Same misalignment.
- **Test 3 (Cell Boundaries):** Not separately reported; issue persists.
- **Test 4 (Chunk Boundaries):** Not separately reported.
- **Test 5 (Console/Performance):** No console errors reported.
- **Re-test after V-flip:** **UNCHANGED** — alignment still wrong; V-flip reverted.

---

## Debug Output (User-Provided)

```
=== SELECTION DEBUG ===
Raycast hit position (world): (3078599, 77.87451, 1943321)
Hit chunk LOD: 1
Hit chunk indices: (33, 21)
Chunk origin (world): (3041280.0, 1935360.0)
Local position: (37318.5, 7960.625)
Cell ID: 14299568
Cell center from metadata (world XZ): (3078519.0, 1942860.0)
Cell center passed to hex_selector: (3078519.0, 1942860.0)
======================

=== HEX_SELECTOR DEBUG ===
Received world_center: (3078519.0, 0.0, 1942860.0)
hex_mesh.global_position: (3078519.0, 0.0, 1942860.0)
hex_mesh.position (local): (3078519.0, 0.0, 1942860.0)
hex_mesh parent: HexSelector
hex_mesh parent global_position: (0.0, 0.0, 0.0)
==========================
```

**Analysis:**

- Hit XZ: (3078599, 1943321) | Center XZ: (3078519, 1942860)  
- Offset: center is **80 m west, 461 m south** of hit.
- Hex radius ≈ 577 m, so hit is **inside** the hex whose center we show (distance from center ≈ 468 m &lt; 577 m).
- So we are likely **selecting the correct cell**; the perceived “misalignment” may be:
  - **Visual:** Green circle / slice not lining up with **drawn grid lines** (shader grid vs metadata center), or
  - **V-flip** was tried and reverted (no improvement).

---

## Grid Line Artifact (New Issue)

**Description:** Lines cutting through the middle of several hexes, parallel to the hex grid, same color as the hex grid.

**Likely cause:** Shader draws a grid line when `cell_id != neighbor` (Phase 1B boundary detection). At **chunk boundaries** or at **texture edges** (UV near 0 or 1), neighbor samples can hit the same texel (clamped) or wrap, producing false “boundaries” and visible seams.

**Suggested follow-up (shader):** In `terrain.gdshader`, when computing `on_boundary`, optionally treat fragments with `v_uv` very close to 0 or 1 on either axis as non-boundary (or reduce line strength) so chunk edges don’t draw extra lines. Example: skip boundary line when `v_uv.x < duv.x || v_uv.x > 1.0 - duv.x || v_uv.y < duv.y || v_uv.y > 1.0 - duv.y`.

---

## Evidence

- Screenshot: *(User to add — LOD 0 selection before/after)*
- Screenshot: *(User to add — LOD 1 selection)*
- Screenshot: *(User to add — Grid line artifact)*

---

## Diagnostic Test — Metadata vs Analytical Center (Completed)

**Test A: Center comparison**

- Raycast hit (world XZ): (3077944, 1944023)
- Hit chunk LOD: 1, indices (33, 21)
- Metadata center: (3077653, 1944360)
- Analytical center: (3077653, 1944360)
- **Difference: (0, 0) — SAME**

**Test B: Analytical center for slice**

- `USE_ANALYTICAL_FOR_TEST = true` was used; center passed to hex_selector was analytical (same as metadata in this run).
- Because difference is 0, switching to analytical does not change the visual; slice position is unchanged.

**Conclusion**

- **Phase 1A (texture/metadata):** **CORRECT** — metadata center matches analytical.
- **Analytical hex math:** **CORRECT** — matches metadata.
- **Phase 1B (shader grid):** **BUG SUSPECTED** — selection and center math agree, but the visible grid lines do not align with where we place the slice. The shader is drawing cell boundaries in a different position than the hex layout implied by the texture and metadata.

**Root cause**

The cell texture and metadata (and analytical math) are consistent. The misalignment is between **where the shader draws the hex grid** and **where the hex centers are**. So the bug is in how the terrain shader samples or interprets the cell texture for boundary detection (e.g. UV mapping, texel centering, or neighbor sampling), not in selection or metadata.

**Recommended fix**

- Investigate **terrain.gdshader** hex grid path: how `v_uv` maps to the texture, how `duv` and neighbor sampling work, and whether the drawn boundaries match the same world positions as the texture’s cell layout (and thus the slice). Options: adjust UV→world mapping in the shader, or ensure boundary detection uses the same texel convention as Python (e.g. which side of a texel is “inside” the cell).

---

## Status

**PARTIAL** — 511-scale fix applied; V-flip reverted. Diagnostic confirms **Phase 1B (shader grid)** is the suspected source of misalignment; Phase 1A and analytical math are consistent.

---

## Next Steps

1. **Phase 1B shader:** Audit `terrain.gdshader` hex grid: `v_uv`, `textureSize`, `duv`, and the four neighbor samples; ensure the fragment’s world position implied by UV matches the same local→texel mapping as Python and selection (0..chunk_size → 0..511).
2. **Grid line artifact:** If chunk-edge lines persist, add UV-edge guard (skip or soften boundary when `v_uv` is near 0 or 1) as previously suggested.

---

## Shader fix applied (no visual improvement)

- **duv:** Changed to 511-based in terrain.gdshader. **UV edge guard:** Added. **User re-test:** Alignment still off; artifact unchanged.

**See [PHASE_1C_FINAL_SUMMARY.md](PHASE_1C_FINAL_SUMMARY.md) for the final summary and next steps.**
