#!/usr/bin/env python3
"""
Validation script for terrain processor output.

Checks all acceptance criteria:
1. Master heightmap exists, is 16-bit, has non-zero dimensions
2. Visual inspection data (statistics)
3. LOD directories and chunk structure
4. Chunk format validation (512×512, 16-bit)
5. LOD chunk count progression
6. Metadata validation
7. Coordinate consistency checks

Usage:
    python validate_output.py --terrain-dir ../data/terrain/
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Tuple
import numpy as np
from PIL import Image


class TerrainValidator:
    """Validates processed terrain data against acceptance criteria."""
    
    def __init__(self, terrain_dir: Path):
        self.terrain_dir = terrain_dir
        self.errors = []
        self.warnings = []
        self.metadata = None
    
    def validate(self) -> bool:
        """Run all validation checks. Returns True if all pass."""
        print(f"\n{'='*80}")
        print(f"GeoStrategy Terrain Validator")
        print(f"{'='*80}\n")
        print(f"Validating: {self.terrain_dir}\n")
        
        # Run all checks
        checks = [
            ("Master heightmap exists", self._check_master_exists),
            ("Master heightmap format", self._check_master_format),
            ("Master heightmap visual data", self._check_master_visual),
            ("Metadata file", self._check_metadata_exists),
            ("Metadata validity", self._check_metadata_valid),
            ("LOD directory structure", self._check_lod_structure),
            ("Chunk format validation", self._check_chunk_formats),
            ("LOD progression", self._check_lod_progression),
            ("Metadata consistency", self._check_metadata_consistency),
            ("Spot check LOD correspondence", self._check_lod_correspondence),
        ]
        
        passed = 0
        failed = 0
        
        for name, check_fn in checks:
            print(f"[{passed + failed + 1}/{len(checks)}] {name}...", end=' ')
            try:
                result = check_fn()
                if result:
                    print("[PASS]")
                    passed += 1
                else:
                    print("[FAIL]")
                    failed += 1
            except Exception as e:
                print(f"[ERROR]: {e}")
                self.errors.append(f"{name}: {e}")
                failed += 1
        
        # Summary
        print(f"\n{'='*80}")
        print(f"Validation Summary")
        print(f"{'='*80}")
        print(f"Passed: {passed}/{len(checks)}")
        print(f"Failed: {failed}/{len(checks)}")
        
        if self.warnings:
            print(f"\nWarnings ({len(self.warnings)}):")
            for warning in self.warnings:
                print(f"  [!] {warning}")
        
        if self.errors:
            print(f"\nErrors ({len(self.errors)}):")
            for error in self.errors:
                print(f"  [X] {error}")
        
        if failed == 0:
            print(f"\n[OK] All validation checks passed!")
        else:
            print(f"\n[FAIL] {failed} validation check(s) failed.")
        
        print(f"{'='*80}\n")
        
        return failed == 0
    
    def _check_master_exists(self) -> bool:
        """Check that master_heightmap.png exists."""
        master_path = self.terrain_dir / "master_heightmap.png"
        if not master_path.exists():
            self.errors.append(f"Master heightmap not found: {master_path}")
            return False
        return True
    
    def _check_master_format(self) -> bool:
        """Check master heightmap is 16-bit grayscale with non-zero dimensions."""
        master_path = self.terrain_dir / "master_heightmap.png"
        
        img = Image.open(master_path)
        
        # Check mode (should be 'I' or 'I;16' for 16-bit)
        if img.mode not in ['I', 'I;16', 'I;16B', 'I;16L']:
            self.errors.append(f"Master heightmap is {img.mode}, expected 16-bit ('I' or 'I;16')")
            return False
        
        # Check dimensions
        w, h = img.size
        if w == 0 or h == 0:
            self.errors.append(f"Master heightmap has zero dimensions: {w}×{h}")
            return False
        
        print(f"\n    Dimensions: {w} × {h} pixels")
        print(f"    Mode: {img.mode}")
        
        return True
    
    def _check_master_visual(self) -> bool:
        """Check master heightmap has reasonable visual data (not all black/white/noise)."""
        master_path = self.terrain_dir / "master_heightmap.png"
        
        img = Image.open(master_path)
        data = np.array(img)
        
        # Statistics
        min_val = np.min(data)
        max_val = np.max(data)
        mean_val = np.mean(data)
        std_val = np.std(data)
        
        print(f"\n    Value range: {min_val} - {max_val}")
        print(f"    Mean: {mean_val:.1f}, Std: {std_val:.1f}")
        
        # Check for all black (min == max == 0)
        if max_val == 0:
            self.errors.append("Master heightmap is all black (max value = 0)")
            return False
        
        # Check for all white (min == max == 65535)
        if min_val == 65535:
            self.errors.append("Master heightmap is all white (min value = 65535)")
            return False
        
        # Check for no variance (flat image)
        if std_val < 100:
            self.warnings.append(f"Master heightmap has very low variance (std={std_val:.1f})")
        
        # Check for reasonable dynamic range
        dynamic_range = max_val - min_val
        if dynamic_range < 1000:
            self.warnings.append(f"Master heightmap has low dynamic range ({dynamic_range})")
        
        return True
    
    def _check_metadata_exists(self) -> bool:
        """Check terrain_metadata.json exists."""
        metadata_path = self.terrain_dir / "terrain_metadata.json"
        if not metadata_path.exists():
            self.errors.append(f"Metadata file not found: {metadata_path}")
            return False
        return True
    
    def _check_metadata_valid(self) -> bool:
        """Check metadata is valid JSON with required fields."""
        metadata_path = self.terrain_dir / "terrain_metadata.json"
        
        try:
            with open(metadata_path, 'r') as f:
                self.metadata = json.load(f)
        except json.JSONDecodeError as e:
            self.errors.append(f"Metadata is not valid JSON: {e}")
            return False
        
        # Check required fields
        required_fields = [
            'region_name', 'bounding_box', 'resolution_m', 'max_elevation_m',
            'chunk_size_px', 'lod_levels', 'total_chunks',
            'master_heightmap_width', 'master_heightmap_height', 'chunks'
        ]
        
        for field in required_fields:
            if field not in self.metadata:
                self.errors.append(f"Metadata missing required field: {field}")
                return False
        
        print(f"\n    Region: {self.metadata['region_name']}")
        print(f"    Total chunks: {self.metadata['total_chunks']}")
        print(f"    Master dimensions: {self.metadata['master_heightmap_width']} × {self.metadata['master_heightmap_height']}")
        
        return True
    
    def _check_lod_structure(self) -> bool:
        """Check LOD directories exist (lod0 through lod4)."""
        chunks_dir = self.terrain_dir / "chunks"
        
        if not chunks_dir.exists():
            self.errors.append(f"Chunks directory not found: {chunks_dir}")
            return False
        
        for lod in range(5):
            lod_dir = chunks_dir / f"lod{lod}"
            if not lod_dir.exists():
                self.errors.append(f"LOD directory not found: {lod_dir}")
                return False
            
            # Check it has some chunks
            chunks = list(lod_dir.glob("*.png"))
            if len(chunks) == 0:
                self.errors.append(f"LOD {lod} directory is empty")
                return False
        
        return True
    
    def _check_chunk_formats(self) -> bool:
        """Validate chunk format: 512×512, 16-bit grayscale."""
        chunks_dir = self.terrain_dir / "chunks"
        
        # Sample chunks from each LOD level
        all_valid = True
        
        for lod in range(5):
            lod_dir = chunks_dir / f"lod{lod}"
            chunks = list(lod_dir.glob("*.png"))
            
            if not chunks:
                continue
            
            # Check first chunk from this LOD
            chunk_path = chunks[0]
            
            img = Image.open(chunk_path)
            
            # Check dimensions
            if img.size != (512, 512):
                self.errors.append(f"Chunk {chunk_path.name} has wrong size: {img.size}, expected (512, 512)")
                all_valid = False
            
            # Check mode (16-bit)
            if img.mode not in ['I', 'I;16', 'I;16B', 'I;16L']:
                self.errors.append(f"Chunk {chunk_path.name} is {img.mode}, expected 16-bit")
                all_valid = False
        
        return all_valid
    
    def _check_lod_progression(self) -> bool:
        """Check LOD levels have correct chunk count progression (~1/4 per level)."""
        if not self.metadata:
            self.warnings.append("Cannot check LOD progression without metadata")
            return True
        
        lod_counts = {}
        for chunk in self.metadata['chunks']:
            lod = chunk['lod']
            lod_counts[lod] = lod_counts.get(lod, 0) + 1
        
        print(f"\n    LOD chunk counts:")
        for lod in range(5):
            count = lod_counts.get(lod, 0)
            print(f"      LOD {lod}: {count:4d} chunks")
        
        # Check progression
        for lod in range(4):
            current_count = lod_counts.get(lod, 0)
            next_count = lod_counts.get(lod + 1, 0)
            
            if current_count == 0:
                continue
            
            # Expect roughly 4× more chunks in current than next
            ratio = current_count / max(next_count, 1)
            
            # Allow some tolerance (2× to 6×) due to rounding in downsampling
            if ratio < 2.0 or ratio > 6.0:
                self.warnings.append(
                    f"LOD {lod} to {lod+1} has unusual ratio: {ratio:.2f}× (expected ~4×)"
                )
        
        return True
    
    def _check_metadata_consistency(self) -> bool:
        """Check metadata chunks array matches actual files on disk."""
        if not self.metadata:
            return False
        
        # Get chunks from metadata
        metadata_chunks = set()
        for chunk in self.metadata['chunks']:
            chunk_path = self.terrain_dir / chunk['path']
            metadata_chunks.add(chunk_path)
        
        # Get actual chunks from disk
        disk_chunks = set()
        chunks_dir = self.terrain_dir / "chunks"
        for lod_dir in chunks_dir.glob("lod*"):
            for chunk_file in lod_dir.glob("*.png"):
                disk_chunks.add(chunk_file)
        
        # Compare
        missing_from_disk = metadata_chunks - disk_chunks
        missing_from_metadata = disk_chunks - metadata_chunks
        
        all_consistent = True
        
        if missing_from_disk:
            self.errors.append(f"Metadata references {len(missing_from_disk)} chunks that don't exist on disk")
            all_consistent = False
        
        if missing_from_metadata:
            self.errors.append(f"{len(missing_from_metadata)} chunks on disk are not in metadata")
            all_consistent = False
        
        # Check total_chunks matches
        if len(self.metadata['chunks']) != self.metadata['total_chunks']:
            self.errors.append(
                f"Metadata total_chunks ({self.metadata['total_chunks']}) doesn't match "
                f"chunks array length ({len(self.metadata['chunks'])})"
            )
            all_consistent = False
        
        return all_consistent
    
    def _check_lod_correspondence(self) -> bool:
        """Spot check: LOD 1 chunk should look like blurred version of LOD 0."""
        chunks_dir = self.terrain_dir / "chunks"
        
        # Find a chunk that exists in both LOD 0 and LOD 1
        lod0_chunks = list((chunks_dir / "lod0").glob("chunk_*_*.png"))
        if not lod0_chunks:
            self.warnings.append("No LOD 0 chunks to compare")
            return True
        
        # Get coordinates from first LOD 0 chunk
        chunk_name = lod0_chunks[0].stem  # e.g., "chunk_0_0"
        parts = chunk_name.split('_')
        if len(parts) != 3:
            self.warnings.append(f"Cannot parse chunk name: {chunk_name}")
            return True
        
        x, y = int(parts[1]), int(parts[2])
        
        # Corresponding LOD 1 chunk should be at (x//2, y//2)
        lod1_x, lod1_y = x // 2, y // 2
        lod1_path = chunks_dir / "lod1" / f"chunk_{lod1_x}_{lod1_y}.png"
        
        if not lod1_path.exists():
            self.warnings.append(f"LOD 1 chunk not found for comparison: {lod1_path.name}")
            return True
        
        # Load both chunks
        lod0_img = np.array(Image.open(lod0_chunks[0]))
        lod1_img = np.array(Image.open(lod1_path))
        
        # Check LOD 1 is "smoother" (lower variance)
        lod0_std = np.std(lod0_img)
        lod1_std = np.std(lod1_img)
        
        print(f"\n    LOD 0 std: {lod0_std:.1f}, LOD 1 std: {lod1_std:.1f}")
        
        # LOD 1 should generally have lower or similar variance
        if lod1_std > lod0_std * 1.5:
            self.warnings.append(
                f"LOD 1 appears noisier than LOD 0 (std ratio: {lod1_std/lod0_std:.2f})"
            )
        
        return True


def main():
    parser = argparse.ArgumentParser(
        description='Validate GeoStrategy terrain processor output'
    )
    parser.add_argument(
        '--terrain-dir',
        type=Path,
        default=Path(__file__).parent.parent / 'data' / 'terrain',
        help='Terrain data directory to validate (default: ../data/terrain/)'
    )
    
    args = parser.parse_args()
    
    if not args.terrain_dir.exists():
        print(f"Error: Terrain directory not found: {args.terrain_dir}")
        sys.exit(1)
    
    validator = TerrainValidator(args.terrain_dir)
    success = validator.validate()
    
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
