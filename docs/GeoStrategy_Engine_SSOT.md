# GeoStrategy Engine - Single Source of Truth

**Version:** 1.0.0  
**Last Updated:** February 14, 2026  
**Engine:** Godot 4  
**Target Platform:** Desktop (Windows/Linux), mid-range hardware

---

## Project Overview

GeoStrategy Engine is a Godot 4-based geospatial strategy engine that renders real-world continental terrain from elevation datasets. The system provides deterministic, data-driven foundation for 4X and grand strategy gameplay with synchronized macro (continental) and micro (local hex) views.

---

## 1. Data Processing & Pipeline

### 1.1 Elevation Data Source
- **Primary Source:** SRTM3 (90m resolution, ~3 arc-seconds)
- **Fallback Sources:** 
  1. ASTER GDEM v3 (30m resolution)
  2. GEBCO (global 15 arc-second)
- **Priority:** SRTM3 → ASTER → GEBCO
- **Data Voids:** Filled using nearest-neighbor interpolation, then 3×3 Gaussian blur

### 1.2 Normalization & Merge
- **Algorithm:** Bilinear blending in overlap zones (10-pixel feather)
- **Normalization:** Min-max normalization to [0, 65535] range per continent
- **Sea Level:** Fixed at elevation 0m (values below become 0)
- **Output Format:** Single 16-bit grayscale PNG heightmap per region

### 1.3 Single Heightmap Specifications
- **Resolution:** 1 pixel = 90m ground sampling distance
- **Bit Depth:** UInt16 (0-65535 range)
- **Height Encoding:** Linear mapping: `real_height_m = pixel_value * (max_elevation / 65535)`
- **File Format:** PNG (lossless, widely supported)
- **Dimensions:** Calculated from bounding box: `width = (lon_max - lon_min) * 111320 / 90`

### 1.4 Chunk Specifications
- **Chunk Size:** 512×512 pixels (46.08 km × 46.08 km at 90m resolution)
- **LOD Levels:** 5 levels (0-4, where 0 = highest detail)
  - LOD 0: 90m/pixel (original SRTM3)
  - LOD 1: 180m/pixel (2× downsampled)
  - LOD 2: 360m/pixel (4× downsampled)
  - LOD 3: 720m/pixel (8× downsampled)
  - LOD 4: 1440m/pixel (16× downsampled)
- **Downsampling:** Box filter (average of 2×2 blocks per level)
- **Storage Pattern:** `chunks/lod{level}/chunk_{x}_{y}.png`

### 1.5 Offline Processing
- **Workflow:** Python script (`tools/process_terrain.py`)
- **Execution:** Manual pre-build step
- **Pipeline:**
  1. Download SRTM tiles for bounding box
  2. Merge tiles with blending
  3. Normalize to UInt16 range
  4. Generate master heightmap
  5. Tile into chunks at all LOD levels
  6. Generate metadata JSON
- **Output Location:** `res://data/terrain/`
- **Processing Time:** ~15 minutes for Europe on 8-core CPU

---

## 2. Runtime Streaming & Performance

### 2.1 Chunk Loading Strategy
- **Load Radius:** 3 chunks in each direction from camera center
- **Loading Method:** Async (threaded) using Godot's `Thread` system
- **Priority Queue:** Distance-sorted, closest chunks load first
- **Max Concurrent Loads:** 4 threads

### 2.2 Unloading Policy
- **Unload Distance:** 5 chunks from camera center
- **Memory Budget:** 2GB for terrain chunks
- **Policy:** FIFO when memory budget exceeded, furthest chunks unloaded first
- **Unload Frequency:** Checked every 0.5 seconds

### 2.3 LOD Transition
- **Method:** Distance-based hard switching (no blending/geomorphing in v1.0)
- **LOD Distances (from camera):**
  - LOD 0: 0-10 km
  - LOD 1: 10-25 km
  - LOD 2: 25-50 km
  - LOD 3: 50-100 km
  - LOD 4: 100+ km
- **Hysteresis:** 10% overlap to prevent flickering (e.g., LOD 0→1 at 10km, 1→0 at 9km)

### 2.4 Cache Management
- **Chunk Pooling:** Yes, pool of 100 pre-allocated mesh instances
- **Reuse Strategy:** Meshes recycled, only height data reloaded
- **Memory Target:** Keep 49 chunks loaded (7×7 grid around camera)

### 2.5 Performance Degradation Handling
- **Target:** 30 FPS minimum on mid-range hardware
- **Fallback Actions (when FPS < 30 for 3+ seconds):**
  1. Reduce load radius by 1 chunk
  2. Increase LOD transition distances by 20%
  3. Disable procedural micro detail
  4. Reduce hex grid overlay resolution
- **Recovery:** Restore settings when FPS > 40 for 10+ seconds

---

## 3. Coordinate System & Grid

### 3.1 Hex Coordinate System
- **Type:** Axial coordinates (q, r) - flat-top hexagons
- **Conversion Library:** Custom implementation based on Red Blob Games reference
- **Storage:** Axial coordinates internally, cube coordinates for distance calculations
- **Origin:** (0, 0) at northwest corner of region bounding box

### 3.2 Hex Size and Scale
- **Macro Hex Size:** 10 km (point-to-point diameter)
- **Micro Hex Size:** Fixed at macro scale (no rescaling per zoom)
- **Hex-to-World Ratio:** 1 hex = 10,000m × 8,660m (width × height)
- **Vertices per Hex (macro):** 7 (center + 6 corners)

### 3.3 Grid Overlay Rendering
- **Method:** Shader-based line rendering on terrain surface
- **Shader:** Custom fragment shader projecting hex grid from world position
- **Alignment:** Grid follows terrain elevation (not flat overlay)
- **Line Width:** 2 pixels at all zoom levels
- **Color:** Semi-transparent white (#FFFFFF80)

### 3.4 Coordinate Precision
- **World Coordinates:** Float64 (double precision) for positions
- **Rendering:** Float32 for mesh vertices (converted at upload)
- **Reason:** Prevent jitter at continental scales (>1000 km)

### 3.5 Geographic Projection
- **Projection Type:** Equirectangular (Plate Carrée)
- **Formula:** `x = (lon - lon_0) * cos(lat_0) * R`, `y = (lat - lat_0) * R`
- **Reference Latitude (lat_0):** Center latitude of bounding box
- **Earth Radius (R):** 6,371,000 m
- **Rationale:** Simple, adequate for continental-scale regions (<30° latitude span)

---

## 4. Macro View

### 4.1 Terrain Mesh Resolution
- **Base Resolution:** Matches LOD 0 chunk resolution (90m/pixel)
- **Vertex Density:** 1 vertex per pixel in active LOD
- **Mesh Generation:** ArrayMesh with indexed triangles
- **Normal Calculation:** Computed from neighboring heights (cross product)

### 4.2 Hex Selection Mechanism
- **Method:** Raycast from camera through mouse position
- **Physics Layer:** Dedicated layer 10 for terrain collision
- **Collision Shape:** One StaticBody3D per loaded chunk with HeightMapShape3D
- **Click Tolerance:** Raycast up to 10,000m distance
- **Conversion:** Hit point → world coords → pixel coords → hex coords

### 4.3 Visual Feedback
- **Selected Hex:** Yellow tinted overlay shader (#FFFF00AA, 60% opacity)
- **Hovered Hex:** White outline (3-pixel width, #FFFFFFFF)
- **Method:** Separate shader pass with stencil buffer for hex borders
- **Update Rate:** Hover updates every frame, selection persists until changed

### 4.4 Camera Constraints
- **Min Zoom:** 5 km altitude (close tactical view)
- **Max Zoom:** 500 km altitude (strategic continental view)
- **Bounds:** Hard-clamped to region bounding box + 50km margin
- **Movement Speed:** `100 m/s * (altitude / 1000)` (scales with zoom)
- **Rotation:** Free yaw (360°), pitch locked to 30°-80° from horizon

---

## 5. Micro View

### 5.1 Procedural Noise
- **Type:** FastNoiseLite (Simplex, built-in to Godot)
- **Amplitude:** ±5m (additive only, never subtracts below base elevation)
- **Frequency:** 0.01 (100m feature size)
- **Octaves:** 3
- **Application:** Added at mesh vertex level, not to base heightmap

### 5.2 Micro Mesh Resolution
- **Resolution:** 10m/vertex (9× higher density than macro LOD 0)
- **Hex Coverage:** Single hex generates ~1000×866 vertices = 866k triangles
- **LOD in Micro:** Not implemented (single resolution view)
- **Generation Time Target:** <200ms for single hex mesh

### 5.3 Macro-to-Micro Transition
- **Trigger:** Double-click on hex in macro view
- **Animation:** Camera fly-over (Bézier curve interpolation)
- **Duration:** 1.5 seconds
- **Target Position:** 500m above hex center, 45° pitch
- **During Transition:** Input locked, macro mesh fades out, micro fades in

### 5.4 Micro View Bounds
- **Coverage:** Selected hex + 1-ring neighbors (7 hexes total)
- **Edge Blending:** 50m feather zone using alpha transparency
- **Background:** Skybox with distant terrain LOD 4 for context
- **Camera Bounds:** Cannot move outside 3-hex radius from selected hex

---

## 6. Data Storage & Format

### 6.1 Chunk File Format
- **Format:** PNG (16-bit grayscale, lossless)
- **Compression:** PNG standard (zlib)
- **Rationale:** Native Godot Image support, human-inspectable, decent compression

### 6.2 Metadata Structure
- **Format:** JSON (`terrain_metadata.json`)
- **Contents:**
```json
{
  "region_name": "Europe",
  "bounding_box": {"lat_min": 36.0, "lat_max": 71.0, "lon_min": -10.0, "lon_max": 40.0},
  "resolution_m": 90,
  "max_elevation_m": 4810,
  "chunk_size_px": 512,
  "lod_levels": 5,
  "chunks": [
    {"lod": 0, "x": 0, "y": 0, "path": "chunks/lod0/chunk_0_0.png", "bounds": {...}},
    ...
  ]
}
```

### 6.3 Bounding Box Configuration
- **Storage:** `res://config/regions.json`
- **Editable:** Design-time only (requires terrain reprocessing)
- **Multiple Regions:** Supported (switch via game menu)
- **Active Region:** Set in project settings, loaded at runtime

### 6.4 Height Sampling API
- **Primary Method:** Bilinear interpolation (4 nearest pixels)
- **Advanced Option:** Bicubic interpolation (16 pixels, slower)
- **API Signature:** `sample_height(world_pos: Vector2) -> float`
- **Fallback:** Return 0.0 for out-of-bounds queries

---

## 7. Architecture & Integration

### 7.1 Module Structure
```
res://
├── core/
│   ├── terrain_manager.gd          # Singleton, orchestrates all systems
│   ├── chunk_streamer.gd           # Async loading/unloading
│   ├── coordinate_transform.gd     # All coord conversions (world↔hex↔geo)
│   └── height_sampler.gd           # Height queries from heightmap
├── rendering/
│   ├── macro_terrain_view.gd       # Macro mesh generation & camera
│   ├── micro_terrain_view.gd       # Micro mesh generation & detail
│   └── hex_grid_overlay.gd         # Shader-based grid rendering
├── ui/
│   ├── hud.gd                      # Main HUD controller
│   ├── hex_info_panel.gd          # Selected hex details
│   └── minimap.gd                  # Strategic overview
├── data/
│   └── terrain/
│       ├── chunks/                 # Generated chunks (gitignored)
│       └── terrain_metadata.json
└── config/
    ├── constants.gd                # All tunable constants
    └── regions.json                # Region bounding boxes
```

### 7.2 Constants Centralization
- **File:** `res://config/constants.gd` (GDScript class with const declarations)
- **Categories:** Chunk, LOD, Camera, Hex, Performance, UI
- **Example:**
```gdscript
class_name Constants

const CHUNK_SIZE_PX: int = 512
const LOD_LEVELS: int = 5
const HEX_SIZE_M: float = 10000.0
```

### 7.3 Error Handling
- **Missing Chunks:** Load lower LOD fallback, log warning
- **Corrupted Data:** Skip chunk, display error tile (magenta debug texture)
- **Invalid Coordinates:** Clamp to valid range, return boundary value
- **OOM:** Emergency unload all LOD 2+ chunks, show performance warning

### 7.4 Debug Tools
- **Debug Overlay:** Toggle with F3 key
- **Displays:**
  - Active chunks (count, LOD distribution)
  - Memory usage (MB)
  - Current FPS / frame time
  - Camera position (world, hex, geo)
  - Hovered hex info
- **Chunk Visualizer:** Wireframe outlines showing loaded chunks (F4 toggle)

### 7.5 Determinism Guarantees
- **Heightmap:** Deterministic (loaded from file, no RNG)
- **Micro Procedural Noise:** Seeded by hex coordinates (q, r) → deterministic
- **Chunk Loading Order:** May vary, but doesn't affect gameplay
- **Network Sync:** Not required for terrain (all clients load same data)

### 7.6 Future Gameplay Hooks
- **Terrain Query API:**
  - `get_hex_elevation(hex_coords) -> float`
  - `get_hex_slope(hex_coords) -> float` (average gradient)
  - `get_hex_terrain_type(hex_coords) -> TerrainType` (elevation-based classification)
- **Movement Cost:** Derived from slope and terrain type
- **Resource Placement:** Seeded procedural generation per hex
- **Line-of-Sight:** Raycast using heightmap data

---

## 8. Player Usage & Interaction

### 8.1 Camera Controls
- **Scheme:** Hybrid (WASD + mouse drag + edge scrolling)
- **Pan:**
  - WASD keys: 4-directional movement
  - Middle-mouse drag: Free pan
  - Edge scrolling: Mouse at screen edge (10px margin)
- **Zoom:** Mouse scroll wheel (discrete steps, 10 zoom levels)
- **Rotation:** Q/E keys for 15° increments, hold right-click + mouse drag for free rotation
- **Shortcuts:**
  - Home: Reset to region center
  - Space: Focus on selected hex
  - PageUp/Down: Altitude adjustment

### 8.2 Hex Selection & Interaction
- **Primary Selection:** Left-click on hex
- **Multi-Selection:** Not supported in v1.0
- **Deselection:** Left-click on empty terrain or press ESC
- **Hover:** Real-time highlight on mouse-over (no click required)
- **Touch Support:** Not planned for v1.0

### 8.3 Hex Information Display
- **Trigger:** Left-click selects hex → info panel appears (bottom-right)
- **Panel Contents:**
  - Hex coordinates (axial and geo)
  - Average elevation (meters)
  - Slope percentage
  - Terrain type (classified)
  - Placeholder: Resources, owner, improvements (future)
- **Tooltip on Hover:** Floating tooltip near cursor with hex coords and elevation

### 8.4 View Switching
- **Macro → Micro:** Double-click on selected hex
- **Micro → Macro:** Press ESC or click "Back to Macro" button (top-left)
- **Animation:** 1.5s camera interpolation (can be skipped by pressing Space)
- **State Persistence:** Macro camera position saved when entering micro, restored on return
- **Concurrent Views:** Not supported in v1.0

### 8.5 Planned Actions (Future Gameplay)
*Hooks for 4X mechanics, not implemented in engine v1.0:*
- Unit placement and movement
- City/building construction
- Resource assignment
- Hex ownership and borders
- Combat resolution

### 8.6 Command Queuing
- **Not Implemented:** V1.0 is observation/navigation only
- **Future:** Shift-click chaining for multi-turn planning

### 8.7 Context Menus
- **Trigger:** Right-click on hex (macro view only)
- **Contents:**
  - "View Details" (opens info panel)
  - "Zoom to Micro" (same as double-click)
  - "Set Waypoint" (marks hex with icon)
- **Style:** Flat list menu (not radial)

---

## 9. UI & Feedback

### 9.1 HUD Elements
**Always Visible:**
- Minimap (top-right, 200×200px)
- Current view indicator (top-left): "Macro View" or "Micro View: Hex (q, r)"
- FPS counter (top-left, debug mode only)
- Notification area (top-center): Transient messages (3s fade)

**Toggleable (all hidden by default):**
- Hex info panel (bottom-right)
- Debug overlay (F3)
- Chunk visualizer (F4)

### 9.2 Terrain Overlays
- **Grid Toggle:** G key (show/hide hex grid)
- **Elevation Heatmap:** H key (color-coded elevation visualization)
- **Slope Overlay:** S key (red = steep, green = flat)
- **Overlay Opacity:** [ and ] keys to adjust (0-100%)

### 9.3 Grid Visibility
- **Default:** Visible in macro, hidden in micro
- **Toggle:** G key in both views
- **Transparency Control:** Shader uniform, adjustable 0-100%
- **Fade with Zoom:** Grid opacity reduces at max zoom (>300 km altitude)

### 9.4 Cursor States
- **Default:** Standard arrow
- **Hex Hover:** Pointer hand (clickable)
- **Camera Pan (middle-mouse):** Grabbing hand
- **Rotate (right-mouse):** Rotate icon
- **Loading:** Hourglass when chunks streaming
- **Invalid Action:** (future) Red crossed circle

### 9.5 Visual Feedback
- **Hex Selection:** Instant yellow tint + subtle pulse animation (0.5s)
- **View Transition:** Screen fade to black (0.3s) + camera movement (1.5s) + fade in (0.3s)
- **Chunk Loading:** No per-chunk feedback (silent background loading)
- **Error:** Red notification banner with icon

### 9.6 Error Messaging
- **Method:** Transient notification (top-center, 5s auto-dismiss)
- **Severity:**
  - Info: Blue background (e.g., "Chunk loaded")
  - Warning: Yellow background (e.g., "Performance degraded")
  - Error: Red background (e.g., "Failed to load terrain data")
- **Log:** All messages also written to `user://logs/engine.log`

---

## 10. Input & Accessibility

### 10.1 Keyboard Shortcuts
**Navigation:**
- WASD: Pan camera
- Q/E: Rotate camera
- Mouse Wheel: Zoom
- Space: Focus selected hex
- Home: Reset camera to region center
- PageUp/Down: Altitude adjustment

**View:**
- G: Toggle hex grid
- H: Toggle elevation heatmap
- S: Toggle slope overlay
- [ / ]: Decrease/increase overlay opacity
- F3: Toggle debug overlay
- F4: Toggle chunk visualizer
- ESC: Deselect hex / return to macro

**System:**
- F11: Toggle fullscreen
- P: Pause (future turn-based mode)

**All shortcuts rebindable** via Settings → Controls menu (stored in `user://settings.cfg`)

### 10.2 Mouse Button Mapping
- **Left Click:** Select hex
- **Right Click:** Context menu
- **Middle Click + Drag:** Pan camera
- **Right Click + Drag:** Rotate camera
- **Mouse Wheel:** Zoom in/out
- **Not Customizable:** Fixed mapping in v1.0

### 10.3 Gamepad Support
- **Not Implemented:** v1.0 is keyboard/mouse only
- **Future:** Left stick = pan, triggers = zoom, A button = select

### 10.4 Accessibility Features
- **Colorblind Modes:**
  - Deuteranopia filter (shader)
  - Protanopia filter (shader)
  - Tritanopia filter (shader)
  - Toggle in Settings → Accessibility
- **UI Scaling:** 75% / 100% / 125% / 150% (Settings → Display)
- **High Contrast Mode:** Increases grid/outline thickness and contrast
- **Screen Reader:** Not supported in v1.0
- **Keybind Display:** Hold Alt to show overlay with all active shortcuts

### 10.5 Tutorial/Onboarding
- **First Launch:** Interactive tutorial overlay
- **Steps:**
  1. Camera movement (WASD, mouse)
  2. Zoom and rotation
  3. Hex selection and info panel
  4. View switching (macro ↔ micro)
  5. Overlays and shortcuts
- **Skippable:** ESC to skip, "Don't show again" checkbox
- **Replayable:** Help → Tutorial from main menu

---

## 11. Game Loop & Timing

### 11.1 Game Loop Model
- **Mode:** Turn-Based with Real-Time Camera
- **Definition:** Gameplay actions (future) execute in discrete turns, but camera and UI are real-time
- **Turn Length:** (Future) Player-controlled, no time limit
- **Current State:** v1.0 has no turns (exploration mode only)

### 11.2 Turn Submission
- **Trigger:** (Future) "End Turn" button (bottom-center of HUD)
- **Confirmation:** Modal dialog: "End turn and process actions?" [Yes / No / Review]
- **Processing:** Loading screen while AI turns resolve

### 11.3 Time Controls
- **Not Applicable:** No real-time simulation in v1.0
- **Future:** Pause/play toggle for AI turn playback visualization

### 11.4 Action Timing
- **Camera/UI:** Immediate (real-time)
- **Gameplay Actions:** (Future) Queued, execute on turn resolution

---

## 12. Strategic Interaction (Future)

*These systems are design hooks for future implementation, not present in engine v1.0:*

### 12.1 Exploration
- **Fog of War:** Hex-based, revealed by units/cities
- **Mechanism:** Visibility system queries hex line-of-sight
- **Persistent:** Revealed hexes stay visible (shroud mode: dimmed if no current vision)

### 12.2 Resource Gathering
- **Distribution:** Procedurally placed per hex (seeded by hex coords)
- **Gathering:** Automatic per-turn from hexes with improvements
- **Display:** Resource icons in hex info panel

### 12.3 Diplomacy
- **Interface:** Separate diplomacy screen (not in main view)
- **Access:** Minimap faction icons clickable

### 12.4 Combat
- **Initiation:** Automatic when units from different factions occupy adjacent hexes
- **Resolution:** Separate tactical combat screen (micro view repurposed)
- **Visualization:** Unit models on terrain, turn-based movement

### 12.5 Technology
- **UI:** Tech tree screen (separate from main view)
- **Assignment:** Global research queue (not per-hex)

---

## 13. Multiplayer (Future)

*Planned but not implemented in v1.0:*

### 13.1 Mode
- **Type:** Asynchronous turn-based (e.g., play-by-email style)
- **Players:** 2-8 players per game

### 13.2 Turn Timer
- **Default:** 48-hour turn timer (configurable 1 hour - 7 days)
- **Notification:** Email/push when turn ready

### 13.3 Spectator Mode
- **Support:** Yes, read-only observation of completed turns
- **Restrictions:** Cannot see fog of war beyond any player

### 13.4 Session Management
- **Save/Load:** Auto-save after each turn submission
- **Reconnection:** Rejoin game from lobby (persistent server-side state)
- **Turn History:** Replay previous turns in fast-forward mode

---

## 14. Performance & Validation

### 14.1 Target Hardware
**"Mid-Range" Specification:**
- **GPU:** NVIDIA GTX 1660 / AMD RX 5600 XT equivalent (6GB VRAM)
- **CPU:** 4-core / 8-thread @ 3.0+ GHz
- **RAM:** 8GB system memory
- **Storage:** SSD (HDD will cause chunk load stutter)

### 14.2 Test Regions
- **Primary:** Europe (36°N-71°N, 10°W-40°E)
- **Secondary:** East Asia (20°N-50°N, 100°E-145°E)
- **Tertiary:** South America (55°S-10°N, 80°W-35°W)
- **Rationale:** Varied elevation profiles and data quality

### 14.3 Performance Metrics
**Tracked Metrics:**
- Frame rate (target: ≥30 FPS, ideal: 60 FPS)
- Frame time (target: ≤33ms, ideal: ≤16ms)
- Chunk load latency (target: ≤100ms per chunk)
- Memory usage (target: ≤2GB for terrain system)
- Streaming throughput (MB/s from disk)

**Profiling Tools:**
- Godot built-in profiler
- Custom frame time graph (debug overlay)

### 14.4 Validation
- **Elevation Accuracy:** Spot-check 100 random points against source SRTM data (tolerance: ±10m)
- **Coordinate Consistency:** Round-trip test: world → pixel → hex → world (tolerance: ±1m)
- **Determinism:** Run identical scenario 10× across 3 machines, verify identical heightmap samples
- **Visual Inspection:** Manual QA of 50 known landmarks (Mt. Blanc, Alps, Danube, etc.)

---

## 15. Version Control & Build

### 15.1 Repository Structure
```
geostrategy-engine/
├── .gitignore              # Ignore data/terrain/chunks/
├── project.godot
├── README.md
├── ARCHITECTURE.md         # This document
├── tools/
│   └── process_terrain.py  # Offline terrain processor
├── res://                  # Godot project (see 7.1)
└── docs/
    ├── api_reference.md
    └── design/
```

### 15.2 Ignored Assets
- `res://data/terrain/chunks/` (too large for git)
- `res://data/terrain/*.png` (master heightmaps)
- `.import/` (Godot generated)
- User settings and logs

### 15.3 Build Pipeline
1. **Pre-Build:** Run `tools/process_terrain.py` for target region
2. **Export:** Godot export templates (PCK includes metadata but not chunks)
3. **Post-Export:** Package chunks as separate DLC download or patch
4. **Distribution:** Base game + region data packs

### 15.4 Versioning
- **Semantic Versioning:** MAJOR.MINOR.PATCH
- **Current:** 1.0.0 (engine foundation, no gameplay)
- **Future:** 2.0.0 (4X gameplay implementation)

---

## 16. Known Limitations & Future Work

### 16.1 Current Limitations
- **Projection Distortion:** Equirectangular has distortion at high latitudes (>60°)
- **LOD Popping:** Hard LOD transitions cause visual "pop" (no geomorphing)
- **Single-Threaded Mesh Gen:** Mesh construction blocks main thread (~10ms per chunk)
- **No Texture:** Terrain is height-only (no satellite imagery overlay)
- **Fixed Hex Size:** Cannot dynamically adjust hex granularity

### 16.2 Future Enhancements
- **Better Projection:** Switch to Albers Equal-Area for large regions
- **Smooth LOD:** Geomorphing or alpha-blended transitions
- **Async Mesh Gen:** Move mesh construction to worker threads
- **Texture Splatting:** Procedural texture based on elevation/slope
- **Adaptive Hex Grid:** Smaller hexes at higher zoom levels
- **GPU Terrain:** Compute shader-based heightmap rendering
- **Vegetation:** Procedural tree/grass placement based on biome

### 16.3 Open Questions
- **Compression:** Is PNG optimal or should we use custom binary format?
- **Networking:** Full synchronous multiplayer viable or stick to async?
- **Modding Support:** Expose terrain API for user-created scenarios?

---

## 17. Dependencies & Licenses

### 17.1 External Dependencies
- **Godot Engine:** 4.3+ (MIT License)
- **SRTM Data:** Public domain (NASA)
- **ASTER GDEM:** Free for research/commercial (LP DAAC)
- **GEBCO:** Public domain
- **Python Libraries (tools):**
  - GDAL (MIT/X)
  - NumPy (BSD)
  - Pillow (HPND)

### 17.2 Project License
- **Engine Code:** MIT License
- **Terrain Data:** Derivative of public domain sources (include attribution)
- **Documentation:** CC BY 4.0

---

## 18. Contact & Contribution

### 18.1 Project Lead
- **Name:** Otto
- **Location:** São José dos Campos, SP, Brazil
- **Focus:** Infrastructure, rendering, coordinate systems

### 18.2 Contribution Guidelines
- Follow GDScript style guide (Godot docs)
- All PRs require passing unit tests (when implemented)
- Terrain processing changes require validation run on Europe test region
- Document all public APIs with docstrings

### 18.3 Communication
- Issues: GitHub issue tracker
- Design Discussions: GitHub Discussions
- Real-time: (TBD - Discord server?)

---

## Appendix A: Coordinate Conversion Formulas

### A.1 Geographic to World
```
x = (lon - lon_ref) * cos(lat_ref) * EARTH_RADIUS
y = (lat - lat_ref) * EARTH_RADIUS
```

### A.2 World to Pixel
```
px = (x - region_x_min) / RESOLUTION_M
py = (y - region_y_min) / RESOLUTION_M
```

### A.3 Pixel to Hex (Axial)
Using flat-top hexagons with size `s`:
```
q = (sqrt(3)/3 * px - 1/3 * py) / s
r = (2/3 * py) / s
(round to nearest integer using cube coordinate rounding)
```

### A.4 Hex (Axial) to World
```
x = s * (sqrt(3) * q + sqrt(3)/2 * r)
y = s * (3/2 * r)
```

---

## Appendix B: File Format Specifications

### B.1 Chunk PNG Format
- **Color Type:** Grayscale
- **Bit Depth:** 16
- **Dimensions:** 512×512 pixels
- **Interlacing:** None (for faster loading)
- **Compression:** Default zlib level 6

### B.2 Metadata JSON Schema
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["region_name", "bounding_box", "resolution_m", "max_elevation_m", "chunk_size_px", "lod_levels", "chunks"],
  "properties": {
    "region_name": {"type": "string"},
    "bounding_box": {
      "type": "object",
      "required": ["lat_min", "lat_max", "lon_min", "lon_max"],
      "properties": {
        "lat_min": {"type": "number"},
        "lat_max": {"type": "number"},
        "lon_min": {"type": "number"},
        "lon_max": {"type": "number"}
      }
    },
    "resolution_m": {"type": "number"},
    "max_elevation_m": {"type": "number"},
    "chunk_size_px": {"type": "integer"},
    "lod_levels": {"type": "integer"},
    "chunks": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["lod", "x", "y", "path", "bounds"],
        "properties": {
          "lod": {"type": "integer"},
          "x": {"type": "integer"},
          "y": {"type": "integer"},
          "path": {"type": "string"},
          "bounds": {
            "type": "object",
            "required": ["world_x_min", "world_x_max", "world_y_min", "world_y_max"],
            "properties": {
              "world_x_min": {"type": "number"},
              "world_x_max": {"type": "number"},
              "world_y_min": {"type": "number"},
              "world_y_max": {"type": "number"}
            }
          }
        }
      }
    }
  }
}
```

---

## Appendix C: Performance Benchmarks

*To be filled after initial implementation and profiling*

Target benchmarks on reference hardware (GTX 1660, Ryzen 5 3600):
- Europe region load time: <5 seconds
- Chunk streaming rate: >10 chunks/second
- Macro view FPS (100km altitude): 60 FPS
- Micro view FPS (500m altitude): 45 FPS
- Memory footprint (49 loaded chunks): <2GB

---

## Appendix D: Glossary

- **Axial Coordinates:** 2D hex coordinate system using (q, r) axes
- **Chunk:** Fixed-size tile of heightmap (512×512 pixels)
- **Cube Coordinates:** 3D hex coordinate system (q, r, s) where q+r+s=0
- **DEM:** Digital Elevation Model
- **Equirectangular:** Simple map projection treating lat/lon as cartesian x/y
- **Geomorphing:** Technique to smoothly blend LOD transitions
- **LOD:** Level of Detail (multiple resolutions of same data)
- **SRTM:** Shuttle Radar Topography Mission (NASA elevation dataset)
- **Hex:** Hexagonal grid cell
- **Macro View:** Continental-scale strategic view
- **Micro View:** Local-scale tactical view
- **Streaming:** Loading/unloading data on-demand based on camera position

---

**Document Status:** ✅ Complete  
**Review Status:** Pending initial implementation  
**Next Review:** After v1.0 alpha milestone

