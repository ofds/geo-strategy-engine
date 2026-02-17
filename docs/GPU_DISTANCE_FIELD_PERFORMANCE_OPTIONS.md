# GPU Distance Field — Performance Options

**Context:** Phase B can spike to 130–240 ms when many chunks need GPU-generated distance fields in one frame. Per-frame cap (e.g. 2 generations) helps; below are options to tune or improve further.

---

## 1. Verify / tighten per-frame cap

- **Current:** `MAX_GPU_DISTANCE_GENERATIONS_PER_FRAME = 2` in `terrain_loader.gd`. At most 2 chunks per frame get a GPU distance texture; the rest use the 8-direction fallback grid.
- **Check:** In debug build you should see `"GPU distance cap reached (2/frame), chunk (x, y, LOD z) will use fallback grid"` when more than 2 chunks need generation in one frame. If you never see that, the reset may run at the wrong time (see below).
- **Tighten:** Set to `1` to add at most ~5–10 ms per frame from distance generation; more chunks will use fallback until reloaded.

---

## 2. Reset cap from ChunkManager (recommended)

The cap counter is reset in `TerrainLoader._process()`. If `ChunkManager._process()` runs **before** `TerrainLoader._process()` in the same frame, Phase B runs with the **previous** frame’s counter, so you can get more than 2 generations per frame.

**Fix:** Reset the counter at the **start of ChunkManager._process()** (before Phase B), so the “frame” is aligned with when Phase B runs. Then the cap is reliable.

---

## 3. Pre-generate PNGs (zero runtime cost)

- Run the Python pipeline (or a future batch GPU tool) so all distance field PNGs exist under `data/terrain/cells/lod{N}/chunk_*_distance.png`.
- At runtime, `_load_distance_field_texture` loads from file and never calls the GPU path for those chunks.
- **Pros:** No GPU generation cost, no cap needed, best frame time.
- **Cons:** One-time or periodic batch run; not suitable if cells change at runtime.

---

## 4. Deferred generation + material update

- When the file is missing, **do not** generate during chunk build. Build the chunk with `has_distance_field = false` (fallback grid).
- Enqueue `(chunk_key, lod, x, y)` (and a way to update the mesh instance) in a “pending GPU distance” queue.
- In `TerrainLoader._process()` (or ChunkManager), drain 1–2 items per frame: run the generator, cache the texture, then **update that chunk’s material** (e.g. set `boundary_distance_texture` and `has_distance_field = true` on the existing MeshInstance3D).
- **Pros:** Every chunk eventually gets the distance field; frame time stays bounded.
- **Cons:** Needs a way to get the MeshInstance3D for a chunk_key (e.g. ChunkManager keeps a map, or passes a callback).

---

## 5. Async GPU (Phase 3)

- After `compute_list_end()`, do **not** call `rd.sync()` in the same frame. Store the output texture RID and a “pending” state.
- Next frame (or a later one), poll for completion (e.g. fence or assume one-frame latency), then readback and create `ImageTexture`, cache it, and update the chunk’s material.
- **Pros:** GPU and CPU overlap; no blocking.
- **Cons:** More complex (double-buffering, tracking which chunk is which), and Godot’s RD API usage must be checked for async patterns.

---

## 6. Lower resolution for GPU output

- Generate the distance field at **256×256** instead of 512×512 (smaller dispatch, ~4× less work), then either:
  - Use as-is and adjust the terrain shader’s sampling, or
  - Upscale to 512×512 on CPU/GPU before creating the texture.
- **Pros:** Lower GPU time per chunk.
- **Cons:** Slightly coarser grid or extra upscale step.

---

## 7. Larger / smarter cache

- Increase `DISTANCE_TEXTURE_CACHE_MAX` (e.g. 400) so more generated textures stay in memory when panning.
- Or change eviction: e.g. don’t evict chunks that are still in ChunkManager’s “desired” set (would require ChunkManager to expose that or a callback).
- **Pros:** Fewer repeated generations when revisiting the same area.
- **Cons:** More VRAM; eviction logic is more involved.

---

## 8. Summary

| Option                    | Effort  | Effect on spikes     | Notes                          |
|---------------------------|---------|----------------------|--------------------------------|
| Cap = 1                   | Trivial | Stronger smoothing   | More fallback chunks           |
| Reset cap in ChunkManager | Small   | Cap actually 2/frame | Do this so the cap is reliable |
| Pre-generate PNGs         | Medium  | Removes GPU path     | Best if cells are static       |
| Deferred + material update| Medium  | Bounded, full quality| Every chunk gets distance      |
| Async GPU                 | High    | No blocking          | Phase 3                        |
| 256² generation           | Small   | ~4× less GPU time    | Slight quality trade-off       |
| Bigger / smarter cache     | Small–Medium | Fewer regenerations | When revisiting areas          |

Recommendation: **Reset the cap in ChunkManager** so the current cap is reliable, then either **pre-generate PNGs** for static data or add **deferred generation + material update** if you want every chunk to get the distance field without spikes.
