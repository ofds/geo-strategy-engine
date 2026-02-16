# Hex Selection Visual Artifacts — Diagnostic Report

**Mission:** Gather structured information to diagnose root cause. No fixes applied.

---

## Step 1: Screen-Space Selection Shader

**File:** `rendering/hex_overlay_screen.glsl`

### CUTOUT CODE

The selection cutout and dark shadow are implemented as follows. The **inside_cutout** condition and the block that renders the dark overlay:

```glsl
// Lines 111-119: cutout region and distance
float hex_radius = params.hex_size * 0.5;
float hex_radius_cutout = hex_radius + CUTOUT_MARGIN_M;
vec2 d_sel = abs(world_xz - params.selected_hex_center);
float d1_sel = d_sel.y;
float d2_sel = abs(dot(d_sel, vec2(SQRT_3/2.0, 0.5)));
float dist_from_sel_center = max(d1_sel, d2_sel);
float dist_to_sel_edge = abs(hex_radius - dist_from_sel_center);
bool inside_cutout = (dist_from_sel_center <= hex_radius_cutout);
```

```glsl
// Lines 161-164: dark shadow applied when inside cutout
if (has_selection) {
    if (inside_cutout) {
        albedo = mix(albedo, vec3(0.02, 0.02, 0.02), 0.95 * tint_fade);
        alpha = max(alpha, 0.95 * tint_fade);
    }
```

- **Color:** `vec3(0.02, 0.02, 0.02)` (near black).
- **Alpha:** `0.95 * tint_fade` (tint_fade ramps over 0.2s via `min(params.selection_time / 0.2, 1.0)`).
- **Conditional:** Only when `has_selection` and `inside_cutout`. Cutout region is **hex plus margin** (`hex_radius_cutout = hex_radius + CUTOUT_MARGIN_M`), so the dark overlay extends **outside** the hex by 15 m.

### HEX DISTANCE CALC (selection)

```glsl
vec2 d_sel = abs(world_xz - params.selected_hex_center);
float d1_sel = d_sel.y;
float d2_sel = abs(dot(d_sel, vec2(SQRT_3/2.0, 0.5)));
float dist_from_sel_center = max(d1_sel, d2_sel);
```

- **Number of distance checks:** 2 (`d1_sel`, `d2_sel`).
- **Format:** `dist_from_sel_center = max(d1_sel, d2_sel)` (no third component).
- **Note:** This is the standard flat-top hex “distance from center” in the 2D metric; `hex_radius` is half the hex width (`params.hex_size * 0.5`).

### GOLDEN BORDER / GLOW CODE

```glsl
// Lines 165-180 (inside has_selection, when is_selected)
if (is_selected) {
    vec3 gold = vec3(1.0, 0.9, 0.5);
    albedo = mix(albedo, gold, 0.25 * tint_fade);
    alpha = max(alpha, 0.25 * tint_fade);
    float outline_width = 20.0 * border_scale;
    float outline_smooth = 6.0 * border_scale;
    float outline = 1.0 - smoothstep(outline_width - outline_smooth, outline_width + outline_smooth, dist_to_sel_edge);
    if (dist_from_sel_center <= hex_radius) {
        albedo = mix(albedo, vec3(0.85, 0.75, 0.35), outline * 0.9);
        alpha = max(alpha, 0.8 * outline);
        float glow_width = 25.0 * border_scale;
        float rim_pulse = 0.7 + 0.3 * sin(params.time * 1.5);
        float glow = glow_fade * glow_scale * exp(-pow(dist_to_sel_edge / glow_width, 2.0)) * rim_pulse;
        emission = vec3(1.0, 0.8, 0.3) * glow;
    }
}
```

- **Outline:** Smoothstep on `dist_to_sel_edge` (distance to hex edge) with `outline_width` and `outline_smooth` scaled by `border_scale` (altitude-based).
- **Conditional:** Golden rim and glow are only applied when `dist_from_sel_center <= hex_radius` (inside the hex). So the **golden border and glow are drawn only for pixels inside the hex**, not in the cutout margin.
- **Breathing:** `rim_pulse = 0.7 + 0.3 * sin(params.time * 1.5)` — time-based pulse applied to the glow.

### NOTES (Step 1)

- Cutout darkens a **larger** region than the hex (hex + 15 m). That can look like dark artifacts “outside” the hex.
- “Two faces” could relate to the hex distance being from `max(d1_sel, d2_sel)`: the gradient and soft transitions differ along the 6 edges (flat-top: 2 axes dominate).
- Breathing is explicitly coded via `rim_pulse` and `params.time`.
- Nearby non-selected hexes get a separate darken (lines 181–186) within `params.hex_size * 2.0`, which can add to perceived “membrane” or dark halos.

---

## Step 2: Physical Slice Generation

**File:** `core/hex_selector.gd`

### GEOMETRY METHOD

- **Approach:** Rectangular grid clipped to hex. Comment: *“Rectangular grid (snap outer points to hex boundary)”* and *“Build ordered boundary vertices… for walls and rim”*.
- **Walls explicitly created:** **Yes.** Loop at lines 263–292: *“Side walls: consecutive boundary vertices, quad each (top L/R, bottom L/R)”*. Each boundary segment becomes a quad (top-left, bottom-left, bottom-right, top-right) with `earth` vertex color and outward normals.

### MATERIAL PROPERTIES

**Top surface + walls (single mesh, one material override):**

- `StandardMaterial3D`, `vertex_colors_used = true`, `shading_mode = PER_PIXEL`.
- No explicit `albedo_color` (vertex colors used: terrain colors on top, `earth = Color(0.35, 0.25, 0.15)` on walls).
- Emission is **not** set in `set_selected_hex`. It is updated in `_process`: `smat.emission = Color(0.12, 0.08, 0.02) * clampf(lift_factor * 1.2, 0.0, 1.0)`, `emission_energy_multiplier = 0.4` (dim warm tint during lift).

**Rim:**

- Separate mesh: `_build_golden_rim_mesh()` returns an `ArrayMesh` with `PRIMITIVE_LINE_STRIP` (6 corners + close).
- Material: `StandardMaterial3D`, `albedo_color = Color(0.9, 0.75, 0.3)`, `emission_enabled = true`, `emission` same color, `emission_energy_multiplier = 0.8`, `shading_mode = SHADING_MODE_UNSHADED`.
- Rim is a **child** `MeshInstance3D` of the slice node (same transform as the lifted slice).

### RENDER FLAGS

- **render_priority:** Not set (default).
- **transparency:** Not set (opaque).
- **cull_mode:** Not set (default back-face cull).

### NOTES (Step 2)

- Single material for both top and walls; walls are only differentiated by vertex color (earth).
- Rim is a line strip (one pixel wide in practice); no separate “thick” rim geometry. Visibility depends on line rendering and possible overlay darkening.
- Slice (and rim) move with `_slice_instance.position.y` (lift + oscillation); they do not set a special render order vs the screen-space overlay.

---

## Step 3: Runtime State During Selection

Diagnostic code was added at the end of `set_selected_hex()` in `core/hex_selector.gd`:

```gdscript
print("=== SLICE DIAGNOSTIC ===")
print("Hex center: ", hex_center)
print("Vertices generated: ", vert_count)
print("Slice node exists: ", _slice_instance != null)
if _slice_instance:
    print("  Visible: ", _slice_instance.visible)
    print("  Position: ", _slice_instance.position)
    print("  Children: ", _slice_instance.get_child_count())
print("========================")
```

**Action required:** Run the project, click a hex, and paste the console output here.

### RUNTIME STATE

```
=== RUNTIME STATE ===
=== SLICE DIAGNOSTIC ===
Hex center: (3077854, 1944000.0)
Vertices generated: 805
Slice node exists: true
  Visible: true
  Position: (3077854, 0.0, 1944000.0)
  Children: 1
========================
```

**Interpretation:** Slice is created and visible; 805 vertices (grid + boundary walls); position at world (center_x, 0, center_z) so lift will animate `position.y`; 1 child = golden rim MeshInstance3D. No errors; geometry and node tree match expectations.

---

## Step 4: Shader Constants

**File:** `rendering/hex_overlay_screen.glsl`

| Constant            | Value              |
|---------------------|--------------------|
| **SQRT_3**          | `1.73205080757`    |
| **CUTOUT_MARGIN_M** | `15.0`             |

**Other selection-related constants / values:**

- `LINE_WIDTH = 30.0` (grid/hover line width).
- `SELECT_SENTINEL = 900000.0` (invalid selection sentinel).
- Selection styling is driven by uniforms and derived values:
  - `border_scale = clamp(params.altitude / 5000.0, 1.0, 25.0)`
  - `outline_width = 20.0 * border_scale`
  - `outline_smooth = 6.0 * border_scale`
  - `glow_width = 25.0 * border_scale`
  - `glow_scale = 1.0 + params.altitude / 50000.0`
  - Fades: `glow_fade`, `darken_fade`, `tint_fade` from `params.selection_time` (0.1s, 0.3s, 0.2s respectively).

---

## Step 5: Expected Visual (from code)

### When a hex is selected, the shader should

1. **Cutout:** Darken the entire region within `hex_radius + 15` m of the selected hex center to near black (0.02) with high alpha (0.95 × tint_fade), so the “hole” is larger than the hex and extends outside it.
2. **Border:** Draw a golden outline (0.85, 0.75, 0.35) only for pixels **inside** the hex (`dist_from_sel_center <= hex_radius`), using a smoothstep on `dist_to_sel_edge` (width/smooth scaled by altitude).
3. **Glow:** Add orange-gold emission (1.0, 0.8, 0.3) with a Gaussian falloff from the hex edge and a time-based pulse (breathing). Also only inside the hex.
4. **Surrounding:** Slightly darken other hexes within 2× hex_size of the selection center (0.15 alpha blend to black).

### The physical slice should

1. **Shape:** Lifted hex-shaped “cookie” of terrain: rectangular grid clipped to flat-top hex, with a small vertical offset above terrain to avoid z-fight.
2. **Walls:** Vertical quads along the 6 hex edges, from terrain height (plus offset) down by `WALL_DEPTH_M` (40 m), earth-colored.
3. **Materials:** One vertex-colored material for top + walls (terrain + earth); emission updated in `_process` for a slight warm lift glow. Rim: separate unshaded golden emissive line strip at the hex boundary.

### Render order

1. Opaque scene (terrain, slice mesh including walls, rim line strip) is drawn first.
2. Compositor runs at `EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT`, so the hex overlay (grid, cutout, border, glow) is drawn **after** opaque geometry, on top of the resolved color/depth. So the overlay (including the large dark cutout) is composited over the slice and terrain; the slice and its rim are underneath the overlay.

---

## Step 6: File Access

- **Location:** Shader lives in `rendering/hex_overlay_screen.glsl` (external file).
- **Compositor:** `rendering/hex_overlay_compositor.gd` loads it with `FileAccess.get_file_as_string("res://rendering/hex_overlay_screen.glsl")` — **external file**, not inline.
- **Search:** `find` / grep for `hex_overlay` shows references in `hex_overlay_compositor.gd`, `basic_camera.gd`, `CODEBASE_AUDIT.md`, `PROGRESS.md`, and `hex_overlay_screen.glsl.import`. No second copy of the compute shader source; no inline shader string in the compositor.

**To confirm from shell (Windows):**

```powershell
type rendering\hex_overlay_screen.glsl
```

The file exists and is the one analyzed above.

---

## Summary of findings relevant to artifacts

| Observation | Possible relevance |
|-------------|--------------------|
| Cutout is hex_radius **+ 15 m** | Dark band/artifacts **outside** the hex; “membrane” feel. |
| Golden outline/glow only when **inside** hex | Rim can be hard to see if cutout darkening or alpha dominates. |
| **rim_pulse** with `params.time * 1.5` | Explains “breathing” animation. |
| Hex distance = **max(d1_sel, d2_sel)** (2 axes) | Different edge orientations can give asymmetric soft transitions (“two faces” more affected). |
| Nearby hex darken (2× hex_size) | Extra darkening around selection can look like halos or membrane. |
| Rim = line strip, child of slice | Thin; can be lost under strong overlay darkening or depth. |
| Overlay drawn **after** opaque pass | Cutout and darkening are drawn on top of the physical slice, so slice and walls can look “under a dark layer” rather than a clear lifted piece. |

---

**Next step:** Fill in **Step 3 (Runtime State)** by running the game, selecting a hex, and pasting the printed diagnostic output. Then we can use this report to design a precise fix.
