#!/usr/bin/env python3
"""
Preprocess La Palma GeoTIFF heightmap for Godot/Terrain3D

This script:
1. Loads la_palma_heightmap.tif (2m resolution GeoTIFF)
2. Tiles into Terrain3D regions (1024x1024 pixels = max supported)
3. Saves as raw binary float32 heightmaps + metadata JSON

Terrain3D Limits:
- Region coordinates: -16 to +15 (32 regions per axis)
- With region_size=1024 and vertex_spacing=2.0:
  - Region world size: 1024 * 2.0 = 2048 meters
  - Max world extent: 32 * 2048 = 65,536 meters = 65.5 km per axis
- La Palma (33.3 x 47 km) fits comfortably!

Output structure:
    lapalma_processed/
        metadata.json        # World configuration
        regions/
            region_-8_11.raw # 1024x1024 float32 heightmap
            ...

Usage:
    python3 preprocess_lapalma.py
    python3 preprocess_lapalma.py --vertex-spacing 4.0  # Lower resolution
"""

import os
import sys
import json
import argparse
from pathlib import Path

try:
    import numpy as np
    import tifffile
except ImportError:
    print("Required packages: pip install numpy tifffile")
    sys.exit(1)


def read_geotiff(path: str) -> tuple:
    """Read a GeoTIFF and return (data, origin, pixel_size)"""
    print(f"Reading {path}...")
    with tifffile.TiffFile(path) as tif:
        page = tif.pages[0]
        data = page.asarray()

        # Extract GeoTIFF tags
        origin = (0.0, 0.0)
        pixel_scale = (1.0, 1.0)

        for tag in page.tags.values():
            if 'ModelTiepoint' in tag.name:
                tp = tag.value
                origin = (tp[3], tp[4])  # x, y in meters (UTM)
            elif 'ModelPixelScale' in tag.name:
                pixel_scale = tag.value[:2]

        return data, origin, pixel_scale


def main():
    parser = argparse.ArgumentParser(
        description='Preprocess La Palma heightmap for Terrain3D import',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 preprocess_lapalma.py
  python3 preprocess_lapalma.py --vertex-spacing 4.0   # Half resolution
  python3 preprocess_lapalma.py --input-file custom.tif
        """
    )
    parser.add_argument('--input-file', default='lapalma_map/la_palma_heightmap.tif',
                        help='Input GeoTIFF file (default: lapalma_map/la_palma_heightmap.tif)')
    parser.add_argument('--output-dir', default='lapalma_processed',
                        help='Output directory (default: lapalma_processed)')
    parser.add_argument('--vertex-spacing', type=float, default=2.0,
                        help='Meters per vertex - use 2.0 for native MDT02 resolution (default: 2.0)')
    parser.add_argument('--region-size', type=int, default=1024, choices=[64, 128, 256, 512, 1024],
                        help='Pixels per region - use 1024 for max Terrain3D coverage (default: 1024)')
    args = parser.parse_args()

    input_file = Path(args.input_file)
    output_dir = Path(args.output_dir)
    vertex_spacing = args.vertex_spacing
    region_size = args.region_size

    # Validate input
    if not input_file.exists():
        print(f"Error: Input file not found: {input_file}")
        print("\nExpected: la_palma_heightmap.tif in lapalma_map/ directory")
        sys.exit(1)

    print("=" * 60)
    print("La Palma Heightmap Preprocessor for Terrain3D")
    print("=" * 60)

    # Load GeoTIFF
    data, origin, pixel_scale = read_geotiff(str(input_file))
    src_height, src_width = data.shape
    src_pixel_size = pixel_scale[0]

    print(f"\nInput file:")
    print(f"  Size: {src_width} x {src_height} pixels")
    print(f"  Pixel size: {src_pixel_size}m")
    print(f"  Coverage: {src_width * src_pixel_size / 1000:.1f} x {src_height * src_pixel_size / 1000:.1f} km")
    print(f"  Height range: {np.min(data):.1f}m to {np.max(data):.1f}m")

    # Replace nodata values (typically -9999 or similar) with 0 (sea level)
    nodata_mask = data <= -1000
    nodata_count = np.sum(nodata_mask)
    data = np.where(nodata_mask, 0.0, data).astype(np.float32)
    if nodata_count > 0:
        print(f"  Replaced {nodata_count:,} nodata pixels with sea level (0)")

    # Resample if needed
    if abs(vertex_spacing - src_pixel_size) < 0.001:
        print(f"\nUsing native {src_pixel_size}m resolution")
        mosaic = data
    else:
        scale_factor = src_pixel_size / vertex_spacing
        output_width = int(src_width * scale_factor)
        output_height = int(src_height * scale_factor)
        print(f"\nResampling: {src_pixel_size}m -> {vertex_spacing}m")
        print(f"  New size: {output_width} x {output_height} pixels")

        # Nearest-neighbor resampling
        y_indices = np.clip((np.arange(output_height) / scale_factor).astype(int), 0, src_height - 1)
        x_indices = np.clip((np.arange(output_width) / scale_factor).astype(int), 0, src_width - 1)
        mosaic = data[y_indices][:, x_indices]

    output_height, output_width = mosaic.shape

    # Calculate region layout
    num_regions_x = (output_width + region_size - 1) // region_size
    num_regions_y = (output_height + region_size - 1) // region_size
    padded_width = num_regions_x * region_size
    padded_height = num_regions_y * region_size

    # Terrain3D coordinate limits
    TERRAIN3D_MAX_COORD = 16  # -16 to +15
    max_needed_x = (num_regions_x + 1) // 2
    max_needed_y = (num_regions_y + 1) // 2

    print(f"\nTerrain3D configuration:")
    print(f"  Region size: {region_size} pixels ({region_size * vertex_spacing}m)")
    print(f"  Vertex spacing: {vertex_spacing}m")
    print(f"  Regions needed: {num_regions_x} x {num_regions_y} = {num_regions_x * num_regions_y}")
    print(f"  Region coords: -{max_needed_x} to +{max_needed_x-1} (X), -{max_needed_y} to +{max_needed_y-1} (Y)")
    print(f"  Terrain3D limit: -{TERRAIN3D_MAX_COORD} to +{TERRAIN3D_MAX_COORD-1}")

    # Check if it fits
    if max_needed_x > TERRAIN3D_MAX_COORD or max_needed_y > TERRAIN3D_MAX_COORD:
        print(f"\n[WARNING] Data exceeds Terrain3D limits!")
        print(f"  Try: --region-size 1024 or --vertex-spacing {vertex_spacing * 2}")
        # Continue anyway - importer will skip out-of-bounds regions

    # Pad to region boundaries
    if padded_width != output_width or padded_height != output_height:
        print(f"\nPadding: {output_width}x{output_height} -> {padded_width}x{padded_height}")
        padded = np.zeros((padded_height, padded_width), dtype=np.float32)
        padded[:output_height, :output_width] = mosaic
        mosaic = padded
        output_width, output_height = padded_width, padded_height

    # Create output directories
    output_dir.mkdir(parents=True, exist_ok=True)
    regions_dir = output_dir / 'regions'
    if regions_dir.exists():
        # Clean old regions
        for f in regions_dir.glob('*.raw'):
            f.unlink()
    regions_dir.mkdir(exist_ok=True)

    # Process regions
    print(f"\nProcessing {num_regions_x * num_regions_y} regions...")
    region_list = []
    terrain_count = 0
    ocean_count = 0

    for ry in range(num_regions_y):
        for rx in range(num_regions_x):
            # Extract region data
            y1, y2 = ry * region_size, (ry + 1) * region_size
            x1, x2 = rx * region_size, (rx + 1) * region_size
            region_data = mosaic[y1:y2, x1:x2]

            # Skip pure ocean regions (all values <= 1m)
            if not np.any(region_data > 1.0):
                ocean_count += 1
                continue

            terrain_count += 1

            # Convert to Godot coordinates (centered at origin)
            # GeoTIFF: row 0 = north, Godot/Terrain3D: row 0 = north (same)
            # But Godot Z is south, so we flip Y coordinate for region placement
            godot_rx = rx - num_regions_x // 2
            godot_ry = num_regions_y // 2 - ry - 1

            # Save as raw float32 binary
            filename = f"region_{godot_rx}_{godot_ry}.raw"
            filepath = regions_dir / filename
            with open(filepath, 'wb') as f:
                f.write(region_data.astype(np.float32).tobytes())

            region_list.append({
                'x': godot_rx,
                'y': godot_ry,
                'file': filename,
                'min_height': float(np.min(region_data)),
                'max_height': float(np.max(region_data)),
            })

        # Progress
        if (ry + 1) % 5 == 0:
            print(f"  Row {ry + 1}/{num_regions_y} processed")

    print(f"\n  Terrain regions: {terrain_count}")
    print(f"  Ocean regions (skipped): {ocean_count}")

    # Save metadata
    metadata = {
        'world_name': 'La Palma',
        'vertex_spacing': vertex_spacing,
        'region_size': region_size,
        'num_regions_x': num_regions_x,
        'num_regions_y': num_regions_y,
        'world_width_m': output_width * vertex_spacing,
        'world_height_m': output_height * vertex_spacing,
        'origin_utm_x': origin[0],
        'origin_utm_y': origin[1],
        'min_height': float(np.min(mosaic)),
        'max_height': float(np.max(mosaic)),
        'regions': region_list,
    }

    with open(output_dir / 'metadata.json', 'w') as f:
        json.dump(metadata, f, indent=2)

    # Summary
    total_size_mb = sum((regions_dir / r['file']).stat().st_size for r in region_list) / 1024 / 1024
    print("\n" + "=" * 60)
    print("Preprocessing Complete!")
    print("=" * 60)
    print(f"\nOutput: {output_dir}/")
    print(f"  metadata.json")
    print(f"  regions/ ({len(region_list)} files, {total_size_mb:.1f} MB)")
    print(f"\nTerrain3D Settings:")
    print(f"  vertex_spacing = {vertex_spacing}")
    print(f"  region_size = {region_size}")
    print(f"  height_scale = 1.0 (values are in meters)")
    print(f"\nNext: Open lapalma_importer.tscn in Godot and run import")
    print("=" * 60)


if __name__ == '__main__':
    main()
