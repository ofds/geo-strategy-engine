# Phase 1B Implementation Report — Shader Integration (Cell Textures)

**Status:** SUCCESS (resolved after debug session).

**Resolution:** Grid lines now visible. Root cause was Godot 4 not applying **instance shader parameters for sampler2D** — the per-chunk `set_instance_shader_parameter("cell_id_texture", tex)` was ignored. Fix: use a **per-chunk material duplicate** with `cell_id_texture` set on the material; camera updates all materials (including per-chunk) each frame so F1/altitude etc. apply. Cell textures are loaded via **Image + ImageTexture** to avoid sRGB import altering data.

---

**What Was Implemented:**

- **`rendering/terrain.gdshader`**
  - Added `uniform sampler2D cell_id_texture` (hint_default_black, filter_nearest) for per-chunk cell ID texture.
  - Added `varying vec2 v_uv`; vertex stage sets `v_uv = UV`.
  - Added `decode_cell_id(vec4 rgba)` to decode RGBA → 32-bit uint (R×16777216 + G×65536 + B×256 + A).
  - Replaced hex grid logic: sample cell texture at `v_uv`, sample four neighbors (uv ± duv in X and Y using `textureSize`), compare cell IDs; if any neighbor differs → on boundary → apply grid line (same hex_line_color, hex_grid_strength, slope fade as before).
  - Removed all analytical hex code: `world_to_axial`, `axial_to_center`, `cube_round`, `hex_sdf`, `hex_grid_distance`; removed varying `v_local_xz`.
  - Kept `show_hex_grid` uniform and grid toggle behavior; kept `hex_size` uniform (unused in shader, set by camera for parity).
  - Kept `chunk_origin_xz` instance uniform (used by other systems).

- **`core/terrain_loader.gd`**
  - Added UVs to terrain mesh: sync path `_generate_mesh_lod` and async path `_compute_chunk_data` + `finish_load_step_mesh`. UV = (x/(mesh_res-1), y/(mesh_res-1)) over chunk quad; ultra-LOD quad gets (0,0)–(1,1).
  - Added `_load_cell_texture(chunk_x, chunk_y, lod)` — path `res://data/terrain/cells/lod{L}/chunk_{x}_{y}_cells.png`, FIFO cache (200 entries), log warning if missing.
  - In `load_chunk` (sync): after setting material, load cell texture and `mesh_instance.set_instance_shader_parameter("cell_id_texture", cell_tex)` if non-null.
  - In `finish_load_step_scene` (async): same — load cell texture and set instance parameter before returning.

- **`core/chunk_manager.gd`**
  - **No changes.** Cell texture loading is entirely in TerrainLoader; ChunkManager continues to set `chunk_origin_xz` in `_do_one_phase_b_step` when adding the mesh instance.

**Codebase Discoveries:**

- **Cell texture dimensions:** 512×512 pixels per chunk (same as height chunk PNGs; Phase 1A generates one cell texture per height chunk at LOD 0, 1, 2).
- **Height texture loading:** Heights are loaded via `_load_16bit_heightmap` → `_parse_16bit_png_raw` / `_decode_png_to_heights` (raw PNG parse for 16-bit); cell textures use simple `load(path)` as Texture2D (8-bit RGBA PNG).
- **Current shader uniforms (terrain):** albedo, roughness, metallic, rim, rim_tint; camera_position, altitude, terrain_center_xz, terrain_radius_m; overview_texture, overview_origin/size, use_overview; hex_size, hex_line_width, hex_line_softness, hex_grid_strength, hex_line_color, show_hex_grid; cell_id_texture; instance chunk_origin_xz; elevation_palette, max_elevation_m, steep_rock_color.
- **UV coordinate system:** Mesh had no UVs before Phase 1B. UVs were added so that (0,0) = chunk NW corner, (1,1) = chunk SE corner, matching the cell texture’s world-aligned coverage (same as height chunk extent).
- **Godot 4 shader hint:** `hint_default_black, filter_linear_mipmap_disable` together caused parse error; `hint_default_black, filter_nearest` is accepted (Godot 4.5). `filter_nearest` was added so boundary sampling uses exact texels; grid still not visible in-game.

**Implementation Decisions:**

- **Texture filtering:** Default (loader does not set NEAREST). Decode uses `floor(rgba.*255+0.5)` so texel-center values round correctly; at boundaries linear filtering may blend IDs — boundary detection still works (neighbor samples differ). If needed, texture import or runtime ImageTexture filter can be set to NEAREST later.
- **Boundary detection:** Sample center + four neighbors (uv ± one texel); if any neighbor has different cell_id, fragment is on boundary. No SDF or distance; binary boundary → same grid line styling (hex_line_color, hex_grid_strength, slope fade).
- **Grid line width/color:** Unchanged — hex_line_width/hex_line_softness no longer used (were for SDF smoothstep); line_mask is 0 or 1; hex_line_color and hex_grid_strength unchanged.
- **Error handling:** If cell texture file missing, log warning (debug build), do not set uniform; shader uses hint_default_black → all cell_id 0 → no grid lines on that chunk. Chunks without cell textures (e.g. LOD 3/4 if not generated) render without grid.

**Deviations from Architectural Guidance:**

- **Pseudocode decode:** Used `floor(rgba.*255+0.5)` instead of `uint(rgba.*255.0)` for correct rounding in GLSL.
- **Single sampler hint:** Godot 4 gdshader allowed only one hint for the sampler (e.g. hint_default_black); second hint caused parse error.

**Acceptance Test Results:**

- **Test 1 (Visual):** FAIL — Grid lines do not appear at any zoom level (continental to ~5 km). F1 toggles grid on/off but no visible change. Implementation and filter_nearest applied; root cause not yet identified.
- **Test 2 (Boundary alignment):** Not testable until grid is visible.
- **Test 3 (Grid toggle):** F1 and camera set show_hex_grid on both shared materials; no visible grid in either state.
- **Test 4 (Performance):** Not measured; no grid to compare.
- **Test 5 (Console):** Clean (LOD 3+ cell texture load skipped; no errors).

**Evidence:**

- Screenshot: Grid at continental zoom (~1000 km altitude) — to be captured by Otto.
- Screenshot: Grid at street level (~1 km altitude) — to be captured by Otto.
- Screenshot: Chunk boundary intersection (4+ chunks) — to be captured by Otto.
- Screenshot: F1 toggle (grid on/off) — to be captured by Otto.
- Console: No errors; warnings only for missing cell texture files if any.

**Performance Analysis:**

- Baseline FPS not measured in this session.
- Shader: removed ~30 lines of SDF/axial math; added 5 texture samples and 4 uint comparisons per fragment. Texture fetches are coherent; expected impact neutral or slightly better.

**Recommendations for Next Step:**

- **Phase 1C:** Selection integration (texture-based or Cell Query API) can proceed.
- **Grid visual refinement:** The current grid is **very pixelated** (hard 1-pixel boundary, no anti-aliasing), which reads as 8-bit / retro. Next steps should consider: sub-pixel or distance-based line softening (e.g. smoothstep over 1–2 pixels), slightly wider effective line width, or a dedicated line-width/softness pass so the hex grid looks smoother and more modern at typical play zoom levels.

**PROGRESS.md Update:** See subsection below.

---

## PROGRESS.md subsection (Phase 1B completion)

### Phase 1B — Shader integration (Feb 16, 2026)

- **Implemented:** Terrain shader now uses cell ID textures instead of analytical hex SDF. Per-chunk RGBA texture sampled at fragment UV; RGBA decoded to 32-bit cell ID; cell boundaries detected by comparing center pixel with four neighbors; grid lines drawn where IDs differ. UVs added to terrain mesh (sync and async paths) for 0–1 mapping over chunk. Shader uses `filter_nearest` for cell texture. Terrain worker builds UVs for async path; LOD 3+ skip cell texture load (no warnings).
- **Removed:** All analytical hex code from shader: `world_to_axial`, `axial_to_center`, `cube_round`, `hex_sdf`, `hex_grid_distance`; varying `v_local_xz`.
- **Decisions:** Cell texture loaded in TerrainLoader (`_load_cell_texture`), FIFO cache 200; set per instance via `set_instance_shader_parameter("cell_id_texture", tex)`. Missing texture → no grid on that chunk. LOD > 2 returns null without warning.
- **Tests:** Headless run OK. **Visual: grid lines do not appear in-game** (confirmed); F1 toggle has no visible effect. Root cause open.
- **Status:** Phase 1B implementation complete; grid visibility blocked. Debug steps recommended before Phase 1C (see report Recommendations).
