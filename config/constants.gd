class_name Constants
## GeoStrategy Engine - Centralized Constants
## All tunable values from the Single Source of Truth (v1.0.0)
## Organized by category for easy reference.


# ── Data & Heightmap ─────────────────────────────────────────────

const RESOLUTION_M: float = 90.0 # Ground sampling distance at LOD 0 (90m for Europe SRTM3)
const HEIGHT_BIT_DEPTH: int = 65535 # UInt16 max value
const SEA_LEVEL_M: float = 0.0 # Values below this become 0
const SEA_LEVEL_UINT16: int = 1000 # Pipeline maps 0m to this in PNG; loader maps it back to 0m


# ── Chunks ───────────────────────────────────────────────────────

const CHUNK_SIZE_PX: int = 512 # Pixels per chunk side
const CHUNK_SIZE_M: float = 46080.0 # 512 * 90m = 46.08 km per chunk side
const CHUNK_POOL_SIZE: int = 100 # Pre-allocated mesh instances
const TARGET_LOADED_CHUNKS: int = 49 # 7x7 grid around camera


# ── LOD ──────────────────────────────────────────────────────────

const LOD_LEVELS: int = 5 # 0 (highest) to 4 (lowest)

const LOD_RESOLUTIONS_M: Array[float] = [
	90.0, # LOD 0 — original SRTM3
	180.0, # LOD 1 — 2x downsampled
	360.0, # LOD 2 — 4x downsampled
	720.0, # LOD 3 — 8x downsampled
	1440.0, # LOD 4 — 16x downsampled
]

## Distance thresholds for switching TO this LOD (in meters). Continental scale (Europe).
const LOD_DISTANCES_M: Array[float] = [
	0.0, # LOD 0: 0–50 km (3×3 full-detail)
	50000.0, # LOD 1: 50–75 km
	75000.0, # LOD 2: 75–200 km
	200000.0, # LOD 3: 200–500 km
	500000.0, # LOD 4: 500 km+
]

const LOD_HYSTERESIS: float = 0.10 # 10% overlap to prevent flickering
## Inner ring: LOD 0 cells within this (500 km). Used by ChunkManager for desired set.
const INNER_RADIUS_M: float = 500000.0
## visible_radius = max(INNER_RADIUS_M, altitude * this). Used by ChunkManager.
const VISIBLE_RADIUS_ALTITUDE_FACTOR: float = 2.5

# ── Streaming ────────────────────────────────────────────────────

const LOAD_RADIUS_CHUNKS: int = 3 # Chunks to load in each direction
const UNLOAD_DISTANCE_CHUNKS: int = 5 # Chunks beyond this get unloaded
const MAX_CONCURRENT_LOADS: int = 4 # Async loading threads
const UNLOAD_CHECK_INTERVAL_S: float = 0.5 # Seconds between unload checks
const MEMORY_BUDGET_BYTES: int = 2147483648 # 2 GB for terrain chunks


# ── Hex Grid ─────────────────────────────────────────────────────

const HEX_SIZE_M: float = 1000.0 # Flat-top hex width (flat edge to flat edge)
const HEX_WIDTH_M: float = 1000.0 # Same as HEX_SIZE_M
const HEX_HEIGHT_M: float = 866.025 # Flat-top hex height (width * sqrt(3)/2)
const HEX_VERTICES: int = 7 # Center + 6 corners


# ── Geographic Projection ────────────────────────────────────────

const EARTH_RADIUS_M: float = 6371000.0 # Mean Earth radius
## Reference latitude is computed per-region at runtime (center of bounding box)


# ── Camera — Macro View ──────────────────────────────────────────

const CAMERA_MIN_ALTITUDE_M: float = 5000.0 # 5 km (close tactical)
const CAMERA_MAX_ALTITUDE_M: float = 5000000.0 # 5,000 km (full continental, e.g. all of Europe)
const CAMERA_BOUNDS_MARGIN_M: float = 50000.0 # 50 km beyond region edge
const CAMERA_SPEED_FACTOR: float = 100.0 # m/s per 1000m altitude → speed = 100 * (alt/1000)
const CAMERA_PITCH_MIN_DEG: float = 30.0 # Minimum pitch from horizon
const CAMERA_PITCH_MAX_DEG: float = 80.0 # Maximum pitch from horizon
const CAMERA_ROTATE_STEP_DEG: float = 15.0 # Q/E rotation increment
const CAMERA_ZOOM_LEVELS: int = 10 # Discrete scroll-wheel steps
const CAMERA_EDGE_SCROLL_MARGIN_PX: int = 10 # Edge scrolling trigger zone


# ── Camera — Micro View ─────────────────────────────────────────

const MICRO_CAMERA_ALTITUDE_M: float = 500.0 # Default altitude above hex center
const MICRO_CAMERA_PITCH_DEG: float = 45.0 # Default pitch angle
const MICRO_CAMERA_BOUNDS_HEXES: int = 3 # Max movement radius from selected hex


# ── Micro Terrain ────────────────────────────────────────────────

const MICRO_RESOLUTION_M: float = 10.0 # Meters per vertex (9x macro LOD 0)
const MICRO_NOISE_AMPLITUDE_M: float = 5.0 # ±5m additive noise
const MICRO_NOISE_FREQUENCY: float = 0.01 # 100m feature size
const MICRO_NOISE_OCTAVES: int = 3 # Simplex noise octaves
const MICRO_COVERAGE_RINGS: int = 1 # Selected hex + N neighbor rings (7 hexes for 1)
const MICRO_EDGE_BLEND_M: float = 50.0 # Alpha feather zone at edges
const MICRO_MESH_GEN_TARGET_MS: float = 200.0 # Max time per hex mesh generation


# ── View Transition ──────────────────────────────────────────────

const TRANSITION_DURATION_S: float = 1.5 # Camera fly-over time
const TRANSITION_FADE_OUT_S: float = 0.3 # Fade to black duration
const TRANSITION_FADE_IN_S: float = 0.3 # Fade from black duration


# ── Hex Selection Visuals ────────────────────────────────────────

const HEX_SELECTED_COLOR: Color = Color(1.0, 1.0, 0.0, 0.667) # #FFFF00AA ~60% opacity
const HEX_HOVERED_COLOR: Color = Color(1.0, 1.0, 1.0, 1.0) # #FFFFFFFF
const HEX_HOVERED_OUTLINE_PX: float = 3.0
const HEX_GRID_COLOR: Color = Color(1.0, 1.0, 1.0, 0.502) # #FFFFFF80
const HEX_GRID_LINE_PX: float = 2.0
const HEX_SELECTION_PULSE_S: float = 0.5 # Pulse animation duration


# ── Hex Raycast ──────────────────────────────────────────────────

const TERRAIN_PHYSICS_LAYER: int = 10 # Dedicated collision layer
const RAYCAST_MAX_DISTANCE_M: float = 10000.0 # Max raycast distance


# ── Grid Visibility ──────────────────────────────────────────────

const GRID_FADE_START_M: float = 5000.0 # Fully visible below this
const GRID_FADE_END_M: float = 20000.0 # Fully invisible above this
const GRID_DEFAULT_VISIBLE: bool = true


# ── Performance ──────────────────────────────────────────────────

const TARGET_FPS: int = 30 # Minimum acceptable
const IDEAL_FPS: int = 60 # Target
const FPS_DEGRADE_THRESHOLD: int = 30 # Below this triggers degradation
const FPS_DEGRADE_DURATION_S: float = 3.0 # Seconds below threshold to trigger
const FPS_RECOVERY_THRESHOLD: int = 40 # Above this restores settings
const FPS_RECOVERY_DURATION_S: float = 10.0 # Seconds above threshold to recover
const FPS_DEGRADE_LOD_INCREASE: float = 0.20 # 20% increase to LOD distances
const TARGET_FRAME_TIME_MS: float = 33.0 # 1000 / 30 FPS
const IDEAL_FRAME_TIME_MS: float = 16.0 # 1000 / 60 FPS
const CHUNK_LOAD_TARGET_MS: float = 100.0 # Max per-chunk load latency


# ── UI Layout ────────────────────────────────────────────────────

const MINIMAP_SIZE_PX: int = 200 # Minimap width and height
const NOTIFICATION_FADE_S: float = 3.0 # Transient message duration
const ERROR_NOTIFICATION_S: float = 5.0 # Error banner auto-dismiss
const UI_SCALE_OPTIONS: Array[float] = [0.75, 1.0, 1.25, 1.5]


# ── Overlay Defaults ─────────────────────────────────────────────

const OVERLAY_OPACITY_DEFAULT: float = 1.0 # 100%
const OVERLAY_OPACITY_STEP: float = 0.1 # 10% per keypress ([ and ])
const OVERLAY_OPACITY_MIN: float = 0.0
const OVERLAY_OPACITY_MAX: float = 1.0


# ── Paths ────────────────────────────────────────────────────────

const TERRAIN_DATA_PATH: String = "res://data/terrain/"
const CHUNK_PATH_PATTERN: String = "res://data/terrain/chunks/lod%d/chunk_%d_%d.png"
const METADATA_PATH: String = "res://data/terrain/terrain_metadata.json"
const REGIONS_CONFIG_PATH: String = "res://config/regions.json"
const SETTINGS_PATH: String = "user://settings.cfg"
const LOG_PATH: String = "user://logs/engine.log"


# ── Debug ────────────────────────────────────────────────────────

const DEBUG_OVERLAY_KEY: String = "F3"
const CHUNK_VISUALIZER_KEY: String = "F4"
const ERROR_TILE_COLOR: Color = Color(1.0, 0.0, 1.0, 1.0) # Magenta for corrupted chunks
