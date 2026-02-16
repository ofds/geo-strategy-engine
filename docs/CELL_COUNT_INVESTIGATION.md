# Cell Count Investigation Results

**Date:** 2026-02-16  
**Region:** Europe @ 90m  
**Actual total cells:** 29,358,100  
**Expected (pre-investigation):** ~58,000  

---

## 1. Cell Count by LOD

- **LOD 0:** Not tracked per LOD (see below)
- **LOD 1:** Not tracked per LOD
- **LOD 2:** Not tracked per LOD
- **Total:** 29,358,100 (single global registry)
- **Are these unique cells or the same cells at different LODs?** **SHARED**

**Explanation:** `cell_metadata.json` does **not** store LOD per cell. There is a single global registry: each entry is a unique **(axial_q, axial_r)** hex with one compact ID (1..29,358,100). Pass 1 in `generate_cell_textures.py` collects unique (q,r) from **all** chunks at LOD 0, 1, and 2 into one **set**; the same hex at (q=10, r=20) appears in many chunks and LODs but is added once. Pass 2 assigns one ID per unique (q,r). So every geometric hex has **one** cell ID used across all LODs. The 29M count is the total number of distinct hex cells that the Europe terrain extent overlaps—not a sum over LODs.

---

## 2. Terrain Resolution Verification

- **Region:** Europe
- **Resolution from terrain_metadata.json:** **90** m
- **Expected resolution:** 90 m
- **Match:** **YES**

`config/constants.gd` and the pipeline use 90 m at LOD 0; chunk size = 512 × 90 = **46,080 m** per side at LOD 0 (not 16,384 m).

---

## 3. Single Chunk Density

- **Test chunk:** LOD 0, chunk_0_0 (first chunk)
- **Chunk size (LOD 0):** 46,080 m × 46,080 m (from constants: 512 × 90 m)
- **Hex size:** radius ≈ 577.35 m (flat-to-flat 1000 m); hex area ≈ 866,000 m²
- **Theoretical cells per chunk:** Chunk area / hex area ≈ (46,080)² / 866,000 ≈ **2,452**
- **Actual unique cell IDs in texture:** **2,565**
- **Ratio:** 2,565 / 2,452 ≈ **1.05**
- **Assessment:** **MATCHES EXPECTATION** (slight overcount from edge hexes and sampling)

So per-chunk density is correct. The “~268” in the investigation prompt assumed 16,384 m chunk size and a different hex spacing; with 46,080 m chunks and 577 m hex radius, ~2,500 unique cells per chunk is correct.

---

## 4. Sparse Collection Logic Review

- **Does each geometric hex get one cell ID across all LODs?** **YES**
- **Does the same hex location get different IDs per LOD?** **NO**
- **Explanation:**
  - **Pass 1** (`collect_unique_axial_cells`): Loops over all chunks at LOD 0, 1, 2. For each chunk it computes (q_int, r_int) from world coordinates using the **same** `world_to_axial` / `_chunk_axial_coords` and `HEX_RADIUS_M`. So the same world position always maps to the same (q, r). Results are merged into a single **set** of (q, r) tuples—duplicates from different chunks/LODs are automatically collapsed.
  - **Pass 2** (`build_sparse_cell_registry_and_id_map`): Sorts the unique (q, r) set, assigns compact IDs 1..N, builds one `id_map` and one `cell_registry`. No LOD is stored; each (q, r) appears once.
  - **Pass 3:** Generates textures per chunk; each pixel’s (q, r) is looked up in the **same** global id_map. So LOD 0, 1, and 2 textures all reference the same cell ID for the same hex.

---

## Root Cause Analysis

The **29M count is correct**, not a bug. The “expected” ~58K was a mis-estimate.

- Europe terrain extent (from metadata): 68,400 × 43,200 pixels @ 90 m → **6,156 km × 3,888 km**.
- Terrain area ≈ 2.39×10¹³ m².
- Hex area (pointy-top, radius 577.35 m) ≈ 866,000 m².
- Number of hexes overlapping this area ≈ terrain area / hex area ≈ **27–30M**, which matches 29,358,100.

So we have one ID per geometric hex over the full continent; 29M is the correct order of magnitude for Europe at 90 m resolution with 1 km (flat-to-flat) hexes.

---

## Impact Assessment

- **Does 29M cells break anything?** **NO** (with current encoding.)
- **24-bit encoding limit:** 16,777,216 (16M).
- **Current count:** 29,358,100.
- **Historical note:** This would have exceeded 24-bit capacity by ~13M cells. The pipeline **already** uses **32-bit RGBA** encoding (implemented earlier in this chat). Cell IDs are stored as R=(id>>24), G=(id>>16), B=(id>>8), A=id; limit = 4,294,967,295.
- **Will cell IDs overflow and wrap around?** **NO** (32-bit supports up to 4B cells.)
- **Do we need to switch to a different encoding scheme?** **NO** — 32-bit RGBA is in place and sufficient.

---

## Recommendation

- **Proceed to Phase 1B.** Cell generation is correct; the 29M count reflects the real number of unique hex cells over Europe at 90 m with 1 km hexes. Encoding is 32-bit; no overflow. Shader integration (Phase 1B) should sample the cell texture as **RGBA** and decode:  
  `cell_id = int(r*255.0)*16777216 + int(g*255.0)*65536 + int(b*255.0)*256 + int(a*255.0)` (or equivalent integer reconstruction).

**Optional follow-up:** If a ~58K-style “region” was intended (e.g. a much coarser hex grid or a smaller area), that would be a **design** choice (e.g. larger `HEX_SIZE_M` or a sub-region), not a fix to the current algorithm.
