# GeoStrategy Engine - Terrain Processing Tools

This directory contains offline terrain processing scripts for the GeoStrategy Engine.

## Prerequisites

Install Python dependencies:

```bash
pip install -r requirements.txt
```

**Required packages:**
- `numpy` - Array operations and data processing
- `Pillow` (PIL) - Image reading/writing (16-bit PNG support)

**Note:** This script intentionally does NOT use GDAL to avoid complex installation requirements.

## Usage

### Basic Usage

Process a region defined in `../config/regions.json`:

```bash
python process_terrain.py --region alps_test
```

### Full Options

```bash
python process_terrain.py \
  --region alps_test \
  --regions-config ../config/regions.json \
  --output ../data/terrain/ \
  --cache ./cache/
```

**Arguments:**
- `--region` (required) - Region name from regions.json (e.g., `alps_test`, `europe`)
- `--regions-config` - Path to regions configuration file (default: `../config/regions.json`)
- `--output` - Output directory for processed terrain (default: `../data/terrain/`)
- `--cache` - Cache directory for downloaded SRTM tiles (default: `./cache/`)

## Processing Pipeline

The script executes the following steps:

1. **Download SRTM3 tiles** (.hgt files, 90m resolution) covering the region's bounding box
   - Caches tiles in `cache/` directory
   - Skips re-downloading cached tiles
   - Fills ocean tiles with zeros

2. **Merge tiles** into a single raster
   - Handles tile overlaps with proper alignment
   - SRTM tiles are named by their SW corner (e.g., N45E006.hgt covers 45°-46°N, 6°-7°E)

3. **Fill data voids** (pixels with value -32768)
   - Uses iterative nearest-neighbor interpolation
   - Applies 3×3 Gaussian blur to smoothed regions

4. **Normalize** to unsigned 16-bit range [0, 65535]
   - Linear mapping: `pixel_value = elevation_m / max_elevation_m * 65535`
   - Clamps negative elevations (below sea level) to 0

5. **Save master heightmap** as `master_heightmap.png`
   - 16-bit grayscale PNG (lossless)
   - Can be opened in any image viewer

6. **Generate LOD levels** (0-4)
   - LOD 0: Original resolution (90m/pixel)
   - Each subsequent LOD: 2× downsampled using box filter
   - Chunks each LOD into 512×512 pixel tiles
   - Saves to `chunks/lod{level}/chunk_{x}_{y}.png`

7. **Generate metadata** (`terrain_metadata.json`)
   - Contains region info, chunk catalog, and bounding boxes

## Output Structure

After processing, the output directory contains:

```
data/terrain/
├── master_heightmap.png          # Full-resolution heightmap
├── terrain_metadata.json          # Metadata and chunk catalog
└── chunks/
    ├── lod0/
    │   ├── chunk_0_0.png
    │   ├── chunk_0_1.png
    │   └── ...
    ├── lod1/
    ├── lod2/
    ├── lod3/
    └── lod4/
```

## Validation

After processing, verify the output:

1. **Visual inspection**: Open `master_heightmap.png` in an image viewer
   - Should show recognizable terrain features (bright = high elevation, dark = low)
   - If all black/white or noisy, something went wrong

2. **Chunk verification**: Check that chunks exist for all LOD levels
   - LOD 0 should have the most chunks
   - Each subsequent LOD should have ~1/4 the chunks

3. **Metadata validation**: Verify `terrain_metadata.json` is valid JSON
   - `chunks` array should match actual chunk files on disk

4. **Bit depth check**: Verify chunks are true 16-bit
   ```python
   from PIL import Image
   img = Image.open('chunks/lod0/chunk_0_0.png')
   print(img.mode)  # Should be 'I' or 'I;16', NOT 'L' (8-bit)
   ```

## SRTM Data Notes

### Data Source
- **SRTM3**: 3 arc-second resolution (~90m at equator)
- **Tile Format**: .hgt files (1201×1201 pixels per 1° tile)
- **Data Type**: Big-endian signed int16
- **Void Value**: -32768

### Tile Naming Convention
SRTM tiles are named by their **southwest corner**:
- `N45E006.hgt` covers 45°-46°N, 6°-7°E
- `S23W043.hgt` covers 23°-22°S, 43°-42°W

### Data Availability
- **Land**: Most land areas covered (2000 mission)
- **Ocean**: No data (script fills with zeros)
- **Voids**: Some areas have data gaps (filled by script)

### Download Sources
The script attempts to download from public SRTM mirrors. In production, you may need:
- NASA EarthData account (free): https://urs.earthdata.nasa.gov/
- Alternative: OpenTopography API
- Alternative: Pre-download tiles manually

## Troubleshooting

### "No module named 'numpy'" or "No module named 'PIL'"
Install dependencies: `pip install -r requirements.txt`

### "Region 'xxx' not found in config"
Check region name in `config/regions.json`. Use exact name (case-sensitive).

### Master heightmap is all black
- Check that SRTM tiles downloaded successfully
- Verify `max_elevation_m` in region config is reasonable
- Check for errors in merge or normalization steps

### Master heightmap is upside down
This is expected if viewing in some tools. The coordinate system has Y-up in world space but Y-down in image space.

### Chunks are 8-bit instead of 16-bit
Verify Pillow version: `pip install --upgrade Pillow>=10.0.0`

### Processing is very slow
- Use SSD for cache and output directories
- Ensure cache directory persists between runs
- Consider reducing region size for testing

## Performance

Approximate processing times (8-core CPU, SSD):
- **alps_test** (~2.5° × 4.5°): ~2-5 minutes
- **europe** (~35° × 50°): ~15-20 minutes

Memory usage scales with region size:
- **alps_test**: ~500 MB peak
- **europe**: ~4-8 GB peak

## Integration with Godot

The generated terrain data is ready to use with the GeoStrategy Engine:

1. Processed files go to `res://data/terrain/`
2. Godot will load `terrain_metadata.json` at runtime
3. Chunks are streamed on-demand by `chunk_streamer.gd`
4. See `docs/GeoStrategy_Engine_SSOT.md` for engine architecture

## License

SRTM data is public domain (NASA/USGS). Processed derivative works should include attribution to the data source.
