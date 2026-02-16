# Hex Grid Decal Experiment – Findings Report

**Date:** February 15, 2026  
**Context:** Refactor from world-space line mesh (HexGridMesh) to Decal-based grid rendering, due to line mesh being invisible except for a 1-frame flash on F1.

---

## What We Did

1. **Replaced MeshInstance3D line mesh with a Decal**
   - Decal projects a texture onto terrain from above (5 km height, 20 km × 20 km footprint).
   - Godot decals project along **local -Y**; we kept **rotation = 0** so the texture projects straight down (rotation caused one axis to collapse to a line).
   - Size: `Vector3(20000, 10000, 20000)` — XZ = footprint, Y = projection depth.

2. **Centered decal on look-at target, not camera position**
   - Grid stays under the view when orbiting; panning (WASD) still moves the decal with the target.

3. **Replaced test cross with procedural hex grid texture**
   - Same hex math as the rest of the engine (`_axial_to_world`, `_hex_corners_local`).
   - 1024×1024 texture, world range -10 km to +10 km in X and Z, drawn once at init.

4. **Kept compositor grid off when decal is used**
   - Avoids F1 causing a 1-frame flash of the screen-space compositor grid.

5. **Documented decal setup**
   - Comment block in `hex_grid_mesh.gd`: do not rotate decal; XZ = footprint, Y = depth. Constant `DECAL_WORLD_SIZE` for single source of truth.

---

## What Works

- **White cross (test pattern)** and **hex grid texture** are visible: a square of hex grid appears and is readable.
- **Hex selection (HexSelector)** works and has the **correct hex shape** — the physical lifted hex slice matches the intended hex geometry and follows terrain (contoured walls, correct outline).
- **F1** toggles grid visibility; decal no longer disappears randomly when we sync visibility every frame and avoid one-time-only sync.
- **Decal does not rotate with camera** when rotation is kept at zero and position is driven by `target_position.xz`.

---

## Foundational Problem

**The hex grid (decal) and the selected hex (HexSelector) feel completely disconnected from the terrain and from each other.**

| Aspect | Observation |
|--------|-------------|
| **Grid vs terrain** | The grid is a flat texture projected onto the terrain. It does not follow elevation or slope; it reads as a flat square overlay, not "painted on" the hills and valleys. |
| **Grid vs selection** | The selected hex has the correct shape and is terrain-aware (lifted slice with contoured walls). The decal grid is a separate square that does not align with that same geometry in a visually coherent way — different coordinate system, no shared "lift" or rim, no sense that the selection is "on" the grid. |
| **Square following camera** | The 20 km × 20 km square moves with the look-at target. That keeps it under the view but reinforces the feeling of a floating overlay rather than a world-anchored grid. |
| **Smoothness** | The result does not feel smooth or integrated: grid, selection, and terrain feel like three separate layers. |

So the issue is not only "one bug" but that **the decal approach itself does not produce a unified, terrain-integrated hex experience**. The selection system (HexSelector) is terrain-aware and correct; the grid (decal) is flat and world-aligned in a way that does not match that.

---

## Recommendations for Next Steps

1. **Treat decal grid as a stopgap, not the final solution**
   - Keep it for "grid visible and togglable" but plan for a grid that is **terrain-aware** (e.g. lines at terrain height, or screen-space with stable world alignment).

2. **Revisit screen-space compositor**
   - The compositor was disabled in favor of the decal because of issues (grid sliding, visibility). If those can be fixed (e.g. camera-relative coordinates for precision, consistent visibility), a **single** screen-space grid that shares the same world hex math as selection might give a more coherent look.

3. **Unify grid and selection visually**
   - Whatever replaces or complements the decal should feel like the same "layer" as the selected hex: same hex size, same alignment, and ideally shared logic (e.g. one world hex → one grid cell and one selection shape).

4. **Preserve what we learned**
   - Do not rotate the decal (rotation breaks one axis).
   - Use `target_position` (look-at) for grid center when using a world-space overlay.
   - Keep `DECAL_WORLD_SIZE` and the comment block in `hex_grid_mesh.gd` so future changes don't reintroduce the "single line" or "grid moving with camera" regressions.

---

## Files Touched This Session

- **`rendering/hex_grid_mesh.gd`** — Decal setup, hex grid texture, `_draw_line`, `DECAL_WORLD_SIZE`, orientation comments.
- **`rendering/basic_camera.gd`** — Grid center from `target_position`; compositor `show_grid = false` when decal used; F1 handling; visibility sync every frame.

No changes to `core/hex_selector.gd`, `rendering/hex_overlay_compositor.gd`, or `hex_overlay_screen.glsl` in this session (per "no changes needed" / "reference only").
