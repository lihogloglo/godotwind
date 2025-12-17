#!/usr/bin/env python3
"""
Preprocess La Palma GeoTIFF heightmaps for Godot/Terrain3D

This script:
1. Loads the merged la_palma_heightmap.tif file
2. Tiles into Terrain3D region-sized chunks (256x256 pixels)
3. Saves as raw binary float32 heightmaps + metadata JSON

Output structure:
    lapalma_processed/
        metadata.json        # World configuration
        regions/
            region_-5_3.raw  # 256x256 float32 heightmap
            region_-5_4.raw
            ...

Usage:
    python3 preprocess_lapalma.py [--vertex-spacing 2.0] [--output-dir lapalma_processed]
"""

import os
import sys
import json
import struct
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
    parser = argparse.ArgumentParser(description='Preprocess La Palma heightmaps for Godot')
    parser.add_argument('--input-file', default='lapalma_map/la_palma_heightmap.tif',
                        help='Input merged TIFF file')
    parser.add_argument('--output-dir', default='lapalma_processed', help='Output directory')
    parser.add_argument('--vertex-spacing', type=float, default=2.0,
                        help='Meters per vertex (default: 2.0 = native MDT02 resolution)')
    parser.add_argument('--region-size', type=int, default=256, help='Pixels per region (default: 256)')
    args = parser.parse_args()

    input_file = Path(args.input_file)
    output_dir = Path(args.output_dir)
    vertex_spacing = args.vertex_spacing
    region_size = args.region_size

    if not input_file.exists():
        print(f"Error: Input file not found: {input_file}")
        print("Expected the merged la_palma_heightmap.tif file")
        sys.exit(1)

    print(f"Loading {input_file}...")
    data, origin, pixel_scale = read_geotiff(str(input_file))

    src_height, src_width = data.shape
    src_pixel_size = pixel_scale[0]  # Assuming square pixels

    print(f"\nInput file info:")
    print(f"  Size: {src_width} x {src_height} pixels")
    print(f"  Source pixel size: {src_pixel_size}m")
    print(f"  Origin (UTM): {origin}")
    print(f"  Coverage: {src_width * src_pixel_size / 1000:.1f} km x {src_height * src_pixel_size / 1000:.1f} km")

    # Replace nodata values with 0 (sea level)
    nodata_mask = data <= -1000
    data = np.where(nodata_mask, 0.0, data).astype(np.float32)

    # Calculate if we need to resample
    if abs(vertex_spacing - src_pixel_size) < 0.001:
        print(f"\nUsing native {src_pixel_size}m resolution (no resampling needed)")
        mosaic = data
    else:
        # Resample to target resolution
        scale_factor = src_pixel_size / vertex_spacing
        output_width = int(src_width * scale_factor)
        output_height = int(src_height * scale_factor)

        print(f"\nResampling from {src_pixel_size}m to {vertex_spacing}m...")
        print(f"  Output size: {output_width} x {output_height} pixels")

        # Create index arrays for nearest-neighbor resampling
        y_indices = (np.arange(output_height) / scale_factor).astype(int)
        x_indices = (np.arange(output_width) / scale_factor).astype(int)
        y_indices = np.clip(y_indices, 0, src_height - 1)
        x_indices = np.clip(x_indices, 0, src_width - 1)

        mosaic = data[y_indices][:, x_indices]

    output_height, output_width = mosaic.shape

    # Round up to region boundaries
    num_regions_x = (output_width + region_size - 1) // region_size
    num_regions_y = (output_height + region_size - 1) // region_size
    padded_width = num_regions_x * region_size
    padded_height = num_regions_y * region_size

    # Pad mosaic if needed
    if padded_width != output_width or padded_height != output_height:
        print(f"\nPadding to region boundaries: {padded_width} x {padded_height} pixels")
        padded = np.zeros((padded_height, padded_width), dtype=np.float32)
        padded[:output_height, :output_width] = mosaic
        mosaic = padded
        output_width, output_height = padded_width, padded_height

    print(f"\nOutput configuration:")
    print(f"  Vertex spacing: {vertex_spacing}m")
    print(f"  Region size: {region_size} pixels ({region_size * vertex_spacing}m)")
    print(f"  Output grid: {output_width} x {output_height} pixels")
    print(f"  Regions: {num_regions_x} x {num_regions_y} = {num_regions_x * num_regions_y} total")
    print(f"  World size: {output_width * vertex_spacing / 1000:.1f} km x {output_height * vertex_spacing / 1000:.1f} km")

    # Get height statistics
    valid_mask = mosaic > 0
    if np.any(valid_mask):
        min_height = np.min(mosaic[valid_mask])
        max_height = np.max(mosaic)
        print(f"\nHeight range: {min_height:.1f}m to {max_height:.1f}m")

    # Create output directory
    output_dir.mkdir(parents=True, exist_ok=True)
    regions_dir = output_dir / 'regions'
    regions_dir.mkdir(exist_ok=True)

    # Save regions
    print(f"\nProcessing {num_regions_x * num_regions_y} regions...")
    region_list = []
    terrain_regions = 0
    ocean_regions = 0

    for ry in range(num_regions_y):
        for rx in range(num_regions_x):
            # Extract region
            y1 = ry * region_size
            y2 = y1 + region_size
            x1 = rx * region_size
            x2 = x1 + region_size

            region_data = mosaic[y1:y2, x1:x2]

            # Check if region has terrain (not all zeros/sea level)
            has_terrain = np.any(region_data > 1.0)  # Above sea level

            if has_terrain:
                terrain_regions += 1
                # Save as raw float32
                # Godot coordinate system: region (0,0) is at world origin
                # We offset so that regions are centered around (0,0)
                godot_rx = rx - num_regions_x // 2
                godot_ry = num_regions_y // 2 - ry - 1  # Flip Y coordinate for Godot

                filename = f"region_{godot_rx}_{godot_ry}.raw"
                filepath = regions_dir / filename

                # NO flipud needed! GeoTIFF row 0 = north, Terrain3D row 0 = north
                # The Y coordinate flip above handles region placement
                with open(filepath, 'wb') as f:
                    f.write(region_data.astype(np.float32).tobytes())

                region_list.append({
                    'x': godot_rx,
                    'y': godot_ry,
                    'file': filename,
                    'min_height': float(np.min(region_data)),
                    'max_height': float(np.max(region_data)),
                })
            else:
                ocean_regions += 1

        # Progress indicator
        if (ry + 1) % 10 == 0:
            print(f"  Processed row {ry + 1}/{num_regions_y}...")

    print(f"\n  Saved {terrain_regions} terrain regions")
    print(f"  Skipped {ocean_regions} ocean regions")

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
        'sea_level': 0.0,
        'min_height': float(np.min(mosaic)),
        'max_height': float(np.max(mosaic)),
        'regions': region_list,
    }

    with open(output_dir / 'metadata.json', 'w') as f:
        json.dump(metadata, f, indent=2)

    print(f"\nDone! Output saved to {output_dir}/")
    print(f"  Metadata: metadata.json")
    print(f"  Regions: regions/*.raw ({len(region_list)} files)")
    print(f"\nTerrain3D Import Settings:")
    print(f"  - Vertex Spacing: {vertex_spacing}")
    print(f"  - Height Scale: 1.0 (values are already in meters)")


if __name__ == '__main__':
    main()
