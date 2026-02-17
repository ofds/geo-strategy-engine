# Phase 1E — Pixel Convention Audit

**Date:** February 16, 2026  
**Purpose:** Compare world→pixel convention across Python texture generation, shader grid rendering, and runtime selection to fix half-hex diagonal shift.

---

## Audit Findings

### 1. Python texture generation

**Source:** Documented in `docs/CELL_SELECTION_DATA_PIPELINE.md` and `docs/CELL_TEXTURE_GENERATION_ANALYSIS.md`. Script `tools/generate_cell_textures.py` is referenced in docs but **not present in this repo** (may live in another repo or be external).

**Forward map (pixel → world):**

- Loop over `ii, jj` in `0..511` (512×512 texture).
- `local_x = (ii / 511) * chunk_size_m`, `local_z = (jj / 511) * chunk_size_m`.
- World for pixel (i, j): `(origin_x + (i/511)*chunk_size, origin_z + (j/511)*chunk_size)`.

**Inverse (world → pixel) implied by this convention:**

- `local = world - origin` → pixel index = **round(local / chunk_size * 511)** (nearest sample point).

**Formula:** Pixel i = sample **at** world position `(i/511)*chunk_size`. So inverse uses **round** with denominator **(texture_size - 1) = 511**.

**Convention:** **Sample-point** (512 discrete positions at 0/511, 1/511, … 511/511). Not “pixel owns extent [i/512, (i+1)/512)”.

| Aspect            | Value                          |
|------------------|--------------------------------|
| Formula           | Forward: (i/511)*chunk_size    |
| Inverse formula   | round(local / chunk_size * 511)|
| Denominator       | 511 (texture_size - 1)         |
| Convention        | Round (nearest sample point)   |
| Texture size basis| 512×512, indices 0..511         |

---

### 2. Shader grid rendering

**File:** `rendering/terrain.gdshader`

**Relevant code:**

- Debug cell texture (F11):  
  `ivec2 pixel_coord = ivec2(floor(v_uv * vec2(tex_size - ivec2(1, 1)) + vec2(0.5, 0.5)));`  
  → **round**: `floor(uv * (tex_size-1) + 0.5)`.
- Hex grid sampling (main path):  
  Same: `ivec2 pixel_coord = ivec2(floor(v_uv * vec2(tex_size - ivec2(1, 1)) + vec2(0.5, 0.5)));`  
  Then `clamp_texel_coord(pixel_coord, tex_size)` clamps to `[0, tex_size-1]`.

**Formula:** `floor(v_uv * (tex_size - 1) + 0.5)` = round to nearest integer in [0, tex_size-1].  
With `v_uv = local / chunk_size` (0..1), this is **round(local / chunk_size * (tex_size - 1))** in texel space.

| Aspect            | Value                                      |
|-------------------|--------------------------------------------|
| Formula            | floor(v_uv * (tex_size - 1) + 0.5)         |
| Equivalent         | round(uv * (tex_size - 1))                 |
| Convention         | Round (nearest sample point)               |
| Texture size basis | tex_size (512); uses (tex_size - 1) = 511  |

---

### 3. Runtime selection

**File:** `core/chunk_manager.gd`, function `_get_cell_id_at_chunk_impl`

**Code (before Phase 1E fix):**

```gdscript
var px_raw: int = clampi(int(round(local_x / chunk_size * float(w - 1))), 0, w - 1)
var py_raw: int = clampi(int(round(local_z / chunk_size * float(h - 1))), 0, h - 1)
```

**Formula:** `round(local_x / chunk_size * (w - 1))`, clamped to [0, w-1]. Same for py.

| Aspect            | Value                                |
|-------------------|--------------------------------------|
| Formula            | round(local / chunk_size * (w - 1))  |
| Convention         | Round (nearest sample point)          |
| Texture size basis | (w - 1), (h - 1) i.e. 511            |

---

## Consistency (before fix)

| System              | Formula                          | Convention | Texture size basis |
|---------------------|----------------------------------|------------|--------------------|
| Python generation   | (i/511)*cs forward; round inverse| Round      | 511 (denominator)   |
| Shader rendering    | floor(uv*(tex_size-1)+0.5)       | Round      | tex_size-1 (511)    |
| Runtime selection   | round(local/cs*(w-1))            | Round      | w-1 (511)           |

**Conclusion:** All three use the **same** convention: **round** with **(texture_size - 1)**. So the half-hex shift is **not** from a mismatch between the three systems, but from **round’s behavior at boundaries**: at exactly 0.5 between two pixels we can get the wrong pixel, and floating point can push us to the wrong side of a boundary, causing a systematic diagonal bias. Aligning to **pixel-extent + floor** gives a deterministic “pixel that contains this point” and removes boundary ambiguity.

---

## Target convention (Phase 1E)

**Pixel-extent convention:**

- Pixel i **owns** world positions in `[ (i/texture_size)*chunk_size, ((i+1)/texture_size)*chunk_size )`.
- Formula: `px = floor(local_position / chunk_size * texture_size)`.
- Clamp: `px = clamp(px, 0, texture_size - 1)`.

**Note:** Python textures were generated with **sample-point** (round, 511). We do **not** change or regenerate Python without architect approval. We change **only** runtime selection and shader to use **floor(local/cs * texture_size)** so that:

1. Selection and shader use the same formula (no mismatch between grid and slice).
2. Boundary behavior is deterministic (no round-tie at 0.5).

If the shift persists after this change, the next step is either texture regeneration with the floor convention (architect decision) or further diagnostics (e.g. detailed logging, V-flip test).
