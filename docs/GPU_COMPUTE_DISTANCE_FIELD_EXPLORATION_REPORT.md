# GPU Compute Shader Exploration Report — Distance Field Generation

**Date:** February 17, 2026  
**Explorer:** Coding Agent  
**Purpose:** Understand codebase for GPU distance field generation integration (read-only exploration).

---

## 1. Existing Compute Shader Usage

**Status:** Found existing compute shaders (one compositor effect).

**Details:**

- **Files found:**
  - `rendering/hex_overlay_screen.glsl` — compute shader (#version 450, `layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in`)
  - `rendering/hex_overlay_compositor.gd` — CompositorEffect that compiles and runs it via RenderingDevice

- **Usage:** Screen-space hex overlay: reads depth + color, reconstructs world XZ, draws grid/hover/selection. Single fullscreen compute pass (image2D output, depth sampler, uniform buffer for Params).

- **Patterns:**
  - `RenderingServer.get_rendering_device()` for `RenderingDevice`
  - `RDShaderSource` with `language = SHADER_LANGUAGE_GLSL`, `source_compute = src`
  - `shader_compile_spirv_from_source()` → `shader_create_from_spirv()` → `compute_pipeline_create()`
  - Uniforms: `UNIFORM_TYPE_IMAGE` (color output), `UNIFORM_TYPE_SAMPLER_WITH_TEXTURE` (depth), `UNIFORM_TYPE_UNIFORM_BUFFER` (Params)
  - `compute_list_begin()` → `bind_compute_pipeline` → `bind_uniform_set` → `compute_list_dispatch(x_groups, y_groups, 1)` → `compute_list_end()`
  - All RIDs freed in `NOTIFICATION_PREDELETE`

**Godot version:** 4.5 (from `project.godot`: `config/features=PackedStringArray("4.5", "Forward Plus")`)  
**Rendering backend:** Vulkan (Forward Plus implies Vulkan in Godot 4)  
**Platform:** Not explicitly restricted; project is desktop (Windows from user_info).

**Recommendation:** Follow the same pattern: GLSL compute shader, compile to SPIR-V, create pipeline, create buffers/textures via RenderingDevice, dispatch. For distance field we need: storage image (write-only output), read-only inputs (cell ID texture or cell centers buffer), uniform buffer for chunk params (origin, resolution, LOD, hex radius).

---

## 2. Distance Field Loading Path

**Entry point:** `core/terrain_loader.gd` :: `_load_distance_field_texture(chunk_x, chunk_y, lod)` (lines 264–279).

**Call chain:**

```
[ChunkManager._process]
  → (streaming) load_queue pop → terrain_loader.start_async_load(x, y, lod)
  → WorkerThreadPool runs TerrainWorker.compute_chunk_data (heightmap + mesh arrays only; NO textures)
  → _drain_completed_async_to_phase_b() → _pending_phase_b
  → _do_one_phase_b_step()
     → step 0: terrain_loader.finish_load_step_mesh(computed)
     → step 1: terrain_loader.finish_load_step_scene(computed, mesh, false)  (core/terrain_loader.gd:986)
        → _load_cell_texture(chunk_x, chunk_y, lod)
        → _load_distance_field_texture(chunk_x, chunk_y, lod)   [LINE 1010]
        → mat.set_shader_parameter("boundary_distance_texture", distance_tex)  [LINES 1016, 1028]
        → mat.set_shader_parameter("has_distance_field", true/false)
     → step 2: finish_load_step_collision(...)
```

Sync path (rare): `ChunkManager._load_chunk()` (line 1276) → `terrain_loader.load_chunk()` (line 126) → same material setup at lines 177–202, calling `_load_distance_field_texture` at 180 and setting `boundary_distance_texture` at 186/198.

**Cache behavior:**

- **Cache type:** FIFO  
- **Cache size:** 200 textures (`DISTANCE_TEXTURE_CACHE_MAX = 200`)  
- **Shared with cell ID textures:** No; separate caches (`_distance_texture_cache` / `_distance_texture_cache_order`) but same key pattern `"lod%d_%d_%d"` (lod, chunk_x, chunk_y).

**Async loading:**

- **Current:** Distance texture is loaded on the **main thread** during Phase B step 1 (`finish_load_step_scene`). Async path only moves heightmap decode + mesh computation to worker; texture loading (PNG load + cache) is main-thread.
- **Can GPU generation be async:** Yes in principle: dispatch compute on main (or when RD is available), then either (a) wait for completion and create ImageTexture from buffer on main, or (b) use a double-buffer and poll completion next frame. GPU work itself is non-blocking for CPU but must be submitted and completed on a thread that has RenderingDevice access (main thread in Godot).

**GPU insertion point:** Replace or supplement the call to `_load_distance_field_texture(chunk_x, chunk_y, lod)` inside `finish_load_step_scene` (and sync `load_chunk`). Options: (1) If pre-generated file exists, load as now; else (2) call a new function e.g. `_generate_distance_field_gpu(chunk_x, chunk_y, lod)` that runs compute, then creates Texture2D from result and returns it (and optionally caches it). Same insertion point for both sync and async Phase B scene step.

---

## 3. Cell Metadata Structure

**Loading location:** `core/chunk_manager.gd` :: `_load_cell_metadata()` (lines 161–216), called from `_ready()` (line 126).

**Data structure:**

```gdscript
# In-memory: cell_metadata: Dictionary (key = cell_id int, value = sub-dict)
# From JSON: data["cells"] = { "1": { ... }, "2": { ... } }
cell_metadata[cell_id] = {
    "center_x": float,
    "center_z": float,
    "axial_q": int,
    "axial_r": int,
    "neighbors": Array  # 6 neighbor cell IDs
}
```

**Size:** Europe: file can be 200+ MB (docs say 8 GB for full Europe; ChunkManager skips load if file > 400 MB). Cell count ~29.4M for Europe. Smaller regions (e.g. Alps) load fully.

**GPU upload considerations:**

- **Upload entire metadata?** Unlikely for Europe (hundreds of MB to GB). Possible for small regions.
- **Alternative:** Per-chunk subset. For one chunk we only need centers of cells that appear in that chunk’s cell ID texture. Python already does this: `unique_ids = np.unique(cell_ids)` then for each uid load `center_x`, `center_z`. So per chunk: list of (cell_id, center_x, center_z) or compact float2 array of centers (order matched to a small cell list). Typical chunk has far fewer than 29M cells (hundreds to low thousands).
- **Estimated GPU buffer size:** Per chunk: e.g. max ~few thousand cells × 2 floats × 4 bytes = tens of KB. A single SSBO or uniform buffer of e.g. 64 KB can hold several thousand vec2 centers. For “all Europe” on GPU at once: not required; stream per-chunk cell data.

**Access pattern:** Given `cell_id`, center is `cell_metadata[cell_id]["center_x"]`, `cell_metadata[cell_id]["center_z"]`. Used by selection (e.g. `get_cell_info(cell_id)`). For GPU: build a small array of centers for the chunk’s unique cell IDs (from cell texture or from metadata filtered by chunk bounds).

---

## 4. Chunk Creation Flow

**Flow:**

```
[Camera moves]
  → _process() every UPDATE_INTERVAL (0.25–0.5 s)
  → _update_chunks() (chunk_manager.gd ~706)
  → _determine_desired_chunks(camera_pos) (line 1023)
  → to_load = desired not in loaded_chunks
  → load_queue.append(...) for each to_load (lines 871–876)
  → In same _process, after _drain_completed_async_to_phase_b():
     → If load_queue.size() > 0 and pending_loads < cap: pop one, start_async_load(x, y, lod) (lines 452–461)
  → Worker runs: TerrainWorker.compute_chunk_data (heightmap load, mesh arrays); result in args["result"]
  → Next frame(s): _drain_completed_async_to_phase_b() moves completed to _pending_phase_b
  → _do_one_phase_b_step(): step 0 MESH → step 1 SCENE → step 2 COLLISION
  → finish_load_step_scene(computed, mesh, false) creates MeshInstance3D, loads cell_tex + distance_tex, sets material, adds to chunks_container
  → Chunk visible
```

**Timing:**

- **Current chunk loading time:** Variable (heightmap decode + mesh + collision). Frame budget: `FRAME_BUDGET_MS = 8.0` ms for streaming, `INITIAL_LOAD_BUDGET_MS = 16.0` ms during initial load (chunk_manager.gd 55–56). Phase B steps are limited by this budget.
- **Async loading:** Yes for Phase A (heightmap + mesh on WorkerThreadPool). Phase B (mesh create, texture load, scene add, collision) is main-thread, budgeted.
- **Budget per frame:** 8 ms (streaming), 16 ms (initial).

**GPU generation integration options:**

- **Option A: In terrain_loader during texture loading (e.g. inside finish_load_step_scene / _load_distance_field_texture)**  
  - Pros: Single place; same code path for sync and async; cache stays in TerrainLoader.  
  - Cons: Must not exceed frame budget (e.g. 8 ms); if GPU generation takes longer, need to defer or run across frames.  
  - Feasibility: Medium (need async GPU: dispatch, later frame poll + create texture, or generate off-thread and hand back texture on main).

- **Option B: In ChunkManager before calling loader**  
  - Pros: ChunkManager could request “prepare distance for (x,y,lod)” one frame, then next frame pass ready texture to loader.  
  - Cons: ChunkManager doesn’t own texture cache; would need TerrainLoader API to “set” or “get generated” distance texture; flow more complex.  
  - Feasibility: Medium.

- **Option C: On-demand in shader (runtime, per-frame)**  
  - Pros: No precomputation; always up to date.  
  - Cons: Would require passing all cell centers for the chunk (or a large subset) and doing SDF in fragment shader per pixel; likely too heavy (many cells, complex branching). Not the same as “compute shader that writes a texture once.”  
  - Feasibility: Hard / not recommended for same design.

**Recommendation:** Option A: keep loading/generation in TerrainLoader. Try “generate on main thread when file missing” first (dispatch, sync wait, create ImageTexture, cache). If a single chunk exceeds budget, architect can add “deferred generation” (e.g. placeholder texture, queue chunk for GPU, next frame poll and swap texture).

---

## 5. Shader Setup & Texture Formats

**Shader file:** `rendering/terrain.gdshader`

**Distance texture usage:**

```glsl
uniform sampler2D boundary_distance_texture : hint_default_white, filter_linear, repeat_disable;
// ...
if (has_distance_field) {
    float distance_to_boundary = texture(boundary_distance_texture, v_uv).r;
    distance_to_boundary *= 500.0;  // DISTANCE_NORMALIZE_M
    float alpha = 1.0 - smoothstep(0.0, grid_line_width_m, distance_to_boundary);
    // ... grid line mix
}
```

**Texture format:**

- **Current:** Grayscale PNG, 8-bit (R or L). Shader uses `.r`. Normalized 0–1 = 0–500 m (Python `DISTANCE_NORMALIZE_M = 500.0`).
- **Size:** 512×512 per chunk (LOD 0–2).
- **Normalized range:** 0–1 → 0–500 m.

**Runtime texture creation:**

- **Method:** Today textures come from `load(path)` (PNG). For GPU-generated: would need `Image` from buffer (e.g. readback from RD texture or fill from PackedByteArray) then `ImageTexture.create_from_image(img)` (pattern used in `hex_grid_mesh.gd`).
- **RenderingDevice textures directly:** High-level ShaderMaterial expects Texture2D/Resource. To use an RD texture in the existing terrain shader we’d need a path that creates a Texture2D backed by or copied from RD (e.g. create Image from RD buffer, then ImageTexture). So “direct” use of RD texture in current material is not standard; readback or copy to Image is the practical approach unless we switch to full RD rendering for terrain.
- **CPU readback:** Yes for current design: compute writes to RD storage image/buffer → read back to CPU → `Image` → `ImageTexture.create_from_image()` → `set_shader_parameter("boundary_distance_texture", texture)`. Alternative (no readback): use a custom texture implementation that wraps an RID; not documented in explored code.

**Shader uniform setup:** In `terrain_loader.gd`: `finish_load_step_scene` and `load_chunk` set `mat.set_shader_parameter("boundary_distance_texture", distance_tex)` and `has_distance_field`. ChunkManager also sets `chunk_origin_xz` on the mesh instance (line 633) for chunk-local math.

---

## 6. Performance & Threading

**Current loading architecture:**

- **Main thread:** Phase B (mesh build, texture load, material set, add to scene, collision), and submission of Phase A tasks.
- **Background thread:** Phase A only (TerrainWorker.compute_chunk_data: PNG read, height decode, mesh arrays). No texture loading in worker.
- **Blocking operations:** `WorkerThreadPool.wait_for_task_completion(tid)` when draining completed async (chunk_manager.gd 483, 591); then Phase B runs. Texture loading (file I/O + decode) is on main thread inside Phase B.

**Frame budget:** Target 60 FPS (IDEAL_FPS 60), 8 ms streaming budget, 16 ms initial-load budget. Phase B does up to several steps per frame until budget consumed.

**GPU compute timing expectations:**

- **Single chunk generation:** 512×512 = 262k pixels; rough estimate 1–10 ms on modern GPU (depends on cell count and memory bandwidth). Should fit in 8 ms if kept under ~5 ms.
- **Batch (e.g. all Europe):** 15,019 chunks → if 5 ms per chunk, ~75 s; if 50 ms per chunk, ~12.5 min. Acceptable for offline/batch; for runtime, only one (or few) chunks per frame.
- **Threading:** RenderingDevice is main-thread. So: dispatch compute on main, then either (1) sync wait and create texture same frame, or (2) defer completion check to next frame and create texture when ready (may need placeholder).

---

## 7. Hex Geometry & Constants

**Constant definitions:**

| Constant           | Value    | Location (file, line)        |
|--------------------|----------|-----------------------------|
| HEX_SIZE_M         | 1000.0   | config/constants.gd:61      |
| HEX_WIDTH_M        | 1000.0   | config/constants.gd:62      |
| HEX_HEIGHT_M       | 866.025  | config/constants.gd:63      |
| HEX_RADIUS_M       | ~577.35  | config/constants.gd:66 (HEX_SIZE_M / sqrt(3)) |
| CHUNK_SIZE_PX      | 512      | config/constants.gd:18      |
| CHUNK_SIZE_M       | 46080.0  | config/constants.gd:19 (512*90) |
| LOD_RESOLUTIONS_M  | [90,180,360,720,1440] | config/constants.gd:27–33 |
| resolution_m       | From terrain_metadata (e.g. 30 or 90) | terrain_loader.gd |

**Hex SDF formula (Python)** — `tools/generate_cell_textures.py`:

```python
HEX_SDF_K = math.sqrt(3.0) / 2.0  # ~0.866025404

def hex_sdf_pointy_top(point: Tuple[float, float], center: Tuple[float, float], radius: float) -> float:
    """Signed distance to pointy-top hex boundary. Vertex on Z axis, flat edge on X."""
    px = abs(point[0] - center[0])
    pz = abs(point[1] - center[1])
    d1 = HEX_SDF_K * px + 0.5 * pz - radius
    d2 = pz - radius
    return max(d1, d2)
```

Vectorized version uses same d1/d2 with numpy. Distance field stores **unsigned** distance (abs(sdf)), normalized by `DISTANCE_NORMALIZE_M = 500.0`, then `min(dist/500, 1.0)` and encoded as 0–255.

**Shader equivalent:** Not present in terrain.gdshader (terrain uses sampled distance texture). Hex overlay compositor uses different hex math (world_to_axial, axial_round, hex_dist) for grid drawing; for GPU distance-field compute we should port the Python pointy-top SDF exactly.

**Chunk origin calculation:**

- **GDScript** (terrain_loader.gd:281–293):  
  `lod_scale = 2^lod`, `world_chunk_size = chunk_size_px * resolution_m * lod_scale`,  
  `position = (chunk_x * world_chunk_size, 0, chunk_y * world_chunk_size)` (NW corner).
- **Python** (generate_cell_textures.py:94–99):  
  `chunk_size_m = 512 * resolution_m * (2 ** lod)`, `origin_x = chunk_x * chunk_size_m`, `origin_z = chunk_y * chunk_size_m`.
- **World position of pixel (Python, lines 443–445):**  
  `world_x = origin_x + (ii / (width - 1)) * chunk_size_m`, `world_z = origin_z + (jj / (height - 1)) * chunk_size_m` (pixel (0,0) = NW, (511,511) = SE). Same convention must be used in GPU compute (UV or pixel_id → world XZ).

---

## 8. Missing Pieces & Unknowns

- **RenderingDevice texture → Texture2D:** No existing code path that creates a high-level Texture2D from an RD texture or RD buffer. Need to confirm API: e.g. read back to PackedByteArray then `Image.create_from_data(512, 512, false, Image.FORMAT_L8, data)` and `ImageTexture.create_from_image(img)`.
- **CompositorEffect vs standalone compute:** Hex overlay runs inside compositor (has RenderData). Distance-field compute would run outside compositor (no RenderData). So we need a standalone RD pipeline: create output storage image, create buffer for params/cell data, dispatch, then read back. No existing “standalone” compute in the project.
- **Cell list per chunk on GPU:** How to get the set of (cell_id, center_x, center_z) for a chunk: (1) from cell_metadata filtered by chunk AABB, or (2) load chunk cell texture on CPU, decode unique IDs, look up centers, upload. (2) matches Python and reuses existing cell texture; (1) needs chunk AABB in world and metadata iteration. Per-chunk cell texture is already loaded for rendering; using it to drive GPU input is consistent.
- **LOD 3+:** Distance textures are only for LOD 0–2. No change needed for LOD 3+ (they don’t get distance texture).

**Potential blockers:**

- Godot 4 RenderingDevice readback cost (sync) could add 1–2 ms per chunk; need to measure.
- Very large cell count per chunk (e.g. dense urban) might require larger SSBO or multiple dispatches; worth a sanity check on max cells per chunk.

---

## 9. Integration Strategy Recommendation

**Recommended approach: Option A — generate in TerrainLoader when loading distance texture.**

- **Reason 1:** Fits existing flow: `_load_distance_field_texture` already is the single call site; we can “if file exists load else generate (GPU) and cache.”
- **Reason 2:** Keeps cache and format in one place; ChunkManager and shader unchanged.
- **Reason 3:** Reuses existing compute patterns (GLSL, RD, pipeline) and constants; only new piece is the distance-field compute shader and a small “runner” that fills params, uploads cell data, dispatches, readback, Image → ImageTexture.

**Fallback:** If single-chunk GPU time exceeds frame budget: (1) generate with lower resolution (e.g. 256×256) and upscale, or (2) queue chunk for generation and use default/white texture until ready, then swap next frame.

**Risks:**

- Readback stalls GPU pipeline if done synchronously every chunk.
- Europe-scale metadata not loaded in engine when file > 400 MB; for “generate at runtime” we must either restrict to regions that have metadata loaded or provide a per-chunk cell list from another source (e.g. precomputed per-chunk JSON).

---

## 10. Next Steps for Architect

**Questions:**

- Prefer “generate only when file missing” vs “always generate on GPU” (e.g. for iteration)? If always GPU, we can skip loading PNGs for distance.
- For Europe (metadata not loaded): allow GPU distance generation at all? If yes, need a per-chunk cell-center source (e.g. preprocessed binary or chunk-specific small JSON).
- Acceptable to block Phase B step for ~2–5 ms for one chunk’s GPU generation + readback, or must we design for fully deferred (placeholder + swap later)?

**Ready for implementation plan:** Yes, with the above clarifications. No critical blocker found; Godot 4.5 + Vulkan + existing compute pattern support the feature.
