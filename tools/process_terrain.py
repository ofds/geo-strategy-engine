#!/usr/bin/env python3
"""
GeoStrategy Engine - Terrain Data Processor

Downloads SRTM3 elevation data, merges tiles, generates LOD levels,
and outputs chunked heightmaps for Godot 4.

Usage:
    python process_terrain.py --region alps_test --regions-config ../config/regions.json --output ../data/terrain/

Requirements: numpy, Pillow (PIL)
"""

import argparse
import gzip
import json
import os
import sys
import tempfile
import time
import urllib.request
import urllib.error
import warnings
from pathlib import Path
from typing import Dict, List, Tuple, Optional
import numpy as np
from PIL import Image


# SRTM tile download URLs (multiple mirror sources)
SRTM_MIRRORS = [
    "https://e4ftl01.cr.usgs.gov/MEASURES/SRTMGL3.003/2000.02.11/",
    "https://srtm.csi.cgiar.org/wp-content/uploads/files/srtm_5x5/TIFF/",
]

# Constants
SRTM_TILE_SIZE = 3601  # SRTM1: 1 arc-second resolution, 1°×1° tile (AWS data)
SRTM1_RESOLUTION_M = 30  # Meters per pixel (1 arc-second)
SRTM3_RESOLUTION_M = 90  # Effective meters per pixel when downsampling SRTM1 by 3×
SRTM_NODATA = -32768  # SRTM void value
CHUNK_SIZE_PX = 512
LOD_LEVELS = 5
TILE_OVERLAP_PX = 10  # Overlap zone for blending
SEA_LEVEL_UINT16 = 1000  # Sea level (0m) maps to this in PNG so water is distinguishable

# Water color for overview (land colors come from elevation_palette.png)
COLOR_WATER_OVERVIEW = (38, 64, 115)


def load_elevation_palette(path: Path) -> Optional[np.ndarray]:
    """Load elevation_palette.png (256×1 or 1×256 RGB) and return (256, 3) float 0-1, or None if missing."""
    if not path.exists():
        return None
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            img = Image.open(path)
        arr = np.array(img)
        if arr.ndim == 2:
            arr = np.stack([arr, arr, arr], axis=-1)
        h, w = arr.shape[0], arr.shape[1]
        if h == 1 and w >= 256:
            row = arr[0, :256, :3].astype(np.float64) / 255.0
        elif w == 1 and h >= 256:
            row = arr[:256, 0, :3].astype(np.float64) / 255.0
        else:
            return None
        return row
    except Exception:
        return None


def sample_elevation_color(elevation_m: np.ndarray, palette: np.ndarray, max_elev: float = 10000.0) -> np.ndarray:
    """Sample elevation palette at given elevations (meters). Returns (N, 3) uint8 RGB.
    Matches shader: t = clamp(elev/max_elev, 0, 1), sample at (t, 0.5). Linear interpolation along palette."""
    t = np.clip(elevation_m.astype(np.float64) / max_elev, 0.0, 1.0)
    n = palette.shape[0]
    idx_float = t * (n - 1)
    idx0 = np.clip(np.floor(idx_float).astype(int), 0, n - 1)
    idx1 = np.clip(idx0 + 1, 0, n - 1)
    frac = idx_float - np.floor(idx_float)
    rgb_float = (1.0 - frac)[:, np.newaxis] * palette[idx0] + frac[:, np.newaxis] * palette[idx1]
    return np.clip(np.round(rgb_float * 255.0), 0, 255).astype(np.uint8)


class TerrainProcessor:
    """Main terrain processing pipeline."""
    
    def __init__(self, region_config: Dict, output_dir: Path, cache_dir: Path, skip_cells: bool = False):
        self.region_config = region_config
        self.output_dir = output_dir
        self.cache_dir = cache_dir
        self.skip_cells = skip_cells
        self.bbox = region_config['bounding_box']
        self.max_elevation_m = region_config['max_elevation_m']
        # SRTM3: use SRTM1 tiles, downsample each tile during merge (90m grid, ~5.5GB not 50GB)
        self.resolution_key = region_config.get('resolution', 'srtm1')
        self.downsample_3x = (self.resolution_key == 'srtm3')
        # Force stream merge for large regions when resolution is srtm3 (safety)
        _lat = int(np.ceil(self.bbox['lat_max'])) - int(np.floor(self.bbox['lat_min']))
        _lon = int(np.ceil(self.bbox['lon_max'])) - int(np.floor(self.bbox['lon_min']))
        if (_lat * _lon) > 800 and self.resolution_key == 'srtm3':
            self.downsample_3x = True
        self.resolution_m = SRTM3_RESOLUTION_M if self.downsample_3x else SRTM1_RESOLUTION_M
        
        # Ensure directories exist
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        
        # Statistics
        self.stats = {
            'tiles_downloaded': 0,
            'tiles_cached': 0,
            'voids_filled': 0,
        }
    
    def run(self) -> None:
        """Execute the full terrain processing pipeline."""
        start_time = time.time()
        
        print(f"\n{'='*80}")
        print(f"GeoStrategy Terrain Processor")
        print(f"Region: {self.region_config['display_name']}")
        print(f"Resolution: {self.resolution_key} ({self.resolution_m}m) — {'stream merge (one tile at a time)' if self.downsample_3x else 'full load then merge'}")
        print(f"{'='*80}\n")
        
        # Step 1–2: For SRTM3, download+merge in one pass (one tile in RAM at a time). For SRTM1, download then merge.
        if self.downsample_3x:
            print("[1/2] Download & merge (90m, one tile at a time)...")
            merged = self._download_and_merge_srtm3()
        else:
            print("[1/7] Downloading SRTM tiles...")
            tiles = self._download_tiles()
            print("\n[2/7] Merging tiles into master heightmap...")
            merged = self._merge_tiles(tiles)
        
        # Step 3: Fill voids
        print("\n[3/7] Filling data voids...")
        merged = self._fill_voids(merged)
        
        # Step 4: Normalize to uint16
        print("\n[4/7] Normalizing to 16-bit range...")
        normalized = self._normalize(merged)
        
        # Step 5: Save master heightmap
        print("\n[5/7] Saving master heightmap...")
        master_path = self.output_dir / "master_heightmap.png"
        self._save_png_16bit(normalized, master_path)
        print(f"  [OK] Saved: {master_path}")
        print(f"  [OK] Dimensions: {normalized.shape[1]} × {normalized.shape[0]} pixels")
        
        # Step 6: Generate LOD levels and chunk
        print("\n[6/7] Generating LOD levels and chunking...")
        chunks_info = self._generate_lods_and_chunk(normalized)
        
        # Step 6b: Generate continental overview texture (while master is still in memory)
        print("\n[6b/7] Generating continental overview texture...")
        overview_info = self._generate_overview_texture(normalized)
        
        # Step 7: Generate metadata
        print("\n[7/7] Generating metadata...")
        self._generate_metadata(normalized.shape, chunks_info, overview_info)
        
        # Step 8: Generate cell textures (Phase 1A) — optional
        if not getattr(self, 'skip_cells', False):
            print("\n[8/8] Generating cell ID textures (LOD 0–2)...")
            self._generate_cell_textures()
        else:
            print("\n[8/8] Skipping cell texture generation (--skip-cells).")
        
        # Summary
        elapsed = time.time() - start_time
        print(f"\n{'='*80}")
        print(f"Processing Complete!")
        print(f"{'='*80}")
        print(f"Region: {self.region_config['display_name']}")
        print(f"Master heightmap: {normalized.shape[1]} × {normalized.shape[0]} pixels")
        print(f"Bounding box: {self.bbox['lat_min']}°N - {self.bbox['lat_max']}°N, "
              f"{self.bbox['lon_min']}°E - {self.bbox['lon_max']}°E")
        print(f"\nLOD Chunk Counts:")
        for lod in range(LOD_LEVELS):
            count = sum(1 for c in chunks_info if c['lod'] == lod)
            print(f"  LOD {lod}: {count:4d} chunks")
        print(f"\nTotal chunks: {len(chunks_info)}")
        print(f"Total processing time: {elapsed:.1f} seconds")
        print(f"Output directory: {self.output_dir}")
        print(f"\n{'='*80}\n")
    
    def run_overview_only(self) -> None:
        """Load existing master_heightmap.png, generate overview texture, and update terrain_metadata.json."""
        master_path = self.output_dir / "master_heightmap.png"
        if not master_path.exists():
            print(f"Error: Master heightmap not found: {master_path}")
            sys.exit(1)
        print("Loading master heightmap...")
        # Allow large master heightmaps (e.g. Europe 68k×43k)
        old_max = getattr(Image, 'MAX_IMAGE_PIXELS', None)
        try:
            Image.MAX_IMAGE_PIXELS = None
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", DeprecationWarning)
                img = Image.open(master_path)
        finally:
            if old_max is not None:
                Image.MAX_IMAGE_PIXELS = old_max
        master = np.array(img)
        if master.ndim != 2:
            master = master[:, :, 0]
        master = master.astype(np.uint16)
        print("Generating continental overview texture...")
        overview_info = self._generate_overview_texture(master)
        metadata_path = self.output_dir / "terrain_metadata.json"
        if metadata_path.exists():
            with open(metadata_path, 'r') as f:
                metadata = json.load(f)
            metadata['overview_texture'] = overview_info['overview_texture']
            metadata['overview_width_px'] = overview_info['overview_width_px']
            metadata['overview_height_px'] = overview_info['overview_height_px']
            metadata['overview_world_width_m'] = overview_info['overview_world_width_m']
            metadata['overview_world_height_m'] = overview_info['overview_world_height_m']
            with open(metadata_path, 'w') as f:
                json.dump(metadata, f, indent=2)
            print(f"  [OK] Updated: {metadata_path}")
        else:
            print("  [WARN] No terrain_metadata.json found; overview texture saved but metadata not updated.")
    
    def _download_tiles(self) -> List[Tuple[int, int, np.ndarray]]:
        """Download all SRTM tiles covering the bounding box."""
        lat_min = int(np.floor(self.bbox['lat_min']))
        lat_max = int(np.ceil(self.bbox['lat_max']))
        lon_min = int(np.floor(self.bbox['lon_min']))
        lon_max = int(np.ceil(self.bbox['lon_max']))
        
        tiles = []
        total_tiles = (lat_max - lat_min) * (lon_max - lon_min)
        current_tile = 0
        
        for lat in range(lat_min, lat_max):
            for lon in range(lon_min, lon_max):
                current_tile += 1
                print(f"  [{current_tile}/{total_tiles}] Processing tile ({lat}°N, {lon}°E)...", end=' ')
                
                tile_data = self._get_tile(lat, lon)
                tiles.append((lat, lon, tile_data))
                
                if tile_data is not None:
                    print("[OK]")
                else:
                    print("[SKIP] (ocean/missing)")
        
        print(f"\n  Downloaded: {self.stats['tiles_downloaded']} tiles")
        print(f"  From cache: {self.stats['tiles_cached']} tiles")
        
        return tiles
    
    def _download_and_merge_srtm3(self) -> np.ndarray:
        """Download tiles and merge at 90m in one pass. Only one tile in RAM at a time (~5.5GB total)."""
        lat_min = self.bbox['lat_min']
        lat_max = self.bbox['lat_max']
        lon_min = self.bbox['lon_min']
        lon_max = self.bbox['lon_max']
        lat_min_i = int(np.floor(lat_min))
        lat_max_i = int(np.ceil(lat_max))
        lon_min_i = int(np.floor(lon_min))
        lon_max_i = int(np.ceil(lon_max))
        lat_degrees = lat_max - lat_min
        lon_degrees = lon_max - lon_min
        
        px_per_degree = 1200
        height_px = int(lat_degrees * px_per_degree)
        width_px = int(lon_degrees * px_per_degree)
        tile_out_h, tile_out_w = 1201, 1201
        
        total_tiles = (lat_max_i - lat_min_i) * (lon_max_i - lon_min_i)
        print(f"  Output dimensions: {width_px} × {height_px} pixels (90m)")
        merged = np.zeros((height_px, width_px), dtype=np.int16)
        
        current = 0
        for lat in range(lat_min_i, lat_max_i):
            for lon in range(lon_min_i, lon_max_i):
                current += 1
                if current % 250 == 0 or current == 1:
                    print(f"  Progress: {current}/{total_tiles} tiles...", flush=True)
                
                tile_data = self._get_tile(lat, lon)
                if tile_data is None:
                    tile_place = np.zeros((tile_out_h, tile_out_w), dtype=np.int16)
                else:
                    tile_place = tile_data[::3, ::3].astype(np.int16)
                    del tile_data  # free before next tile load
                
                y_offset = int((lat_max - (lat + 1)) * px_per_degree)
                x_offset = int((lon - lon_min) * px_per_degree)
                y_start = max(0, y_offset)
                y_end = min(height_px, y_offset + tile_out_h)
                x_start = max(0, x_offset)
                x_end = min(width_px, x_offset + tile_out_w)
                src_y_start = y_start - y_offset
                src_y_end = src_y_start + (y_end - y_start)
                src_x_start = x_start - x_offset
                src_x_end = src_x_start + (x_end - x_start)
                if src_y_end > src_y_start and src_x_end > src_x_start:
                    merged[y_start:y_end, x_start:x_end] = tile_place[src_y_start:src_y_end, src_x_start:src_x_end]
        
        print(f"  [OK] Merged {total_tiles} tiles")
        print(f"  Downloaded: {self.stats['tiles_downloaded']}, from cache: {self.stats['tiles_cached']}")
        return merged
    
    def _get_tile(self, lat: int, lon: int) -> Optional[np.ndarray]:
        """Get a single SRTM tile, from cache or download."""
        # Generate filename (SRTM tiles are named by SW corner)
        lat_str = f"{'N' if lat >= 0 else 'S'}{abs(lat):02d}"
        lon_str = f"{'E' if lon >= 0 else 'W'}{abs(lon):03d}"
        filename = f"{lat_str}{lon_str}.hgt"
        
        cache_path = self.cache_dir / filename
        
        # Check cache first
        if cache_path.exists():
            self.stats['tiles_cached'] += 1
            return self._read_hgt(cache_path)
        
        # Try to download
        tile_data = self._download_hgt(lat, lon, filename, cache_path)
        if tile_data is not None:
            self.stats['tiles_downloaded'] += 1
        
        return tile_data
    
    def _download_hgt(self, lat: int, lon: int, filename: str, cache_path: Path) -> Optional[np.ndarray]:
        """Download a .hgt file from AWS S3 SRTM mirror (no auth required)."""
        lat_str = f"{'N' if lat >= 0 else 'S'}{abs(lat):02d}"
        lon_str = f"{'E' if lon >= 0 else 'W'}{abs(lon):03d}"
        
        # AWS S3 bucket structure: https://elevation-tiles-prod.s3.amazonaws.com/skadi/{lat_band}/{filename}
        # Files are gzipped: N45E006.hgt.gz
        lat_band = lat_str
        hgt_filename = f"{lat_str}{lon_str}.hgt.gz"
        url = f"https://elevation-tiles-prod.s3.amazonaws.com/skadi/{lat_band}/{hgt_filename}"
        
        try:
            print(f"Downloading...", end=' ', flush=True)
            
            # Download to a temporary gzipped file
            with tempfile.NamedTemporaryFile(delete=False, suffix='.hgt.gz') as tmp_gz:
                tmp_path = tmp_gz.name
                urllib.request.urlretrieve(url, tmp_path)
            
            # Decompress and save to cache (close tmp file before deleting)
            with gzip.open(tmp_path, 'rb') as gz_file:
                with open(cache_path, 'wb') as hgt_file:
                    hgt_file.write(gz_file.read())
            
            # Clean up temp file (now it's closed)
            try:
                Path(tmp_path).unlink()
            except:
                pass  # Ignore cleanup errors
            
            # Read the decompressed file
            return self._read_hgt(cache_path)
            
        except urllib.error.HTTPError as e:
            if e.code == 404:
                # Tile doesn't exist (likely ocean)
                return None
            else:
                print(f"HTTP Error {e.code}")
                return None
        except Exception as e:
            print(f"Error: {e}")
            return None
    
    
    def _read_hgt(self, path: Path) -> np.ndarray:
        """Read a .hgt file (big-endian int16, 1201×1201)."""
        data = np.fromfile(path, dtype='>i2')  # big-endian signed int16
        data = data.reshape((SRTM_TILE_SIZE, SRTM_TILE_SIZE))
        return data
    
    def _merge_tiles(self, tiles: List[Tuple[int, int, np.ndarray]]) -> np.ndarray:
        """Merge SRTM tiles into a single raster. For SRTM3, allocate 90m grid and downsample tiles during merge (avoids ~50GB allocation)."""
        lat_min = self.bbox['lat_min']
        lat_max = self.bbox['lat_max']
        lon_min = self.bbox['lon_min']
        lon_max = self.bbox['lon_max']
        lat_degrees = lat_max - lat_min
        lon_degrees = lon_max - lon_min

        if self.downsample_3x:
            # SRTM3: output at 90m — 1200 pixels per degree (never allocate full 30m grid)
            px_per_degree = 1200  # 90m ≈ 1200 px/degree
            height_px = int(lat_degrees * px_per_degree)
            width_px = int(lon_degrees * px_per_degree)
            tile_out_h, tile_out_w = 1201, 1201  # one degree at 90m: 1201 samples (1 pixel overlap)
        else:
            # SRTM1: output at 30m — 3600 pixels per degree
            px_per_degree = SRTM_TILE_SIZE - 1  # 3600
            height_px = int(lat_degrees * px_per_degree)
            width_px = int(lon_degrees * px_per_degree)
            tile_out_h, tile_out_w = SRTM_TILE_SIZE, SRTM_TILE_SIZE

        print(f"  Output dimensions: {width_px} × {height_px} pixels ({'90m' if self.downsample_3x else '30m'})")

        merged = np.zeros((height_px, width_px), dtype=np.int16)

        total = len(tiles)
        for i, (lat, lon, tile_data) in enumerate(tiles):
            if (i + 1) % 250 == 0 or i == 0:
                print(f"  Merge progress: {i + 1}/{total} tiles...", flush=True)
            if self.downsample_3x:
                # Downsample tile before placing: 3601×3601 → 1201×1201 (stride 3)
                if tile_data is None:
                    tile_place = np.zeros((tile_out_h, tile_out_w), dtype=np.int16)
                else:
                    tile_place = tile_data[::3, ::3].astype(np.int16)  # 1201×1201
            else:
                if tile_data is None:
                    tile_place = np.zeros((SRTM_TILE_SIZE, SRTM_TILE_SIZE), dtype=np.int16)
                else:
                    tile_place = tile_data

            # Position in output (Y: north to south)
            y_offset = int((lat_max - (lat + 1)) * px_per_degree)
            x_offset = int((lon - lon_min) * px_per_degree)

            y_start = max(0, y_offset)
            y_end = min(height_px, y_offset + tile_out_h)
            x_start = max(0, x_offset)
            x_end = min(width_px, x_offset + tile_out_w)

            src_y_start = y_start - y_offset
            src_y_end = src_y_start + (y_end - y_start)
            src_x_start = x_start - x_offset
            src_x_end = src_x_start + (x_end - x_start)

            if src_y_end > src_y_start and src_x_end > src_x_start:
                merged[y_start:y_end, x_start:x_end] = tile_place[src_y_start:src_y_end, src_x_start:src_x_end]

        print(f"  [OK] Merged {len(tiles)} tiles")
        return merged
    
    def _fill_voids(self, data: np.ndarray) -> np.ndarray:
        """Fill SRTM data voids using nearest-neighbor interpolation + Gaussian blur."""
        void_mask = (data == SRTM_NODATA)
        num_voids = np.sum(void_mask)
        
        if num_voids == 0:
            print("  [OK] No voids to fill")
            return data
        
        print(f"  Found {num_voids} void pixels ({100 * num_voids / data.size:.2f}%)")
        
        # Fill voids with nearest valid neighbor (iterative approach)
        filled = self._simple_void_fill(data.copy(), void_mask)
        
        # Apply Gaussian blur to smoothed filled regions
        filled = self._smooth_filled_regions(filled, void_mask)
        
        print(f"  [OK] Filled {num_voids} void pixels")
        self.stats['voids_filled'] = num_voids
        
        return filled
    
    def _simple_void_fill(self, data: np.ndarray, void_mask: np.ndarray) -> np.ndarray:
        """Simple iterative void filling from neighboring valid pixels."""
        filled = data.copy()
        remaining_voids = void_mask.copy()
        
        # Iterate until all voids filled (or max iterations)
        max_iterations = 100
        for iteration in range(max_iterations):
            if not np.any(remaining_voids):
                break
            
            # For each void pixel, check if any neighbor is valid
            h, w = filled.shape
            new_filled = filled.copy()
            
            # Find void pixels
            void_coords = np.argwhere(remaining_voids)
            
            for y, x in void_coords:
                # Check 8 neighbors
                neighbors = []
                for dy in [-1, 0, 1]:
                    for dx in [-1, 0, 1]:
                        if dy == 0 and dx == 0:
                            continue
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < h and 0 <= nx < w and not remaining_voids[ny, nx]:
                            neighbors.append(filled[ny, nx])
                
                if neighbors:
                    # Average of valid neighbors
                    new_filled[y, x] = int(np.mean(neighbors))
                    remaining_voids[y, x] = False
            
            filled = new_filled
            
            if iteration % 10 == 0 and iteration > 0:
                remaining = np.sum(remaining_voids)
                print(f"    Iteration {iteration}: {remaining} voids remaining")
        
        return filled
    
    def _smooth_filled_regions(self, data: np.ndarray, void_mask: np.ndarray) -> np.ndarray:
        """Apply 3×3 Gaussian blur to previously void regions."""
        # Simple 3×3 Gaussian kernel approximation
        kernel = np.array([[1, 2, 1],
                          [2, 4, 2],
                          [1, 2, 1]], dtype=np.float32) / 16.0
        
        smoothed = data.copy().astype(np.float32)
        h, w = data.shape
        
        # Apply blur only to void regions
        void_coords = np.argwhere(void_mask)
        
        for y, x in void_coords:
            # Apply kernel
            result = 0.0
            weight_sum = 0.0
            
            for ky in range(-1, 2):
                for kx in range(-1, 2):
                    ny, nx = y + ky, x + kx
                    if 0 <= ny < h and 0 <= nx < w:
                        weight = kernel[ky + 1, kx + 1]
                        result += smoothed[ny, nx] * weight
                        weight_sum += weight
            
            if weight_sum > 0:
                smoothed[y, x] = result / weight_sum
        
        return smoothed.astype(np.int16)
    
    def _normalize(self, data: np.ndarray) -> np.ndarray:
        """Normalize elevation data to uint16. Sea level (0m) maps to SEA_LEVEL_UINT16 for water detection."""
        # Clamp below sea level to 0 (missing/ocean tiles already 0)
        data = np.maximum(data, 0)
        
        # Map 0m -> SEA_LEVEL_UINT16, max_elevation_m -> 65535 so ocean is low but non-zero
        scale = (65535.0 - SEA_LEVEL_UINT16) / float(self.max_elevation_m)
        normalized = (data.astype(np.float32) * scale + SEA_LEVEL_UINT16)
        normalized = np.clip(normalized, 0, 65535).astype(np.uint16)
        
        print(f"  Min elevation: {np.min(data)}m")
        print(f"  Max elevation: {np.max(data)}m")
        print(f"  Normalized range: {np.min(normalized)} - {np.max(normalized)} (sea level -> {SEA_LEVEL_UINT16})")
        
        return normalized
    
    def _save_png_16bit(self, data: np.ndarray, path: Path) -> None:
        """Save uint16 array as 16-bit grayscale PNG."""
        # PIL 16-bit grayscale (mode 'I;16'); suppress Pillow 13 deprecation for mode=
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            img = Image.fromarray(data, mode='I;16')
        img.save(path)
    
    def _generate_lods_and_chunk(self, master: np.ndarray) -> List[Dict]:
        """Generate LOD levels and chunk each level."""
        chunks_info = []
        
        current_lod = master
        
        for lod in range(LOD_LEVELS):
            print(f"\n  LOD {lod}: {current_lod.shape[1]} × {current_lod.shape[0]} pixels")
            
            # Chunk this LOD level
            lod_dir = self.output_dir / "chunks" / f"lod{lod}"
            lod_dir.mkdir(parents=True, exist_ok=True)
            
            lod_chunks = self._chunk_lod(current_lod, lod, lod_dir)
            chunks_info.extend(lod_chunks)
            
            print(f"    [OK] Generated {len(lod_chunks)} chunks")
            
            # Downsample for next LOD (box filter: average 2×2 blocks)
            if lod < LOD_LEVELS - 1:
                current_lod = self._downsample(current_lod)
        
        return chunks_info
    
    def _chunk_lod(self, data: np.ndarray, lod: int, output_dir: Path) -> List[Dict]:
        """Chunk a single LOD level into 512×512 tiles."""
        h, w = data.shape
        chunks = []
        
        # Calculate number of chunks (with padding if necessary)
        num_chunks_y = (h + CHUNK_SIZE_PX - 1) // CHUNK_SIZE_PX
        num_chunks_x = (w + CHUNK_SIZE_PX - 1) // CHUNK_SIZE_PX
        
        for chunk_y in range(num_chunks_y):
            for chunk_x in range(num_chunks_x):
                # Extract chunk region
                y_start = chunk_y * CHUNK_SIZE_PX
                y_end = min(y_start + CHUNK_SIZE_PX, h)
                x_start = chunk_x * CHUNK_SIZE_PX
                x_end = min(x_start + CHUNK_SIZE_PX, w)
                
                chunk_data = data[y_start:y_end, x_start:x_end]
                
                # Pad if necessary
                if chunk_data.shape[0] < CHUNK_SIZE_PX or chunk_data.shape[1] < CHUNK_SIZE_PX:
                    padded = np.zeros((CHUNK_SIZE_PX, CHUNK_SIZE_PX), dtype=data.dtype)
                    padded[:chunk_data.shape[0], :chunk_data.shape[1]] = chunk_data
                    chunk_data = padded
                
                # Save chunk
                chunk_filename = f"chunk_{chunk_x}_{chunk_y}.png"
                chunk_path = output_dir / chunk_filename
                self._save_png_16bit(chunk_data, chunk_path)
                
                # Record chunk info
                chunks.append({
                    'lod': lod,
                    'x': chunk_x,
                    'y': chunk_y,
                    'path': f"chunks/lod{lod}/{chunk_filename}",
                })
        
        return chunks
    
    def _downsample(self, data: np.ndarray) -> np.ndarray:
        """Downsample by 2× using box filter (average of 2×2 blocks)."""
        h, w = data.shape
        
        # Ensure dimensions are even (pad if necessary)
        if h % 2 == 1:
            data = np.vstack([data, data[-1:, :]])
            h += 1
        if w % 2 == 1:
            data = np.hstack([data, data[:, -1:]])
            w += 1
        
        # Reshape and average
        downsampled = data.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3)).astype(data.dtype)
        
        return downsampled
    
    def _generate_overview_texture(self, master: np.ndarray) -> Optional[Dict]:
        """Generate a continental overview RGB texture from the master heightmap.
        Replicates terrain shader elevation coloring (water, green valleys, rock, snow).
        Returns overview info dict for metadata, or None if skipped.
        """
        master_height, master_width = master.shape
        overview_width = 4096
        aspect = master_height / float(master_width)
        overview_height = int(round(overview_width * aspect))
        
        # Stride-sample the master heightmap to overview size
        step_x = master_width / float(overview_width)
        step_y = master_height / float(overview_height)
        indices_x = np.minimum(
            np.round(np.arange(overview_width) * step_x).astype(int),
            master_width - 1
        )
        indices_y = np.minimum(
            np.round(np.arange(overview_height) * step_y).astype(int),
            master_height - 1
        )
        overview_elev = master[np.ix_(indices_y, indices_x)].astype(np.float32)
        
        # Convert uint16 to meters (same formula as terrain_loader.gd)
        elev_m = (overview_elev - SEA_LEVEL_UINT16) / (65535.0 - SEA_LEVEL_UINT16) * self.max_elevation_m
        elev_m = np.clip(elev_m, 0.0, float(self.max_elevation_m))
        
        # World dimensions (same as chunk grid) for metadata
        grid_w = (master_width + CHUNK_SIZE_PX - 1) // CHUNK_SIZE_PX
        grid_h = (master_height + CHUNK_SIZE_PX - 1) // CHUNK_SIZE_PX
        overview_world_width_m = grid_w * CHUNK_SIZE_PX * self.resolution_m
        overview_world_height_m = grid_h * CHUNK_SIZE_PX * self.resolution_m

        # Elevation colors from shared palette (single source of truth with shader)
        palette = load_elevation_palette(self.output_dir / "elevation_palette.png")
        max_elev = float(self.max_elevation_m)
        rgb = np.zeros((overview_height, overview_width, 3), dtype=np.uint8)
        water_mask = elev_m < 5  # Match shader WATER_ELEVATION_M = 5.0
        rgb[water_mask] = COLOR_WATER_OVERVIEW

        land = ~water_mask
        if palette is not None and np.any(land):
            land_elev = elev_m[land]
            land_rgb = sample_elevation_color(land_elev, palette, max_elev)
            rgb[land] = land_rgb
        else:
            if palette is None:
                print("  [WARN] elevation_palette.png not found; run tools/generate_elevation_palette.py first. Using fallback green.")
            rgb[land] = (46, 82, 31)  # Fallback lowland green

        out_path = self.output_dir / "overview_texture.png"
        img = Image.fromarray(rgb)
        img.save(out_path)

        print(f"  [OK] Saved: {out_path} ({overview_width}×{overview_height})")
        return {
            'overview_texture': 'overview_texture.png',
            'overview_width_px': overview_width,
            'overview_height_px': overview_height,
            'overview_world_width_m': int(overview_world_width_m),
            'overview_world_height_m': int(overview_world_height_m),
        }
    
    def _generate_metadata(self, master_shape: Tuple[int, int], chunks_info: List[Dict], overview_info: Optional[Dict] = None) -> None:
        """Generate terrain_metadata.json."""
        metadata = {
            'region_name': self.region_config['display_name'],
            'bounding_box': self.bbox,
            'resolution_m': self.resolution_m,
            'max_elevation_m': self.max_elevation_m,
            'chunk_size_px': CHUNK_SIZE_PX,
            'lod_levels': LOD_LEVELS,
            'total_chunks': len(chunks_info),
            'master_heightmap_width': master_shape[1],
            'master_heightmap_height': master_shape[0],
            'chunks': chunks_info,
        }
        if overview_info:
            metadata['overview_texture'] = overview_info['overview_texture']
            metadata['overview_width_px'] = overview_info['overview_width_px']
            metadata['overview_height_px'] = overview_info['overview_height_px']
            metadata['overview_world_width_m'] = overview_info['overview_world_width_m']
            metadata['overview_world_height_m'] = overview_info['overview_world_height_m']
        
        metadata_path = self.output_dir / "terrain_metadata.json"
        with open(metadata_path, 'w') as f:
            json.dump(metadata, f, indent=2)
        
        print(f"  [OK] Saved: {metadata_path}")

    def _generate_cell_textures(self) -> None:
        """Phase 1A: Generate cell ID textures and cell_metadata.json (LOD 0–2)."""
        try:
            from generate_cell_textures import run_generation
        except ImportError:
            # Run from repo root or tools/
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            from generate_cell_textures import run_generation
        metadata_path = self.output_dir / "terrain_metadata.json"
        total_chunks, total_cells, elapsed = run_generation(
            metadata_path,
            self.output_dir,
            lods=[0, 1, 2],
            workers=1,
            verify=False,
            debug_viz=False,
        )
        print(f"  [OK] Generated {total_chunks} cell textures, {total_cells} cells, in {elapsed:.1f}s")
        print(f"  [OK] Saved: {self.output_dir / 'cell_metadata.json'}")


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='GeoStrategy Terrain Processor - Download and process SRTM elevation data',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    
    parser.add_argument(
        '--region',
        type=str,
        required=True,
        help='Region name from regions.json (e.g., alps_test)',
    )
    
    parser.add_argument(
        '--regions-config',
        type=Path,
        default=Path(__file__).parent.parent / 'config' / 'regions.json',
        help='Path to regions.json config file (default: ../config/regions.json)',
    )
    
    parser.add_argument(
        '--output',
        type=Path,
        default=Path(__file__).parent.parent / 'data' / 'terrain',
        help='Output directory for processed terrain data (default: ../data/terrain/)',
    )
    
    parser.add_argument(
        '--cache',
        type=Path,
        default=Path(__file__).parent / 'cache',
        help='Cache directory for downloaded SRTM tiles (default: ./cache/)',
    )
    
    parser.add_argument(
        '--overview-only',
        action='store_true',
        help='Only generate overview texture from existing master_heightmap.png and update metadata (skip download/merge/chunk).',
    )
    parser.add_argument(
        '--skip-cells',
        action='store_true',
        help='Skip Phase 1A cell texture generation (chunk_*_cells.png and cell_metadata.json).',
    )
    
    args = parser.parse_args()
    
    # Load regions config
    if not args.regions_config.exists():
        print(f"Error: Regions config not found: {args.regions_config}")
        print(f"Expected location: {args.regions_config.absolute()}")
        sys.exit(1)
    
    with open(args.regions_config, 'r') as f:
        regions_data = json.load(f)
    
    if args.region not in regions_data['regions']:
        print(f"Error: Region '{args.region}' not found in config")
        print(f"Available regions: {', '.join(regions_data['regions'].keys())}")
        sys.exit(1)
    
    region_config = regions_data['regions'][args.region]
    
    # Run processor
    processor = TerrainProcessor(region_config, args.output, args.cache, skip_cells=args.skip_cells)
    
    try:
        if args.overview_only:
            processor.run_overview_only()
        else:
            processor.run()
    except KeyboardInterrupt:
        print("\n\nProcessing interrupted by user.")
        sys.exit(1)
    except Exception as e:
        print(f"\n\nError during processing: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
