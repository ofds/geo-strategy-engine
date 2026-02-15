#!/usr/bin/env python3
"""
Generate synthetic SRTM tiles for testing the terrain processor.

This script creates realistic-looking elevation data for the Alps test region
without requiring actual SRTM downloads.

Usage:
    python generate_test_data.py --output ./cache/
"""

import argparse
import numpy as np
from pathlib import Path


def generate_synthetic_tile(lat: int, lon: int, region: str = 'alps') -> np.ndarray:
    """Generate a synthetic 1201×1201 SRTM tile with realistic elevation patterns."""
    size = 1201
    
    # Create base elevation using multiple noise layers
    np.random.seed(lat * 1000 + lon)  # Deterministic per tile
    
    tile = np.zeros((size, size), dtype=np.int16)
    
    if region == 'alps':
        # Alps: high mountains with valleys
        # Base elevation depends on location
        base_elevation = 500
        
        # Central Alps are higher
        if 46 <= lat <= 47 and 7 <= lon <= 9:
            base_elevation = 2000
        elif 45 <= lat <= 47 and 6 <= lon <= 10:
            base_elevation = 1200
        
        # Add large-scale terrain features
        y, x = np.meshgrid(np.linspace(0, 1, size), np.linspace(0, 1, size), indexing='ij')
        
        # Mountain ridges (high frequency)
        ridges = np.sin(x * 8 + lat) * np.cos(y * 6 + lon) * 800
        
        # Valleys (lower frequency)
        valleys = np.sin(x * 3 + lon * 0.5) * np.sin(y * 2 + lat * 0.7) * -400
        
        # Random noise for texture
        noise = np.random.randn(size, size) * 50
        
        # Combine
        tile = base_elevation + ridges + valleys + noise
        
        # Add some peaks
        num_peaks = np.random.randint(3, 10)
        for _ in range(num_peaks):
            peak_y = np.random.randint(0, size)
            peak_x = np.random.randint(0, size)
            peak_height = np.random.randint(500, 1500)
            peak_radius = np.random.randint(50, 200)
            
            # Gaussian peak
            yy, xx = np.ogrid[:size, :size]
            dist_sq = (yy - peak_y)**2 + (xx - peak_x)**2
            peak = peak_height * np.exp(-dist_sq / (2 * peak_radius**2))
            tile += peak.astype(np.int16)
        
        # Ensure reasonable range
        tile = np.clip(tile, 200, 4800)
    
    else:
        # Generic terrain
        tile = np.random.randint(0, 2000, (size, size), dtype=np.int16)
    
    return tile.astype(np.int16)


def save_hgt_tile(data: np.ndarray, path: Path) -> None:
    """Save tile as .hgt file (big-endian int16)."""
    # Convert to big-endian and save
    data_be = data.astype('>i2')  # big-endian signed int16
    data_be.tofile(path)


def main():
    parser = argparse.ArgumentParser(
        description='Generate synthetic SRTM test data for the Alps region'
    )
    parser.add_argument(
        '--output',
        type=Path,
        default=Path(__file__).parent / 'cache',
        help='Output directory for .hgt tiles (default: ./cache/)'
    )
    parser.add_argument(
        '--region',
        type=str,
        default='alps',
        choices=['alps', 'generic'],
        help='Region type for terrain generation'
    )
    
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    
    print("Generating synthetic SRTM tiles for testing...")
    print(f"Output directory: {args.output}")
    
    # Alps test region: 45.5°-48°N, 6°-10.5°E
    # Generate tiles for integer degree boundaries
    lat_range = range(45, 49)  # 45, 46, 47, 48
    lon_range = range(6, 11)   # 6, 7, 8, 9, 10
    
    tiles_generated = 0
    
    for lat in lat_range:
        for lon in lon_range:
            # Generate filename
            lat_str = f"N{lat:02d}"
            lon_str = f"E{lon:03d}"
            filename = f"{lat_str}{lon_str}.hgt"
            filepath = args.output / filename
            
            # Generate synthetic data
            tile_data = generate_synthetic_tile(lat, lon, args.region)
            
            # Save
            save_hgt_tile(tile_data, filepath)
            tiles_generated += 1
            
            print(f"  [OK] Generated {filename} (elev range: {tile_data.min()}m - {tile_data.max()}m)")
    
    print(f"\n[OK] Generated {tiles_generated} synthetic tiles")
    print(f"[OK] Ready to run: python process_terrain.py --region alps_test --cache {args.output}")


if __name__ == '__main__':
    main()
