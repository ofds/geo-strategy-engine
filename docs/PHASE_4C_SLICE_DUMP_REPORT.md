# Phase 4c: Slice Mesh Deep Diagnostic

## Purpose

Instrument the slice builder to dump actual geometry when a hex is selected. Compare those numbers against what the grid expects to find the mismatch (wrong shape or misalignment).

---

## How to collect data

1. Launch the project, zoom to LOD 0 where the grid is visible.
2. Click to select a hex.
3. Copy all `[SLICE-DUMP]` lines from the Godot console.
4. Paste them into the sections below (and optionally attach a screenshot showing the slice and surrounding grid).

---

## Phase 4c: Slice Geometry Dump

### Selection center

```
[SLICE-DUMP] Selected hex center (world XZ): (3077854.250, 1944000.000)
[SLICE-DUMP] Hex radius used: 577.350
```
(Second selection: center (3076122.250, 1944000.000), same radius.)

### Hex corners (actual vs expected)

Actual = from `_hex_corners_local(radius)`. Expected = terrain shader math (pointy-top, radius = HEX_RADIUS_M ≈ 577.35).

```
[SLICE-DUMP] Corner 0 (local): (0.000, 577.350) -> (world): (3077854.250, 1944577.350)  expected_local: (0.000, 577.350)
[SLICE-DUMP] Corner 1 (local): (-500.000, 288.675) -> (world): (3077354.250, 1944288.675)  expected_local: (-500.000, 288.675)
[SLICE-DUMP] Corner 2 (local): (-500.000, -288.675) -> (world): (3077354.250, 1943711.325)  expected_local: (-500.000, -288.675)
[SLICE-DUMP] Corner 3 (local): (0.000, -577.350) -> (world): (3077854.250, 1943422.650)  expected_local: (0.000, -577.350)
[SLICE-DUMP] Corner 4 (local): (500.000, -288.675) -> (world): (3078354.250, 1943711.325)  expected_local: (500.000, -288.675)
[SLICE-DUMP] Corner 5 (local): (500.000, 288.675) -> (world): (3078354.250, 1944288.675)  expected_local: (500.000, 288.675)
```

**Side-by-side check:** Yes — actual local corners are identical to expected (0, R), (-c, s), (-c, -s), (0, -R), (c, -s), (c, s).

### Boundary vertices

```
[SLICE-DUMP] Boundary vertex count: 144
[SLICE-DUMP] Boundary[0]: Vector3(0.000, 82.173, 577.350)
[SLICE-DUMP] Boundary[1]: Vector3(-20.833, 82.535, 565.322)
[SLICE-DUMP] Boundary[2]: Vector3(-41.667, 82.732, 553.294)
[SLICE-DUMP] Boundary[3]: Vector3(-62.500, 82.637, 541.266)
[SLICE-DUMP] Boundary[4]: Vector3(-83.333, 82.484, 529.238)
[SLICE-DUMP] ... (omitted 134) ...
[SLICE-DUMP] Boundary[139]: Vector3(104.167, 83.535, 517.210)
[SLICE-DUMP] Boundary[140]: Vector3(83.333, 82.606, 529.238)
[SLICE-DUMP] Boundary[141]: Vector3(62.500, 81.968, 541.266)
[SLICE-DUMP] Boundary[142]: Vector3(41.667, 81.986, 553.294)
[SLICE-DUMP] Boundary[143]: Vector3(20.833, 82.077, 565.322)
```

### Grid clipping samples

```
[SLICE-DUMP] Grid row z=-502.4: intersection_x range = [-484.8, 484.8] (expected for hex: [-484.8, 484.8])
[SLICE-DUMP] Grid point (lx, lz) = (47.6, -502.4): is_inside = true
[SLICE-DUMP] Grid row z=-2.4: intersection_x range = [-500.0, 500.0] (expected for hex: [-500.0, 500.0])
[SLICE-DUMP] Grid point (lx, lz) = (47.6, -2.4): is_inside = true
[SLICE-DUMP] Grid row z=497.6: intersection_x range = [-500.0, 500.0] (expected for hex: [-500.0, 500.0])
[SLICE-DUMP] Grid point (lx, lz) = (47.6, 497.6): is_inside = true
```

### Mesh stats

```
[SLICE-DUMP] Total top vertices: 455
[SLICE-DUMP] Total wall vertices: 576
[SLICE-DUMP] Mesh bounding box: min(-502.350, -39.835, -577.350) to max(547.650, 92.360, 577.350)
[SLICE-DUMP] Slice node position (world offset): (3077854.250, 0.000, 1944000.000)
```

### Analysis

1. **Are the corners correct?** Yes. `_hex_corners_local` matches the expected pointy-top corners exactly.

2. **Is the center correct?** Yes (selection center is used consistently; no offset issue).

3. **Is the bounding box hex-shaped or rectangular?** **Wrong.** For a pointy-top hex, X extent at z=0 should be ±apothem (±500 m) and at z=±577 m should be 0. The dump shows **max.x = 547.65** (and min.x = -502.35). So the mesh extended ~47 m too far right (and ~2 m too far left). That is not rectangular (Z extent is correct ±577.35), but the X extent was too wide — i.e. **clipping was too loose**: some grid points with x > 500 were considered inside.

4. **Do the grid clipping results make sense?** Row intersection ranges and expected ranges match. The bug was not in `_hex_row_intersection_x` but in **which points** were considered inside: `_is_inside_hex` used an SDF with **radius** (`max(dot(p,(√3/2, 1/2)), p.y) - radius <= 0`). That shape has horizontal extent at z=0 where `0.866*x = radius` → x ≈ 666 m, so it includes points out to ~667 m. The true pointy-top hex has flat edges at x = ±apothem = ±500 m. So grid points with x_center = 547.65 (e.g. column index 22) were incorrectly marked inside and added with x_snap = x_center, producing max.x = 547.65.

### Fix applied

**`_is_inside_hex`** was changed to use the **same boundary as `_hex_row_intersection_x`** instead of the SDF with radius. So “inside” is now: get the row intersection for this z; return true iff `lx` is between `row[0]` and `row[1]`. That makes the inside test exactly match the clipping (apothem and slanted caps). After the fix, the mesh bounding box should have X in [-500, 500] and Z in [-577.35, 577.35], i.e. a proper pointy-top hex outline.

---

## Implementation notes

- Dump runs **once per selection** in `_build_slice_mesh()` (called from `set_selected_hex()`).
- Expected corners use the same formula as the terrain shader: pointy-top, radius = `Constants.HEX_RADIUS_M` (577.35 m), c = R×0.8660254, s = R×0.5.
- Slice mesh is built in **local space** (center at origin); the MeshInstance3D node is positioned at `(_center_x, 0, _center_z)` so world position = node position + vertex.
