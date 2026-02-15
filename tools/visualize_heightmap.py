#!/usr/bin/env python3
"""
Quick visual check of master heightmap - saves a thumbnail for inspection.
"""

from PIL import Image
import numpy as np
from pathlib import Path

# Load master heightmap
terrain_path = Path(__file__).parent.parent / 'data' / 'terrain' / 'master_heightmap.png'

print(f"Loading {terrain_path}...")
img = Image.open(terrain_path)
data = np.array(img)

print(f"Size: {data.shape[1]} x {data.shape[0]} pixels")
print(f"Value range: {data.min()} - {data.max()}")
print(f"Mean: {data.mean():.1f}, Std: {data.std():.1f}")

# Normalize to 0-255 for visual inspection
normalized = ((data - data.min()) / (data.max() - data.min()) * 255).astype(np.uint8)

# Create thumbnail
thumbnail = Image.fromarray(normalized, mode='L')
thumbnail.thumbnail((1600, 900), Image.Resampling.LANCZOS)

# Save
output_path = Path(__file__).parent / 'master_heightmap_preview.png'
thumbnail.save(output_path)

print(f"\nSaved preview to: {output_path}")
print(f"Preview size: {thumbnail.size}")
print("\nOpen the preview image to verify terrain features:")
print("- Bright areas = high elevation (mountains)")
print("- Dark areas = low elevation (valleys, plains)")
print("- Should show recognizable Alpine mountain ranges")
