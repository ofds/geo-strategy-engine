# Cell Texture Generation Analysis — Why Are Textures Missing?

**Purpose:** Analyze existing cell texture files and the generation script to determine why F11 diagnostic shows many RED (texture not bound) chunks, and provide the exact fix.

---

## Part 1: Existing Files

### File Counts

| LOD | Files on disk | Chunks in metadata | Match |
|-----|----------------|--------------------|-------|
| LOD 0 | 11,391 | 11,390 | ✓ (1 extra: likely `chunk_0_0_cells_debug.png` from `--debug-viz`) |
| LOD 1 | 2,881 | 2,881 | ✓ |
| LOD 2 | 748 | 748 | ✓ |

**Total LOD 0+1+2:** 15,020 files on disk vs 15,019 chunks in metadata — **generation coverage is complete** for all chunks the script is designed to produce.

### Chunk Coordinate Range (from metadata and files)

| LOD | X range | Y range | Grid (full rect) | Chunks in metadata | Files on disk |
|-----|---------|---------|-------------------|--------------------|---------------|
| LOD 0 | 0 to 133 (134) | 0 to 84 (85) | 134×85 = 11,390 | 11,390 | 11,391 |
| LOD 1 | 0 to 66 (67) | 0 to 42 (43) | 67×43 = 2,881 | 2,881 | 2,881 |
| LOD 2 | 0 to 33 (34) | 0 to 21 (22) | 34×22 = 748 | 748 | 748 |

- **Expected total (full grid):** 11,390 + 2,881 + 748 = **15,019** (matches metadata).
- **Actual files:** 15,020 (one extra in LOD 0 as noted).
- **Missing:** **0** chunks — no chunks are missing from generation for LOD 0–2.
- **Coverage:** **100%** for the chunk set defined by `terrain_metadata.json`.

### File Size Check

Sample file sizes (from `tools/analyze_cell_textures.py`):

- **LOD 0:** ~20–27 KB average (sample ~25.5 KB)
- **LOD 1:** ~37–39 KB average
- **LOD 2:** ~49–50 KB average

All sampled files are **well below** the 200–800 KB “typical” for lossless 512×512 RGBA because PNG compression is very effective when most pixels share the same cell ID (large flat regions). So:

- **Small size is expected** for terrain with large hex cells and relatively uniform IDs per chunk.
- **Issues detected:** None — no evidence of corruption or empty textures from size alone.

---

## Part 2: Generation Script Analysis

**File:** `tools/generate_cell_textures.py`

### Chunk range logic

The script **does not** use a hardcoded region or chunk range. It uses **only** the chunk list from `terrain_metadata.json`:

```367:371:tools/generate_cell_textures.py
def get_chunks_at_lod(metadata: Dict, lod: int) -> List[Tuple[int, int]]:
    """Return list of (chunk_x, chunk_y) for the given LOD from terrain_metadata chunks."""
    chunks = metadata.get("chunks", [])
    return [(c["x"], c["y"]) for c in chunks if c.get("lod") == lod]
```

Pass 3 iteration (main loop):

```516:528:tools/generate_cell_textures.py
        for lod in lods:
            chunks = get_chunks_at_lod(metadata, lod)
            if not chunks:
                print(f"LOD {lod}: no chunks in metadata, skipping")
                continue
            lod_dir = cells_dir / f"lod{lod}"
            lod_dir.mkdir(parents=True, exist_ok=True)
            it = tqdm(chunks, desc=f"LOD {lod}", unit="chunk") if tqdm else chunks
            for (chunk_x, chunk_y) in it:
                texture = generate_cell_texture(...)
                path = lod_dir / f"chunk_{chunk_x}_{chunk_y}_cells.png"
                save_texture_cells(texture, path)
```

So the chunk set is exactly `metadata["chunks"]` filtered by `lod`; there is **no** separate region bounds or min/max chunk iteration.

### Region bounds

- **Script:** Does not define `REGION_BOUNDS` or lat/lon; it only reads `terrain_metadata.json` (written by `process_terrain.py`).
- **Metadata:** `data/terrain/terrain_metadata.json` has `bounding_box`: lat 35–71, lon -12–45 (Europe), `resolution_m`: 90, `master_heightmap_width/height`: 68400×43200, `total_chunks`: 15260.

### Skip conditions

- **None.** The script iterates every `(chunk_x, chunk_y)` returned by `get_chunks_at_lod(metadata, lod)` and always generates and saves a texture. There is no `if cell_count == 0: continue` or ocean/empty skip.

### Expected chunk count

- **Source:** `terrain_metadata.json` → 11,390 (LOD 0) + 2,881 (LOD 1) + 748 (LOD 2) = **15,019** chunks for LOD 0–2.
- **Actual generated:** 15,020 files (LOD 0 has one extra debug file if `--debug-viz` was used).
- **Conclusion:** Expected and actual match; no missing chunks.

### LOD generation

- **LODs generated:** 0, 1, 2 (default `--lods 0,1,2`).
- **Logic:** Each LOD is generated **independently** from the same metadata chunk list. LOD 1/2 are **not** derived from LOD 0; they use the same `id_map` and `get_chunk_origin(chunk_x, chunk_y, lod, resolution_m)` so coordinates and cell IDs stay consistent.

### Error handling

- **On exception:** The main loop has no `try/except` around `generate_cell_texture` or `save_texture_cells`. A single chunk failure would **abort** the script (no silent skip).
- **Multiprocessing:** `_worker_cell_texture` has no try/except; a worker failure would propagate and can stop the pool.
- **Conclusion:** Partial generation would imply the script was **interrupted** (e.g. Ctrl+C, OOM, disk full), not “skip empty chunk” logic.

---

## Part 3: Root Cause

**Identified scenario:** **Not A, B, C, or D** — generation is **complete** for LOD 0–2. The RED chunks in F11 are explained by **engine behavior**, not missing files.

### Explanation

1. **All metadata chunks (LOD 0–2) have cell textures on disk.** File counts and coordinate ranges match; there are no missing PNGs for the chunk set the script uses.

2. **The engine also loads LOD 3 and LOD 4 chunks.**  
   `ChunkManager` builds a “desired” set that includes LOD 0–4. For each loaded chunk it calls `_load_cell_texture(chunk_x, chunk_y, lod)`.

3. **Cell textures are only generated and loaded for LOD 0–2.**  
   In `terrain_loader.gd`, `_load_cell_texture` returns `null` for `lod > 2`:

```225:227:core/terrain_loader.gd
func _load_cell_texture(chunk_x: int, chunk_y: int, lod: int) -> Texture2D:
	if lod > 2:
		return null
```

4. **When `cell_tex` is null,** the chunk uses the **shared** material (no per-chunk `cell_id_texture`). The shader then uses the default 1×1 sampler, which is treated as “no valid cell texture” and shown as **RED** in the F11 diagnostic.

5. **So RED is expected for all LOD 3 and LOD 4 chunks.** At medium to high altitude, many visible chunks are LOD 3 or 4, so “many red chunks” is consistent with **no cell textures for LOD 3+**, not with missing files for LOD 0–2.

### Evidence

- File counts: 11,390 / 2,881 / 748 for LOD 0/1/2 match metadata.
- No skip logic in the script; no wrong range; no coordinate mismatch.
- Engine explicitly returns `null` for `lod > 2` and uses shared material when `cell_tex` is null.

---

## Part 4: Fix (and optional improvement)

### 1. No change required in the generation script

Generation is correct and complete. **Do not** re-run a full multi-hour regeneration under the assumption that chunks are missing.

### 2. Optional: Reduce confusion from F11 (RED on LOD 3/4)

If you want F11 to show “no cell texture” only when a texture **could** exist (LOD 0–2), you can treat LOD 3+ differently in the shader or in the loader:

**Option A — Shader:** Add a uniform (e.g. `has_cell_texture`) set per chunk: `true` for LOD 0–2 when a texture is bound, `false` for LOD 3+ or when texture is null. In the F11 debug branch, if `has_cell_texture` is false and LOD ≥ 3, show gray (or skip grid) instead of RED.

**Option B — Loader:** For LOD 3/4, still pass a small “dummy” 1×1 texture (e.g. single pixel cell_id 0) so the shader always has a bound texture and doesn’t show RED. This avoids shader changes but uses a bit more state.

**Option C — Do nothing:** Keep current behavior and document that **RED = no cell texture (expected for LOD 3 and LOD 4)**. Grid and selection are only defined for LOD 0–2 anyway.

### 3. Verification steps (confirm no missing files)

Run from project root:

```powershell
# Count files (PowerShell)
(Get-ChildItem "data\terrain\cells\lod0" -Filter "*.png").Count   # expect 11390 or 11391
(Get-ChildItem "data\terrain\cells\lod1" -Filter "*.png").Count   # expect 2881
(Get-ChildItem "data\terrain\cells\lod2" -Filter "*.png").Count   # expect 748
```

Optional: ensure no chunk in metadata is missing its file:

```bash
python -c "
import json
from pathlib import Path
with open('data/terrain/terrain_metadata.json') as f:
    m = json.load(f)
cells = Path('data/terrain/cells')
missing = []
for c in m['chunks']:
    lod = c.get('lod')
    if lod not in (0,1,2):
        continue
    p = cells / f'lod{lod}' / f\"chunk_{c['x']}_{c['y']}_cells.png\"
    if not p.exists():
        missing.append((lod, c['x'], c['y']))
print('Missing:', len(missing))
if missing:
    print(missing[:20])
"
```

Expected: **Missing: 0**.

### 4. When to re-run generation

Re-run `generate_cell_textures.py` only if:

- You change the region or re-run `process_terrain.py` and get a **new** `terrain_metadata.json` with different chunks, or  
- You add a new LOD (e.g. LOD 3) to the cell system and extend the script and loader.

Command (for reference):

```bash
python tools/generate_cell_textures.py --metadata data/terrain/terrain_metadata.json --output-dir data/terrain --lods 0,1,2
```

---

## Summary

| Question | Answer |
|----------|--------|
| Are cell textures missing for chunks the script targets? | **No.** LOD 0–2 file counts match metadata (15,019 chunks → 15,020 files). |
| Why does F11 show many RED chunks? | **LOD 3 and LOD 4** chunks never get a cell texture; engine returns `null` and uses shared material → RED. |
| Do we need to fix the generation script? | **No.** No skip logic, no wrong range, no coordinate mismatch. |
| What can we do next? | (1) Treat F11 RED for LOD 3/4 as expected, or (2) add optional shader/loader tweak so RED only means “missing where it should exist”. (3) Run the verification script above to confirm 0 missing files. |

After verification, you can declare Phase 1C cell texture generation **complete** for LOD 0–2; red in F11 for coarser LODs is expected and does not indicate missing assets.
