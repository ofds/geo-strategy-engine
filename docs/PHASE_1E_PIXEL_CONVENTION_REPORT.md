# Phase 1E — Pixel Convention Alignment Report

**Date:** February 16, 2026  
**Status:** PARTIAL (implementation complete; verification by Otto pending)

---

## Report (copy-paste block for architect)

```
Status: PARTIAL (implementation complete; verification pending)

Audit Findings:
System              | Current Formula (before fix)           | Convention (before) | Texture Size Basis
Python generation   | forward: (i/511)*cs; inverse: round    | Round (sample-point) | 511 (denominator)
Shader rendering    | floor(v_uv*(tex_size-1)+0.5)            | Round               | tex_size-1 (511)
Runtime selection   | round(local/cs*(w-1))                   | Round               | w-1 (511)

Consistency: All three used the same convention (round with 511). Half-hex shift attributed to round()
boundary ambiguity; aligned selection and shader to pixel-extent (floor with texture_size) for deterministic sampling.

What Was Changed:
- core/chunk_manager.gd: px/py from round(local/cs*(w-1)) to floor(local/cs*w) with clampi(0, w-1). V-flip toggle unchanged (false).
- rendering/terrain.gdshader: pixel_coord from floor(v_uv*(tex_size-1)+0.5) to floor(v_uv*tex_size) with clamp to 0..tex_size-1 (F11 debug + hex grid path).
- tools/generate_cell_textures.py: Not in repo; convention taken from docs (round, 511). No change.

V-Flip Test Results:
- Tested: NO (to be run by Otto if shift persists after pixel convention fix)
- Result: N/A

Verification Test Results:
- F12 offset test: [To be filled by Otto — run F12, paste min/max/mean/std]
- Visual alignment: [To be filled by Otto — click grid center, note aligned / still shifted / worse]
- F9 debug viz: [To be filled by Otto — yellow marker vs grid center]
- Edge cases: [To be filled by Otto — chunk boundary clicks]

Evidence:
Otto to attach: F12 console output; screenshot aligned/shifted; F9 viz if useful.

Texture Regeneration Needed?
- NO for current change (selection and shader now match each other with floor convention).
- If shift persists: Python textures use round+511; full alignment would require regenerating textures with
  floor convention (pixel i owns [i/512,(i+1)/512)*chunk_size). Architect decision.

Recommendations:
- Run F12, visual alignment, F9, and edge-case tests. If offset < 10 m and slice aligns: Phase 1E complete.
- If shift persists: (1) Set CELL_TEXTURE_V_FLIP = true and retest; (2) If still shifted, add detailed
  logging (hit, local, px, py, cell_id, metadata_center) and report; (3) Architect may approve
  texture regeneration with floor convention in Python.
```

---

## Audit summary

See **`docs/PHASE_1E_PIXEL_CONVENTION_AUDIT.md`** for the full audit.

Before Phase 1E, all three systems used **round** with **(texture_size - 1) = 511**. That is consistent, but at boundaries round() can pick the neighboring pixel, causing a systematic half-hex diagonal shift. Selection and shader were changed to **pixel-extent** convention: **floor(local / chunk_size * texture_size)** with clamp to [0, texture_size-1], so both use “pixel that contains this point” and stay in sync. Python (documented only; script not in repo) still uses sample-point (round, 511); textures were not regenerated.

---

## What was changed (code)

### core/chunk_manager.gd

- In `_get_cell_id_at_chunk_impl`:  
  **Before:** `px_raw = clampi(int(round(local_x / chunk_size * float(w - 1))), 0, w - 1)` (same for py).  
  **After:** `px_raw = clampi(int(floor(local_x / chunk_size * float(w))), 0, w - 1)` (same for py).  
  V-flip logic unchanged (`CELL_TEXTURE_V_FLIP = false`).

### rendering/terrain.gdshader

- **F11 debug path:**  
  `pixel_coord = ivec2(floor(v_uv * vec2(tex_size)))` then `clamp(..., 0, tex_size - 1)`.
- **Hex grid path:**  
  Same: `pixel_coord = ivec2(floor(v_uv * vec2(tex_size)))` then `clamp(..., 0, tex_size - 1)`.

### tools/generate_cell_textures.py

- Not present in repo. Convention from docs: pixel i = world at (i/511)*chunk_size (round inverse). **No change.** Regeneration would require architect approval if full floor alignment is desired.

---

## Verification (for Otto)

1. **F12:** Run game, press F12. Note offset statistics (min, max, mean, std). Pass: max < 10 m, mean < 8 m.
2. **Visual:** Click center of a visible hex; confirm slice aligns with grid (no diagonal shift).
3. **F9:** Enable debug markers; confirm yellow (cell center) aligns with grid center.
4. **Edge:** Click near a chunk boundary; confirm correct cell and no wrap.
5. **If shift remains:** Set `CELL_TEXTURE_V_FLIP = true` in `chunk_manager.gd`, retest, and report (disappeared / changed direction / unchanged).
