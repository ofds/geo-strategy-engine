# Cell Texture & Selection Coordinate System Report

## Part 1: Cell Texture Generation (Python)

**File:** `tools/generate_cell_textures.py`

### 1.1 World-to-Pixel Mapping

Python does **pixel → world** (not a single world→pixel function). The inverse can be derived.

**Pixel → World (exact code):**

From `_chunk_axial_coords()` (lines 164–179) and `_generate_cell_id_array()` (lines 258–266):

```python
# _chunk_axial_coords (lines 171-176)
ii = np.arange(CHUNK_SIZE_PX, dtype=np.float32)   # 0..511
jj = np.arange(CHUNK_SIZE_PX, dtype=np.float32)
local_x = (ii[np.newaxis, :] / (CHUNK_SIZE_PX - 1)) * chunk_size_m   # ii along columns (x)
local_z = (jj[:, np.newaxis] / (CHUNK_SIZE_PX - 1)) * chunk_size_m   # jj along rows (z)
world_x = origin_x + np.broadcast_to(local_x, (CHUNK_SIZE_PX, CHUNK_SIZE_PX))
world_z = origin_z + np.broadcast_to(local_z, (CHUNK_SIZE_PX, CHUNK_SIZE_PX))
```

So for **pixel index** `(i, j)` (column `i`, row `j`, both in 0..511):

- `local_x = (i / 511) * chunk_size_m`
- `local_z = (j / 511) * chunk_size_m`
- `world_x = origin_x + local_x`, `world_z = origin_z + local_z`

**Inverse (world → pixel):**

- `local_x = world_x - origin_x`, `local_z = world_z - origin_z`
- `i = local_x / chunk_size_m * 511`  (float; pixel index 0..511)
- `j = local_z / chunk_size_m * 511`

Pixels are indexed **0..511** (512 pixels). The extent is **0 to chunk_size_m** with samples at `k/511 * chunk_size_m` for k = 0..511 (so both endpoints 0 and chunk_size_m are included).

### 1.2 Chunk Coordinate System

**Chunk origin (NW corner):**

From `get_chunk_origin()` (lines 91–97):

```python
def get_chunk_origin(chunk_x: int, chunk_y: int, lod: int, resolution_m: float) -> Tuple[float, float]:
    """Chunk origin (NW corner) in world space. Must match ChunkManager.get_chunk_origin_at()."""
    chunk_size_m = 512 * resolution_m * (2 ** lod)
    origin_x = chunk_x * chunk_size_m
    origin_z = chunk_y * chunk_size_m
    return (origin_x, origin_z)
```

- Formula: `chunk_size_m = 512 * resolution_m * (2 ** lod)`, `origin = (chunk_x * chunk_size_m, chunk_y * chunk_size_m)`.
- LOD 0 example: chunk (10, 20), resolution_m=90 → `chunk_size_m = 46080`, `origin = (460800, 921600)`.

### 1.3 Axial-to-World (Cell Centers)

**Axial → world center (no chunk offset):**

From `axial_to_center()` (lines 76–81):

```python
def axial_to_center(q: int, r: int, size: float = HEX_RADIUS_M) -> Tuple[float, float]:
    """Axial to world center XZ. Matches shader axial_to_center (pointy-top)."""
    center_x = size * (1.5 * q)
    center_z = size * (math.sqrt(3.0) / 2.0 * q + math.sqrt(3.0) * r)
    return (center_x, center_z)
```

Cell centers in `cell_metadata.json` are built from this in **world** space (global, not chunk-relative). From `build_sparse_cell_registry_and_id_map()` (lines 234–245):

```python
for (q, r), compact_id in cell_id_map.items():
    cx, cz = axial_to_center(q, r)   # world XZ, no chunk origin added
    ...
    registry[compact_id] = {
        "axial_q": q,
        "axial_r": r,
        "center_x": round(cx, 2),
        "center_z": round(cz, 2),
        ...
    }
```

So metadata `center_x`, `center_z` are **global** hex centers (axial → world with no offset).

### 1.4 Texture Resolution & Extent

- **Texture size:** 512×512 pixels (LOD 0; same for LOD 1, 2).
- **World extent per axis:** `0` to `chunk_size_m` in **chunk-local** space.
  - LOD 0, resolution_m=90: `chunk_size_m = 512 * 90 * 1 = 46080` m.
  - So each texture covers **0 m → 46080 m** along X and Z (relative to chunk origin).
- **UV assumption:** Not used in Python (no UVs). Pixel (0,0) = local (0, 0), pixel (511,511) = local (chunk_size_m, chunk_size_m).

### 1.5 Summary Table (Part 1)

| Property | Value | Notes |
|----------|-------|-------|
| Texture size (pixels) | 512×512 | LOD 0, 1, 2 |
| World extent covered | 0 m → chunk_size_m | chunk_size_m = 512 * resolution_m * 2^lod |
| Chunk origin | (chunk_x * chunk_size_m, chunk_y * chunk_size_m) | NW corner |
| Pixel→World | local_x = (i/511)*chunk_size_m, world = origin + local | i, j in 0..511 |
| World→Pixel (inverse) | i = local_x/chunk_size_m * 511, j = local_z/chunk_size_m * 511 | float; round for integer pixel |
| Axial→World (centers) | center_x = size*(1.5*q), center_z = size*(√3/2*q + √3*r) | Global; no chunk offset in metadata |
| UV mapping assumption | N/A | Python does not use UVs |

---

## Part 2: Shader Grid Rendering (Phase 1B)

**File:** `rendering/terrain.gdshader`

### 2.1 Texture Sampling in Shader

From fragment shader (lines 122–124):

```gdshader
vec4 cell_rgba = texture(cell_id_texture, v_uv);
uint cell_id = decode_cell_id(cell_rgba);
```

`uv` is the varying **v_uv** from the vertex shader.

### 2.2 Vertex UV Assignment

**In shader (vertex):** Lines 66–71:

```gdshader
void vertex() {
	vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_world_pos = world_pos.xyz;
	v_uv = UV;
	v_elevation = world_pos.y;
	v_world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}
```

So **v_uv = UV** (mesh UVs, passed through).

**Mesh UV assignment:** `core/terrain_loader.gd`, `_generate_mesh_lod()` (lines 416–430):

```gdscript
# UV scale: 0..1 over chunk for cell texture sampling (Phase 1B)
var uv_scale_x: float = 1.0 / maxf(1.0, float(mesh_res) - 1.0)
var uv_scale_y: float = 1.0 / maxf(1.0, float(mesh_res) - 1.0)
# ...
uvs.append(Vector2(float(x) * uv_scale_x, float(y) * uv_scale_y))
```

So **UV = (x / (mesh_res-1), y / (mesh_res-1))** for vertex grid (x, y) in 0..(mesh_res-1). For LOD 0, mesh_res=512: **UV = (x/511, y/511)**.

Vertex position in local chunk space (lines 428–430):

```gdscript
var pos = Vector3(
    x * actual_vertex_spacing,
    height,
    y * actual_vertex_spacing
)
```

With `actual_vertex_spacing = chunk_world_size / (mesh_res - 1)` (line 415), so last vertex (x=y=511) is at local (chunk_world_size, chunk_world_size). So:

- **UV (0, 0)** = vertex (0,0) = local **(0, 0)** = chunk NW.
- **UV (1, 1)** = vertex (511,511) = local **(chunk_world_size, chunk_world_size)** = chunk SE.

### 2.3 Chunk Origin in Shader

`chunk_origin_xz` is set per instance in `chunk_manager.gd` (line 431):

```gdscript
mesh_instance.set_instance_shader_parameter("chunk_origin_xz", Vector2(world_pos.x, world_pos.z))
```

In `terrain.gdshader`, **chunk_origin_xz is declared** (line 32) but **not used** for cell ID sampling. Cell sampling uses only **v_uv** (and thus mesh UVs). So chunk origin does **not** affect cell ID lookup in the shader.

### 2.4 Summary Table (Part 2)

| Property | Value | Notes |
|----------|-------|-------|
| v_uv calculation | v_uv = UV (from mesh) | Vertex shader passes UV through |
| UV assignment (mesh) | UV = (x/(mesh_res-1), y/(mesh_res-1)) | x, y = 0..mesh_res-1 |
| UV (0,0) world pos | local (0, 0) | Chunk NW (relative to chunk origin) |
| UV (1,1) world pos | local (chunk_world_size, chunk_world_size) | Chunk SE |
| Chunk origin used? | NO | Not used for cell_id_texture sampling |
| World→UV | Implicit: vertex local pos = (x,y)*spacing, UV = (x,y)/(mesh_res-1); local 0..chunk_world_size → UV 0..1 | Fragment uses interpolated v_uv |

---

## Part 3: Selection Texture Sampling (Phase 1C)

**File:** `core/chunk_manager.gd`

### 3.1 World-to-Pixel Mapping

From `_get_cell_id_at_chunk_impl()` (lines 809–833):

```gdscript
var chunk_size: float = _get_chunk_world_size(hit_lod)
# ...
var chunk_origin_x: float = float(cx) * chunk_size
var chunk_origin_z: float = float(cy) * chunk_size
var local_x: float = world_pos.x - chunk_origin_x
var local_z: float = world_pos.z - chunk_origin_z
# ...
var w: int = img.get_width()
var h: int = img.get_height()
var px: int = clampi(int(round(local_x / chunk_size * float(w))), 0, w - 1)
var py: int = clampi(int(round(local_z / chunk_size * float(h))), 0, h - 1)
var color: Color = img.get_pixel(px, py)
```

So:

- **Chunk origin:** `(cx * chunk_size, cy * chunk_size)`.
- **Local:** `local_x = world_pos.x - chunk_origin_x`, `local_z = world_pos.z - chunk_origin_z`.
- **Pixel:** `px = round(local_x / chunk_size * w)`, `py = round(local_z / chunk_size * h)` (then clamped to 0..w-1, 0..h-1).

With w=h=512 this is **px = round(local_x / chunk_size * 512)** (and similarly for py).

### 3.2 Chunk Origin Calculation

Chunk origin for the hit chunk is computed inside `_get_cell_id_at_chunk_impl` as:

- `chunk_size = _get_chunk_world_size(hit_lod)` (line 810)
- `chunk_origin_x = float(cx) * chunk_size`, `chunk_origin_z = float(cy) * chunk_size` (lines 823–824)

`_get_chunk_world_size()` (lines 1496–1498):

```gdscript
func _get_chunk_world_size(lod: int) -> float:
	return float(Constants.CHUNK_SIZE_PX) * _resolution_m * pow(2.0, float(lod))
```

So **chunk_size = 512 * resolution_m * 2^lod**, same as Python’s `chunk_size_m`. Origin formula matches Python: **(chunk_x * chunk_size, chunk_y * chunk_size)**.

### 3.3 Texture Access

- **Load:** `terrain_loader.get_cell_texture_for_selection(cx, cy, hit_lod)` → `_load_cell_texture()` in `terrain_loader.gd` (lines 224–243). Path: `res://data/terrain/cells/lod{L}/chunk_{x}_{y}_cells.png`, cached by `"lod{L}_{x}_{y}"`.
- **Sample:** `img.get_pixel(px, py)` with **integer** `px`, `py` (clamped to 0..w-1, 0..h-1). No V-flip or extra transform in this code.

### 3.4 Summary Table (Part 3)

| Property | Value | Notes |
|----------|-------|-------|
| Chunk origin formula | chunk_origin = (cx * chunk_size, cy * chunk_size), chunk_size = 512*resolution_m*2^lod | Same as Python |
| World→Local | local_x = world_pos.x - chunk_origin_x, local_z = world_pos.z - chunk_origin_z | Correct |
| Local→Pixel | px = round(local_x / chunk_size * w), py = round(local_z / chunk_size * h); then clampi to 0..w-1 | w,h = 512 |
| Pixel sampling | img.get_pixel(px, py) | Integer coords |
| World extent assumption | 0..chunk_size (46080 m for LOD0 @ 90 m) | Pixel 0 = local 0, pixel 511 = local chunk_size |

---

## Part 4: Cross-Reference Analysis

### 4.1 Coordinate Origin

- **Python:** origin = (chunk_x * chunk_size_m, chunk_y * chunk_size_m), chunk_size_m = 512 * resolution_m * 2^lod.
- **Shader:** Does not use chunk origin for cell sampling; mesh is in chunk-local space and UV 0..1 spans that chunk.
- **Selection:** chunk_origin = (cx * chunk_size, cy * chunk_size), chunk_size = 512 * _resolution_m * 2^lod.

**Match:** YES — Python and selection use the same chunk origin. Shader relies on mesh position (chunk at world origin of the mesh) and UV 0..1 = chunk extent.

### 4.2 World Extent Mapping

- **Python:** Pixel index i in 0..511 maps to local = (i/511)*chunk_size_m. So pixel 0 = 0 m, pixel 511 = chunk_size_m (46080 m at LOD0 @ 90 m).
- **Shader:** UV 0..1 maps to local 0..chunk_world_size (mesh last vertex at (mesh_res-1)*spacing = chunk_world_size). So UV 0 = 0 m, UV 1 = chunk_world_size.
- **Selection:** px = local/chunk_size * 512, so pixel 0 = local 0, pixel 511 = local ≈ chunk_size (for local = chunk_size, px = 512 → clamped to 511).

**Match:** Almost. Same nominal extent 0..chunk_size, but see pixel-scale mismatch below.

### 4.3 Pixel/Texel Scale (511 vs 512)

- **Python:** For pixel index i, local = (i / **511**) * chunk_size. So 512 pixels cover [0, chunk_size] with samples at i/511 for i = 0..511 (both ends included).
- **Selection:** px = round(local / chunk_size * **512**). So the chunk is divided into 512 equal segments; pixel i covers [i/512*chunk_size, (i+1)/512*chunk_size).

So:

- Same world extent 0..chunk_size.
- Different mapping: Python uses divisor **511**, selection uses multiplier **512**.
- At local = (256/511)*chunk_size, Python has pixel 256; selection gives px = round(256/511*512) ≈ round(256.5) = 256 or 257 → can be off by one.
- At boundaries (e.g. near cell edges) this can choose the wrong texel and thus the wrong cell.

**Match:** NO — 511 vs 512 scale causes a systematic half-pixel shift and possible off-by-one in texel index.

### 4.4 Pixel/Texel Center Convention

- **Python:** Pixel index i represents world at local = (i/511)*chunk_size (no explicit “center” vs “edge”; the sample is at that point).
- **Shader:** Samples at interpolated UV (texel center in normalized coords); UV 0..1 from mesh matches local 0..chunk_world_size; mesh uses (mesh_res-1) = 511 for UV scale, so consistent with “511 steps” for 512 vertices.
- **Selection:** Treats pixel as covering local range [px/512*chunk_size, (px+1)/512*chunk_size] (implied by local/chunk_size*512). So selection assumes 512 equal segments; Python assumes 511 segments between 512 samples.

**Match:** NO — Python’s 511-based indexing vs selection’s 512-based indexing is the main coordinate mismatch.

### 4.5 V-Flip / Z Coordinate

- **Python:** `local_z = (jj / 511) * chunk_size_m` with jj row index; array[row, col] → image row 0 = jj=0 = local_z=0 (North), row 511 = local_z=chunk_size (South). No explicit flip.
- **Shader:** v_uv.y from mesh: UV.y = y/(mesh_res-1), y=0 = first row of vertices = local z=0, y=511 = local z=chunk_size. So UV.y and local Z increase together; no V-flip in mesh or shader.
- **Selection:** py = round(local_z / chunk_size * h). local_z=0 → py=0 (first row), local_z=chunk_size → py=511. Same as Python.

**V-flip detected:** NO — Z/local_z vs row/py direction is consistent across the three.

---

## Suspected Mismatches

1. **511 vs 512 in local→pixel (main candidate for selection misalignment)**  
   - Python: local → pixel index = **local / chunk_size * 511** (so pixel i = local at i/511*chunk_size).  
   - Selection: px = **local / chunk_size * 512** (then round and clamp).  
   - Consequence: Same world position can map to different texels (e.g. off-by-one), so selection can read a different cell than the one drawn under the cursor.

2. **Optional: Mesh extent vs “logical” extent**  
   - Mesh: vertices from 0 to (mesh_res-1)*actual_vertex_spacing = chunk_world_size, so mesh extent = chunk_size.  
   - `_get_mesh_extent_for_lod()` in chunk_manager uses (mesh_res-1)*vertex_spacing with vertex_spacing = resolution_m*(1<<lod). For LOD0 that is 511*90 = 45990 m, which is **not** the same as chunk_world_size (46080 m) used elsewhere. So any code that uses `_get_mesh_extent_for_lod()` for selection or texture extent would assume 45990 m; the texture and mesh actually span 46080 m. This is only a problem if selection or other logic uses `_get_mesh_extent_for_lod()` for world→pixel; currently selection uses `_get_chunk_world_size()`, so the main fix remains the 511 vs 512 scale.

---

## Questions for Architect

1. **Intended convention:** Should texture pixel index be “512 samples over [0, chunk_size]” (current selection: local/chunk_size*512) or “512 samples at 0, 1/511, 2/511, …, 1” (current Python: i/511*chunk_size)? Resolving this will fix the 511 vs 512 mismatch.

2. **Godot get_pixel(px, py):** Does Godot’s Image.get_pixel() use (0,0) as top-left (row 0 = first row) and no vertical flip? Assumed yes; worth confirming for PNG load.

3. **Texel center vs edge:** Should “cell at cursor” be defined as the texel whose **center** is closest to the hit point, or the texel that contains the hit point (segment boundaries at i/511 or i/512)? This affects whether to use round(local/chunk_size * 511) or a different rule.

4. **Cell metadata centers:** They are global (axial_to_center with no chunk offset). Selection uses chunk-local texture then looks up cell_id in metadata. If 511/512 is fixed, is there any remaining offset between “cell center” in metadata and the hex drawn by the shader for that cell (e.g. origin of hex grid vs chunk origin)?

---

## Recommended Fix (for implementer)

To align selection with Python (and thus with the drawn grid):

- In `chunk_manager.gd`, `_get_cell_id_at_chunk_impl()`, change local→pixel to use **511** so it matches Python’s (i/511)*chunk_size:

  - Replace  
    `px = clampi(int(round(local_x / chunk_size * float(w))), 0, w - 1)`  
    with  
    `px = clampi(int(round(local_x / chunk_size * float(w - 1))), 0, w - 1)`  
    (and same for py with h).

  So: **px = round(local_x / chunk_size * 511)**, **py = round(local_z / chunk_size * 511)**.

  Then pixel 0 = local 0, pixel 511 = local chunk_size, and the mapping matches the Python texture generation.

---

*Report generated from code inspection of generate_cell_textures.py, terrain.gdshader, terrain_loader.gd, and chunk_manager.gd.*
