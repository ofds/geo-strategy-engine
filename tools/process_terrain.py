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
SRTM_RESOLUTION_M = 30  # Approximate meters per pixel at equator (1 arc-second)
SRTM_NODATA = -32768  # SRTM void value
CHUNK_SIZE_PX = 512
LOD_LEVELS = 5
TILE_OVERLAP_PX = 10  # Overlap zone for blending


class TerrainProcessor:
    """Main terrain processing pipeline."""
    
    def __init__(self, region_config: Dict, output_dir: Path, cache_dir: Path):
        self.region_config = region_config
        self.output_dir = output_dir
        self.cache_dir = cache_dir
        self.bbox = region_config['bounding_box']
        self.max_elevation_m = region_config['max_elevation_m']
        
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
        print(f"{'='*80}\n")
        
        # Step 1: Download SRTM tiles
        print("[1/7] Downloading SRTM tiles...")
        tiles = self._download_tiles()
        
        # Step 2: Merge tiles
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
        
        # Step 7: Generate metadata
        print("\n[7/7] Generating metadata...")
        self._generate_metadata(normalized.shape, chunks_info)
        
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
        """Merge SRTM tiles into a single raster covering the bounding box."""
        # Calculate output dimensions
        lat_min = self.bbox['lat_min']
        lat_max = self.bbox['lat_max']
        lon_min = self.bbox['lon_min']
        lon_max = self.bbox['lon_max']
        
        # Calculate dimensions in pixels
        # Each degree = SRTM_TILE_SIZE pixels (1201 for SRTM3)
        lat_degrees = lat_max - lat_min
        lon_degrees = lon_max - lon_min
        
        # Pixels per degree (SRTM3 has 1201 samples per degree)
        px_per_degree = SRTM_TILE_SIZE - 1  # 1200 pixels span 1 degree (edges overlap)
        
        height_px = int(lat_degrees * px_per_degree)
        width_px = int(lon_degrees * px_per_degree)
        
        print(f"  Output dimensions: {width_px} × {height_px} pixels")
        
        # Initialize output array
        merged = np.zeros((height_px, width_px), dtype=np.int16)
        
        # Place each tile
        for lat, lon, tile_data in tiles:
            if tile_data is None:
                # Fill with zeros (sea level)
                tile_data = np.zeros((SRTM_TILE_SIZE, SRTM_TILE_SIZE), dtype=np.int16)
            
            # Calculate position in output array
            # Note: SRTM Y axis goes from north to south (top to bottom)
            # Image Y axis also goes top to bottom, so lat is inverted
            
            y_offset = int((lat_max - (lat + 1)) * px_per_degree)
            x_offset = int((lon - lon_min) * px_per_degree)
            
            # Handle edge overlaps: use average of overlapping pixels
            tile_h, tile_w = tile_data.shape
            
            # Determine actual region to copy (may be clipped at edges)
            y_start = max(0, y_offset)
            y_end = min(height_px, y_offset + tile_h)
            x_start = max(0, x_offset)
            x_end = min(width_px, x_offset + tile_w)
            
            # Source indices
            src_y_start = y_start - y_offset
            src_y_end = src_y_start + (y_end - y_start)
            src_x_start = x_start - x_offset
            src_x_end = src_x_start + (x_end - x_start)
            
            # Copy tile data
            if src_y_end > src_y_start and src_x_end > src_x_start:
                merged[y_start:y_end, x_start:x_end] = tile_data[src_y_start:src_y_end, src_x_start:src_x_end]
        
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
        """Normalize elevation data to uint16 range [0, 65535]."""
        # Clamp below sea level to 0
        data = np.maximum(data, 0)
        
        # Linear mapping: pixel = elevation_m / max_elevation_m * 65535
        normalized = (data.astype(np.float32) / self.max_elevation_m * 65535.0)
        normalized = np.clip(normalized, 0, 65535).astype(np.uint16)
        
        print(f"  Min elevation: {np.min(data)}m")
        print(f"  Max elevation: {np.max(data)}m")
        print(f"  Normalized range: {np.min(normalized)} - {np.max(normalized)}")
        
        return normalized
    
    def _save_png_16bit(self, data: np.ndarray, path: Path) -> None:
        """Save uint16 array as 16-bit grayscale PNG."""
        # PIL requires mode 'I;16' for 16-bit grayscale
        # Must ensure data is uint16 and in correct byte order
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
    
    def _generate_metadata(self, master_shape: Tuple[int, int], chunks_info: List[Dict]) -> None:
        """Generate terrain_metadata.json."""
        metadata = {
            'region_name': self.region_config['display_name'],
            'bounding_box': self.bbox,
            'resolution_m': SRTM_RESOLUTION_M,
            'max_elevation_m': self.max_elevation_m,
            'chunk_size_px': CHUNK_SIZE_PX,
            'lod_levels': LOD_LEVELS,
            'total_chunks': len(chunks_info),
            'master_heightmap_width': master_shape[1],
            'master_heightmap_height': master_shape[0],
            'chunks': chunks_info,
        }
        
        metadata_path = self.output_dir / "terrain_metadata.json"
        with open(metadata_path, 'w') as f:
            json.dump(metadata, f, indent=2)
        
        print(f"  [OK] Saved: {metadata_path}")


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
    processor = TerrainProcessor(region_config, args.output, args.cache)
    
    try:
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
