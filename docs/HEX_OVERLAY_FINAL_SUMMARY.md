# Screen-Space Hex Overlay – Final Summary

**Date:** February 15, 2026  
**Scope:** Compositor-based hex grid (`hex_overlay_compositor.gd` + `hex_overlay_screen.glsl`).

---

## Desired Behavior

- **Terrain should feel selectable:** Panning the camera should not move the hex grid; the grid should be fixed to the world so it feels like the terrain itself is covered by an infinite hex grid.
- **Close to the ground:** When near the terrain, a large, continuous grid of hexes should be visible.
- **Borders:** Hex borders should look good – not too bold (addressed by reducing line/rim width in the shader).

---

## What Works

- **Selection and hover:** Work correctly and feel world-locked. They use **physics raycast** in `basic_camera.gd`: `intersect_ray()` → world hit position → axial round → hex center in **world space** → passed to compositor. The compositor draws the selection rim and hover highlight using these world-space centers; that logic is sound.
- **Depth in R channel:** With F4 debug, the top-left quadrant (R channel) shows valid depth when zoomed in; depth is present and in the red channel.
- **Rotation:** When rotating the camera, the grid can appear to stay fixed (behavior varies by setup), which suggests the problem is specific to **panning** and/or how world position is derived from depth.

---

## What Still Fails

- **Grid moves with camera on pan:** When the camera is panned, the hex grid (or a “hex square” under the camera) moves with the view instead of staying on the terrain. So the grid does not behave like an infinite, world-locked overlay.
- **Small square of hexes:** The grid often appears only in a limited region (e.g. a square under the camera) instead of across the full visible terrain.

Together, this suggests the **reconstructed world position from the depth buffer** is wrong or inconsistent: either we are not getting the correct depth for the main scene, or the unprojection (clip → view → world) does not match the renderer, so the grid is effectively in view/camera space instead of world space.

---

## What Was Tried (This Session)

1. **Reverse-Z unproject:** NDC z from `depth*2-1`, perspective divide, single `inv_view_projection` → world.
2. **Camera-relative XZ** for hex math to avoid precision loss at 2M+ m.
3. **Two-step unproject:** Separate `inv_projection` (clip → view) and `inv_view` (view → world) with matrices from `view_proj * Projection(cam_transform)` and `cam_transform`.
4. **Depth source:** Raw vs resolved depth (F6), debug views (F4: quadrants R/G/B/A, power curve for depth).
5. **Far depth:** Accept depth &gt; 1e-6 so far terrain still gets grid; no change to the “moves with camera” behavior.
6. **Borders:** `LINE_WIDTH` reduced from 30 → 12; selection rim from 30 → 18 (× border_scale) for subtler lines.

None of the unproject/matrix changes fixed the panning behavior; the grid still moves with the camera.

---

## Insight from Selection Logic

**Selection/hover are world-correct because they never use the depth buffer.** They use:

- **Physics raycast** from the camera through the mouse into the world.
- **World hit position** from the physics engine.
- **Same axial/hex math** (axial round, hex center in world XZ) as the compositor.

So the “infinite, world-locked grid” behavior you want is already achieved for **which hex is under the cursor** and **which hex is selected**. The missing piece is making the **drawn grid** use the same notion of world space.

**Implication:** Consider approaches that do **not** depend on reconstructing world position from the compositor’s depth buffer, for example:

- **World-space grid:** Draw the grid in world space (e.g. `HexGridMesh` / decal or a large mesh aligned to world XZ) so it is inherently locked to the terrain, like the raycast. Use the compositor only for hover/selection overlay (which already get correct world positions from the camera).
- **Or:** If keeping a full screen-space grid, find a way to get **the same depth the main view uses** (correct buffer, correct pass, correct view index) and confirm the compositor’s projection/view matrices match the renderer’s exactly (e.g. same API and frame as the depth write).

---

## File References

| Item | Location |
|------|----------|
| Compositor + shader | `rendering/hex_overlay_compositor.gd`, `rendering/hex_overlay_screen.glsl` |
| Selection/hover (world-space) | `rendering/basic_camera.gd` (raycast ~L541–571), `core/hex_selector.gd` |
| Grid line width / rim | `hex_overlay_screen.glsl`: `LINE_WIDTH`, selection `rim_width` |
| Debug keys | F4 = depth view, F6 = raw vs resolved depth |

---

## Recommended Next Steps

1. **Validate depth source:** Confirm which buffer the compositor reads (e.g. one-time print of depth RID and pass name) and whether it is the same buffer the opaque scene writes to for the main view.
2. **Compare with world-space grid:** If `HexGridMesh` (or similar) is used when available, compare behavior: if that grid stays fixed on pan while the compositor grid does not, that supports moving the “infinite grid” drawing to world space and using the compositor mainly for selection/hover.
3. **Thinner borders:** The reduced `LINE_WIDTH` and rim width are in place; tweak further in `hex_overlay_screen.glsl` if needed.

This summary can be used to hand off the screen-space hex overlay work and to prioritize either fixing depth/unproject in the compositor or shifting the grid to a world-space solution aligned with the selection logic.
