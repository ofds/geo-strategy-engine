# Phase 1C — Final Summary

**Outcome:** Selection alignment and grid-line artifact are **not resolved** after all applied fixes. Phase 1C remains **incomplete**.

---

## What Was Tried

| Fix | Where | Result |
|-----|--------|--------|
| 511-scale for selection (px/py) | chunk_manager.gd | Alignment still off |
| V-flip for texture row (py) | chunk_manager.gd | No change; reverted |
| Diagnostic: metadata vs analytical | basic_camera.gd | Same center (0,0 diff) — selection/metadata correct |
| 511-based duv in shader | terrain.gdshader | Alignment still off |
| UV edge guard in shader | terrain.gdshader | Chunk-edge artifact unchanged |

---

## What We Know

- **Selection and center math are consistent.** Texture → cell_id → metadata center matches analytical `get_hex_center_at_lod`. The slice is placed at the correct hex center for the sampled cell.
- **Visible grid and slice disagree.** The hex grid drawn by the shader does not align with where we draw the slice (or with the texture’s cell layout). Changing the shader to 511-based `duv` did not fix that.
- **Chunk-edge lines persist.** Extra lines through hexes at chunk boundaries remain; the UV edge guard did not remove or clearly reduce them.

---

## Open Possibilities

1. **UV vs world in the shader** — Mesh UVs may not map to the same world positions as the texture’s cell layout (e.g. fragment interpolation or LOD shifting UV relative to world).
2. **Texel center vs edge** — Boundary detection may need to sample at texel centers or use a different rule so “boundary” matches the intended cell edges.
3. **Texture filtering or binding** — Assumed `filter_nearest` and no repeat; different wrap or scale could shift boundaries.
4. **Artifact from elsewhere** — Chunk-edge lines might come from mesh seams, LOD transitions, or another pass, not this boundary detection.

---

## Phase 1C Status

**Incomplete.** Texture-based selection and metadata are in place and internally consistent, but the **drawn grid does not align** with the slice, and the chunk-edge artifact persists. Phase 1 (A+B+C) is not yet fully complete for “grid and selection aligned.”

---

## Recommendations for Next Steps

1. **UV–world audit** — Trace mesh UV assignment (terrain_loader.gd / worker) and fragment `v_uv` to world XZ; confirm it matches Python’s `local = (i/511)*chunk_size` for the same chunk.
2. **Minimal repro** — One chunk, one LOD; print or visualize UV and world at a few pixels to see where the first mismatch appears.
3. **Shader boundary rule** — Revisit how “boundary” is defined (texel center, half-texel offset, or different neighbor strategy) so drawn lines match the intended cell edges.
4. **Chunk-edge artifact** — Confirm whether the extra lines come from this shader’s boundary path; if yes, try a stronger or different edge guard or avoid drawing at chunk borders.
