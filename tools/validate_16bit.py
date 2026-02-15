"""
16-bit PNG Validation Script
Run this in Python to verify your PNG chunks are actually 16-bit mode I;16

Usage:
    python validate_16bit.py path/to/chunk_3_2.png
"""

import sys
from PIL import Image


def validate_png_16bit(filepath):
    """Validate that a PNG file contains 16-bit grayscale data."""
    
    print(f"Validating: {filepath}")
    print("-" * 60)
    
    try:
        img = Image.open(filepath)
        
        # Basic info
        print(f"Format: {img.format}")
        print(f"Mode: {img.mode}")
        print(f"Size: {img.size}")
        
        # Check mode
        if img.mode != "I;16":
            print(f"\n⚠️  WARNING: Image mode is '{img.mode}', not 'I;16'")
            print(f"   This means it's not stored as 16-bit grayscale!")
            
            if img.mode == "L":
                print(f"   Mode 'L' = 8-bit grayscale (0-255)")
                print(f"   You'll lose elevation precision!")
            elif img.mode == "I":
                print(f"   Mode 'I' = 32-bit integer grayscale")
                print(f"   Should work but wastes space")
            
            return False
        
        # Sample pixel values
        pixels = list(img.getdata())
        min_val = min(pixels)
        max_val = max(pixels)
        
        print(f"\nPixel value range:")
        print(f"  Min: {min_val}")
        print(f"  Max: {max_val}")
        
        # Check if values use full 16-bit range
        if max_val <= 255:
            print(f"\n⚠️  WARNING: Max value is {max_val} (≤255)")
            print(f"   Even though mode is I;16, data only uses 8 bits!")
            print(f"   This suggests data was improperly converted.")
            return False
        
        print(f"\n✅ SUCCESS: Image is properly stored as 16-bit!")
        print(f"   Values span {min_val}-{max_val} (using full range)")
        
        # Convert to elevation for reference
        max_elevation_m = 4810.0
        min_elev = (min_val / 65535.0) * max_elevation_m
        max_elev = (max_val / 65535.0) * max_elevation_m
        
        print(f"\nExpected elevation range:")
        print(f"  Min: {min_elev:.1f} m")
        print(f"  Max: {max_elev:.1f} m")
        
        return True
        
    except Exception as e:
        print(f"\n❌ ERROR: {e}")
        return False


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_16bit.py <path_to_png>")
        print("\nExample:")
        print("  python validate_16bit.py data/terrain/chunks/lod0/chunk_3_2.png")
        sys.exit(1)
    
    filepath = sys.argv[1]
    is_valid = validate_png_16bit(filepath)
    
    sys.exit(0 if is_valid else 1)
