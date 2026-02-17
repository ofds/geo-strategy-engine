# Cell Selection Data Pipeline

How world position flows from **click** and **terrain draw** into **cell ID** and **slice position**, and where a fixed half-hex shift can come from.

---

## 1. Python (texture generation)

**Input:** Chunk (chunk_x, chunk_y, lod), origin (origin_x, origin_z) = (chunk_x × chunk_size_m, chunk_y × chunk_size_m).

**Pixel → world (per pixel):**

- `ii, jj = 0..511` (integer indices).
- `local_x = (ii / 511) * chunk_size_m`
- `local_z = (jj / 511) * chunk_size_m`
- `world_x = origin_x + local_x`, `world_z = origin_z + local_z`

**Cell at pixel (i, j):**

- World position for that pixel: `(origin_x + (i/511)*chunk_size_m, origin_z + (j/511)*chunk_size_m)`.
- Axial: `q_float = (2/3 * world_x) / HEX_RADIUS_M`, same for r from world_x, world_z.
- Cube-round to integer (q, r); look up cell_id from id_map.
- Texture is written so that **array[j, i]** = row j (local_z), column i (local_x). Row 0 = north (local_z=0).

**Metadata:** Centers are **global** world XZ from `axial_to_center(q, r)` (no chunk offset).

So: **pixel (i, j) ↔ world (origin_x + (i/511)*cs, origin_z + (j/511)*cs)** and that world point gets one cell_id.

---

## 2. Terrain mesh (runtime)

**Chunk node:** `position = (chunk_origin_x, 0, chunk_origin_z)` = (cx × chunk_size, 0, cy × chunk_size).

**Vertices (terrain_worker):**

- Grid (x, y) with x, y in 0..(mesh_res-1). mesh_res = 512 for LOD 0.
- `actual_vertex_spacing = chunk_world_size / (mesh_res - 1)` → last vertex at chunk_world_size.
- Vertex position (local): `(x * spacing, height, y * spacing)` → local_x = x/511*chunk_world_size, local_z = y/511*chunk_world_size.
- UV: `(x / (mesh_res-1), y / (mesh_res-1))` = (local_x / chunk_world_size, local_z / chunk_world_size).

So: **UV (0..1, 0..1) ↔ local (0..chunk_size, 0..chunk_size)**. UV (0,0) = NW (local 0,0).

---

## 3. Shader (grid drawing)

**Fragment:**

- `v_uv` = interpolated UV from mesh (so v_uv = local / chunk_size in 0..1).
- Pixel: `pixel_coord = floor(v_uv * (tex_size - 1) + 0.5)` = round to nearest 0..511.
- `cell_id = texelFetch(cell_id_texture, pixel_coord)`.
- Grid line where center cell_id ≠ neighbor cell_id.

So the **same** world position on the mesh gives:

- local = world - chunk_origin  
- v_uv = local / chunk_size  
- pixel = round(v_uv * 511)  
→ shader and Python use the same mapping (0..1 ↔ 0..chunk_size, round to pixel).

---

## 4. Selection (click → cell_id → slice)

**Steps:**

1. Raycast → `hit_pos` (world 3D).
2. Project to 2D: `cell_xz = (hit_pos.x, hit_pos.z)`.
3. Chunk: from hit collider name `HeightMap_LOD%d_%d_%d` → (sel_cx, sel_cy, hit_lod), or else floor(cell_xz / chunk_size).
4. Chunk origin: `(sel_cx * chunk_size, sel_cy * chunk_size)`.
5. Local: `local_x = hit_pos.x - chunk_origin_x`, `local_z = hit_pos.z - chunk_origin_z`.
6. Pixel: `px = round(local_x / chunk_size * 511)`, `py = round(local_z / chunk_size * 511)` (clamped 0..511).
7. Sample: `img.get_pixel(px, py)` → RGBA → cell_id.
8. Metadata: `get_cell_info(cell_id)` → center_x, center_z (world).
9. Slice: `hex_selector.set_selected_hex(center)`; slice Y from `get_height_at(center_x, center_z)`.

So selection uses the **same** idea: local = world - chunk_origin, pixel = round(local / chunk_size * 511).

---

## 5. Where a fixed half-hex shift can come from

A **fixed** offset in **one direction** (e.g. “always half a hex that way”) usually means one of:

| Cause | Effect | What to check |
|-------|--------|----------------|
| **Pixel convention** | We use “round”, Python/shader might effectively use “floor” or “floor+0.5” so we sample the next pixel over at boundaries. | Use `floor(local / chunk_size * (w-1))` in selection to match “pixel that contains point” and compare with shader. |
| **Texture V flip** | PNG row 0 = north in Python; if Godot or GPU treats row 0 as bottom, we read the wrong row → offset in Z. | In selection use `py = (h - 1) - round(local_z / chunk_size * (h - 1))` and see if shift direction changes or disappears. |
| **Chunk origin** | Wrong chunk (e.g. off by one in cx or cy) → whole chunk offset. | Debug print chunk (cx, cy) and chunk_origin; confirm they match the mesh under the cursor. |
| **Mesh extent ≠ chunk_size** | If mesh didn’t span full chunk_size, UV would be scaled and our “local / chunk_size” would not match. | Already verified: mesh spans 0..chunk_world_size. |

So the two main suspects for a **half-hex** shift are:

1. **Pixel indexing:** round vs floor (or “pixel center” vs “pixel corner”) so we sometimes sample the neighbor pixel → wrong cell → slice one hex over (or half-hex if the “half” is between two cells).
2. **Texture row (V) flip:** we think py = row for local_z, but the texture is effectively upside down, so we read a row that’s offset in Z → shift in one direction.

The pipeline is designed so that **world → chunk → local → pixel → cell_id** is the same in Python, shader, and selection. Any remaining offset is likely a single convention mismatch (round vs floor, or V flip) in one of the three.

**Runtime toggle:** In `core/chunk_manager.gd`, `_get_cell_id_at_chunk_impl` uses `CELL_TEXTURE_V_FLIP` (default `false`). If the shift is in the Z direction, set it to `true` so selection uses `py = (h - 1) - py_raw` and matches a texture loaded with row 0 at bottom.

---

## 6. Phase 1E — Pixel convention (floor)

**Selection and shader** now use **pixel-extent** convention so the same world position maps to the same pixel in both:

- **Formula:** `px = floor(local_x / chunk_size * texture_size)` (same for py), then clamp to [0, texture_size-1].
- **Shader:** `pixel_coord = ivec2(floor(v_uv * vec2(tex_size)))`, then clamp to [0, tex_size-1].

Python (from docs) still uses sample-point: pixel i = world at (i/511)*chunk_size (round inverse). Textures were not regenerated; if a shift remains, see `docs/PHASE_1E_PIXEL_CONVENTION_REPORT.md` and audit.
