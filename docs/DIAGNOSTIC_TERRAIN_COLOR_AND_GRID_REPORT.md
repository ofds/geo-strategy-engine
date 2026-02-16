# Diagnostic Investigation — Terrain Color & Grid Visibility

**Purpose:** Identify why terrain appears all white/snow and why grid lines never appear (Phase 1B texelFetch fix is in place; selection alignment works).

**How to run:** With the game running (F5), use the camera debug keys (only one diagnostic is active at a time):
- **F10** — Toggle **elevation debug** (Part 1): terrain shows grayscale by height (0–5000 m) + red bands every 1000 m. Console: `[Camera] Elevation debug: ON/OFF`.
- **F11** — Toggle **cell texture debug** (Part 2): chunks show RED if texture missing, or colored patches if bound. Console: `[Camera] Cell texture debug: ON/OFF`.

Press F10 or F11 again to turn that diagnostic off. Then fill this report.

---

## Report Template — Paste Back Results

**Diagnostic Results:**

### Part 1: Terrain Color

**Elevation Debug Visualization:**
- Terrain appearance: [ dark-to-light gradient | all white | all black | solid gray ]
- Red bands visible: [ YES / NO ]
- Screenshot: [ attach ]

**Terrain Metadata (`data/terrain/terrain_metadata.json`):**
- max_elevation_m: [ value ]
- min_elevation_m: [ value if present ]
- resolution_m: [ value ]
- region_name: [ value ]

**Elevation Palette:**
- File exists: [ YES / NO ] at path `res://data/terrain/elevation_palette.png`
- File appearance: [ describe or attach screenshot ]
- Dimensions: [ width × height ]

**Shader Uniform Loading (reference):**
- elevation_palette set in: `core/terrain_loader.gd`, in shader setup (around line 75): `shader_material.set_shader_parameter("elevation_palette", palette_tex)`
- max_elevation_m set in: same file, line 76: `shader_material.set_shader_parameter("max_elevation_m", terrain_metadata.get("max_elevation_m", max_elevation_m))`
- Console warnings: [ paste any related warnings ]

**Diagnosis (Part 1):**
- [ ] max_elevation_m is incorrect (too low/high)
- [ ] elevation_palette.png missing or wrong
- [ ] Height data not loading (all same elevation)
- [ ] Other: [ describe ]

---

### Part 2: Grid Visibility

**Cell Texture Debug Visualization:**
- Chunk colors: [ RED (not bound) | solid one color (bound, no variation) | Colored patches (working) ]
- Screenshot: [ attach ]

**Cell Texture Files:**
- Directory exists: [ YES / NO ] at `data/terrain/cells/lod0/` (and lod1, lod2)
- Number of files in lod0: [ count ]
- Sample file checked: [ e.g. chunk_0_0_cells.png ]
- Sample appearance: [ describe or screenshot ]
- Sample dimensions: [ width × height ]

**Cell Texture Loading Code (reference):**
- Loading function: `_load_cell_texture(chunk_x, chunk_y, lod)` in `core/terrain_loader.gd`, lines 225–243
- Path used: `res://data/terrain/cells/lod{L}/chunk_{x}_{y}_cells.png`
- Called from: chunk build (lines 176, 186) and reload (975, 986)
- Console warnings: [ paste any "Cell texture not found or failed to load" or similar ]

**Material Assignment (reference):**
- Per-chunk materials: YES — `shared_terrain_material.duplicate()` (or lod2plus) when `cell_tex` is non-null; `mesh_instance.set_surface_override_material(0, mat)` (lines 179–180, 186–187; 978–979, 985–986)
- cell_id_texture set: `mat.set_shader_parameter("cell_id_texture", cell_tex)` in same blocks
- When cell_tex is null: chunk uses shared material (no override), so no per-chunk texture → shader sees default 1×1 → grid skipped

**Diagnosis (Part 2):**
- [ ] Cell textures not loading (files missing or path wrong)
- [ ] Textures loading but not bound to materials
- [ ] Materials are shared (not per-chunk) so textures don’t apply
- [ ] Textures bound but all one cell ID (generation issue)
- [ ] Other: [ describe ]

---

### Console Output
[ Paste any warnings or errors related to textures, materials, or shaders ]

---

### Recommended Fixes
[ Based on findings ]

**For terrain color:**
- [ ] Update max_elevation_m in terrain_metadata.json to [ value ]
- [ ] Add/fix elevation_palette.png at `res://data/terrain/elevation_palette.png`
- [ ] Fix height data loading in [ code location ]

**For grid visibility:**
- [ ] Fix cell texture file paths or ensure files exist under `data/terrain/cells/lod0/`, `lod1/`, `lod2/`
- [ ] Verify per-chunk material duplication and `cell_id_texture` set (see references above)
- [ ] Regenerate cell textures if corrupted

---

## Code Reference Summary

| What | Where |
|------|--------|
| elevation_palette uniform | terrain_loader.gd ~75 |
| max_elevation_m uniform | terrain_loader.gd ~76, 288 |
| _load_cell_texture() | terrain_loader.gd 225–243 |
| Cell texture path | res://data/terrain/cells/lod{L}/chunk_{x}_{y}_cells.png |
| Per-chunk material + cell_id_texture | terrain_loader.gd 176–187, 975–986 |
| Diagnostic uniforms | terrain.gdshader: debug_show_elevation, debug_show_cell_texture |

**Note:** Remove the two debug blocks and the two diagnostic uniforms from `rendering/terrain.gdshader` after the investigation is complete.

---

## User findings (elevation + cell texture)

**Elevation debug (F10) – sea vs land**
- Normal mode: blue sea, clear coast transition with Europe.
- With elevation debug on: where the sea is (blue when off), the terrain turns **red** in the debug view.
- The **extent** of what looks like “water” in the elevation debug (dark + red) is **larger** than the blue sea in normal mode — i.e. “sea level” appears higher in the debug view.

**Interpretation:** In the elevation debug, **red** = 1000 m elevation bands (0 m, 1000 m, 2000 m, …). The sea is at ~0 m, so it falls in the **0 m band** and shows as red. So “blue → red” is expected. The fact that the low-elevation (dark + red) area is **larger** in debug than the blue sea in normal mode is because:
- **Normal mode** only paints **water** where `v_elevation < 5` m (constant `WATER_ELEVATION_M` in the shader).
- **Elevation debug** shows **raw elevation**: everything from 0 m up to 5000 m is grayscale, with red at 0, 1000, 2000, … So low coastal land (e.g. 0–50 m) is also dark and can sit in or near the 0 m red band, so it looks like “water” in the debug even though in normal mode it’s land (above 5 m). So the debug is showing that **a lot of near-sea-level terrain** (0–~100 m) exists; the normal shader only treats **&lt; 5 m** as blue water. No bug implied — just different definitions (5 m water threshold vs raw elevation bands).

**Cell texture debug (F11) – many red chunks**
- **Lots of red chunks**, often **connected** (large red regions).
- Some areas show **colored (rainbow-ish) patches**; those are chunks where the cell texture is loaded.

**Interpretation:** **Red** = no valid cell texture (missing file or default 1×1). So for many chunks the loader is **not** getting a cell texture (e.g. `_load_cell_texture` returns `null`), so those chunks use the shared material and the shader sees the default sampler → grid is skipped. **Colored patches** = cell texture present and varied cell IDs. So:
- **Cause:** Cell texture files are **missing** (or path wrong) for a large part of the chunk set. The pipeline may only generate cell PNGs for a subset of chunks/LODs (e.g. only some lod0/lod1/lod2 chunks).
- **Effect:** Grid lines will only appear on chunks that have `res://data/terrain/cells/lod{N}/chunk_{x}_{y}_cells.png` and load successfully; the rest stay red in F11 and show no grid.

**Recommended next steps**
1. **Elevation:** No change required unless you want the 5 m water threshold to match a different sea level; the mismatch is from definition (5 m water vs elevation bands).
2. **Grid:** Generate or add cell textures for all chunks (or the visible LOD range) so that `chunk_{x}_{y}_cells.png` exists under `data/terrain/cells/lod0/`, `lod1/`, `lod2/` for the chunk coordinates that are actually loaded. Then red areas in F11 should turn into colored patches and the grid can draw there.
