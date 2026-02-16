# Hex Grid Diagnostic Results

## Test 1 (inside mask)
**Result:** No visible change. Terrain looks normal; no red hex cells. If the test were running, we would see red where `inside == 1` and normal terrain where `inside == 0`.

## Test 2 (edge distance)
**Result:** No visible change. Terrain looks normal; no grayscale hex pattern (bright at edges, dark at centers).

## Test 3 (line mask)
**Result:** No visible change. Terrain looks normal; no white lines on black.

## Test 4 (fwidth)
**Result:** No visible change. Terrain looks normal; no dark/bright fwidth visualization.

## Test 5 (hex_size)
**Result:** No visible change. Terrain looks normal; no red tint (~0.577 brightness) from the hex_size uniform.

## Conclusion

**None of the five diagnostic tests produced any visible change.** The hex grid never appears before or after toggling it on (F1).

This means the **hex grid branch of the fragment shader is not affecting the final image**. The most likely causes are:

1. **`show_hex_grid` is always false at runtime**  
   The F1 toggle may not be updating the terrain material's `show_hex_grid` uniform, or the script may be setting it on a different material than the one used by the terrain mesh.

2. **Terrain is not using this shader**  
   The mesh you're looking at might use a different material/shader (e.g. a duplicate or a different terrain node), so changes in `terrain.gdshader` never show up.

3. **Wrong material reference**  
   The camera (or whatever script owns the F1 toggle) might be getting a different `ShaderMaterial` / `Material` than the one assigned to the visible terrain surface.

**Next step:** Verify in code where `show_hex_grid` is set and which material it's applied to; confirm that the same material is the one on the terrain mesh that's visible in the viewport. Once the hex branch is confirmed to run (e.g. Test 1 or 5 shows a visible change), re-run the diagnostics to isolate any remaining line-mask or scale issues.

---

## Phase 2c: Material Pipeline Trace Results

**Run order:** Run the project, wait for terrain to load, check if terrain is red. Toggle F1 and check console. Paste logs below.

### Visual test (Investigation 3)
[ x ] **Is the terrain red?** NO  
*(Unconditional red tint is in terrain.gdshader before the if (show_hex_grid) block. Terrain did not appear red, so the visible terrain is not using this shader — or what we see is not the chunk meshes.)*

### Material trace logs (Investigation 1)
*(Representative [MAT-TRACE] lines from run.)*

```
[MAT-TRACE] shared_terrain_material shader path: res://rendering/terrain.gdshader
[MAT-TRACE] shared_terrain_material instance ID: -9223371999307364975
[MAT-TRACE] shared_terrain_material_lod2plus shader: res://rendering/terrain.gdshader
[MAT-TRACE] Chunk material shader: res://rendering/terrain.gdshader
[MAT-TRACE] Chunk material ID: -9223371998820825683   (LOD 2+ chunks)
[MAT-TRACE] Chunk material ID: -9223371999307364975  (LOD 0–1 chunks)
[MAT-TRACE] Chunk surface material: <Object#null>   (mesh has no built-in surface mat; override is used)
```
*All chunks use terrain.gdshader. LOD 0–1 use material -9223371999307364975; LOD 2+ use -9223371998820825683.*

### Hex grid trace logs (Investigation 2)
*(Representative [HEX-TRACE] lines.)*

```
[HEX-TRACE] Camera terrain_material: <ShaderMaterial#-9223371999307364975> shader: res://rendering/terrain.gdshader
[HEX-TRACE] Setting show_hex_grid = true on material ID: -9223371999307364975
[HEX-TRACE] Setting show_hex_grid = true on material ID: -9223371998820825683
[HEX-TRACE] F1 pressed. _grid_visible is now: false
[HEX-TRACE] F1 pressed. _grid_visible is now: true
[HEX-TRACE] Setting show_hex_grid = false on material ID: -9223371999307364975
[HEX-TRACE] Setting show_hex_grid = false on material ID: -9223371998820825683
```

### F1 toggle
- **Does F1 produce a log line?** YES  
- **What does _grid_visible show when you toggle?** true and false (toggles correctly).

### Conclusion
**d) Something else**

- **Pipeline is correct:** Camera gets the same shader and material (ID -9223371999307364975) as LOD 0–1 chunks; both shared materials (LOD 0–1 and LOD 2+) are updated with `show_hex_grid` every frame; F1 toggles the uniform on both materials. Chunks all use `terrain.gdshader` and the expected material IDs.
- **No red tint** means the **visible “terrain” on screen is not drawn by the chunk shader.** At startup the camera is at **150 km** and the initial load had **L0=0** (no LOD 0 chunks). The **overview plane** (ChunkManager, Y=-20, full region) is added first and uses a **StandardMaterial3D** with the overview texture — it does **not** use `terrain.gdshader`. So at high altitude the ground you see is likely the **overview plane**, not the chunk meshes. The red tint and hex grid only affect chunk meshes; they never affect the overview quad.
- **Fix direction:** Either (1) use the terrain shader (or a compatible pass) for the overview plane so the same uniforms/hex logic apply, or (2) ensure chunk meshes are what the camera sees when testing (e.g. zoom in until LOD 0 chunks load and the overview is not dominant), or (3) change draw order / visibility so that at high altitude the chunks using the terrain shader are the visible surface.

---

## Phase 2d: LOD 0 hex diagnostic tests (re-run)

**Context:** The unconditional red tint is visible when zoomed in at LOD 0, so the terrain shader **is** active on the visible chunk meshes.

**Result:** When zoomed in so that LOD 0 terrain is visible (red tint clearly on the ground), **the hex grid never appears**. This holds for:
- All five diagnostic tests (hex_test 1 through 5): no red hex cells, no grayscale gradient, no white lines, no fwidth pattern, no solid ~0.577 red.
- F1 toggle (grid on/off): no visible change; no hex grid at any zoom level where the red tint is visible.

So the **hex branch** (`if (show_hex_grid)` and the test 1–5 visuals) is either **not running** (e.g. `show_hex_grid` is false in the shader at runtime despite camera setting it), or it runs but the **hex math / scale produces nothing visible** (e.g. wrong `hex_size`, wrong world units, or output overwritten/hidden). Next step: confirm `show_hex_grid` value in-shader (e.g. force a visible override when `show_hex_grid` is true) or audit hex_size / world_to_axial scale so the grid can appear.

---
*Temporary instrumentation (prints in terrain_loader, chunk_manager, basic_camera, and red tint in terrain.gdshader) left in place for the fix phase.*
