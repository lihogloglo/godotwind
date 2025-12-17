#!/usr/bin/env python3
"""
Preprocess La Palma GeoTIFF heightmaps for Godot/Terrain3D

This script:
1. Merges multiple GeoTIFF tiles into a single mosaic
2. Resamples to target resolution (6m vertex spacing)
3. Tiles into Terrain3D region-sized chunks (256x256 pixels)
4. Saves as raw binary float32 heightmaps + metadata JSON

Output structure:
    lapalma_processed/
        metadata.json        # World configuration
        regions/
            region_-5_3.raw  # 256x256 float32 heightmap
            region_-5_4.raw
            ...

Usage:
    python3 preprocess_lapalma.py [--vertex-spacing 6.0] [--output-dir lapalma_processed]
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
                origin = (tp[3], tp[4])  # lon, lat
            elif 'ModelPixelScale' in tag.name:
                pixel_scale = tag.value[:2]

        return data, origin, pixel_scale


def deg_to_meters(lon_deg: float, lat_deg: float, ref_lat: float = 28.5) -> tuple:
    """Convert degrees to approximate meters at La Palma latitude"""
    import math
    meters_per_deg_lat = 111320.0
    meters_per_deg_lon = 111320.0 * math.cos(math.radians(ref_lat))
    return lon_deg * meters_per_deg_lon, lat_deg * meters_per_deg_lat


def main():
    parser = argparse.ArgumentParser(description='Preprocess La Palma heightmaps for Godot')
    parser.add_argument('--input-dir', default='lapalma_map', help='Input directory with GeoTIFFs')
    parser.add_argument('--output-dir', default='lapalma_processed', help='Output directory')
    parser.add_argument('--vertex-spacing', type=float, default=6.0, help='Meters per vertex (default: 6.0)')
    parser.add_argument('--region-size', type=int, default=256, help='Pixels per region (default: 256)')
    parser.add_argument('--use-wgs84', action='store_true', default=True, help='Use WGS84 tiles (default)')
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir)
    vertex_spacing = args.vertex_spacing
    region_size = args.region_size

    # Find GeoTIFF files
    pattern = 'WGS84' if args.use_wgs84 else 'REGCAN95'
    tiff_files = sorted([f for f in input_dir.glob('*.tif') if pattern in f.name])

    if not tiff_files:
        print(f"No {pattern} GeoTIFF files found in {input_dir}")
        sys.exit(1)

    print(f"Found {len(tiff_files)} GeoTIFF tiles")

    # Read all tiles and compute bounds
    tiles = []
    global_bounds = [float('inf'), float('inf'), float('-inf'), float('-inf')]  # min_lon, min_lat, max_lon, max_lat

    for tiff_path in tiff_files:
        print(f"  Reading {tiff_path.name}...")
        data, origin, pixel_scale = read_geotiff(str(tiff_path))

        h, w = data.shape
        extent_lon = w * pixel_scale[0]
        extent_lat = h * pixel_scale[1]

        bounds = (origin[0], origin[1] - extent_lat, origin[0] + extent_lon, origin[1])

        tiles.append({
            'path': tiff_path,
            'data': data,
            'origin': origin,
            'pixel_scale': pixel_scale,
            'bounds': bounds,
            'shape': data.shape,
        })

        global_bounds[0] = min(global_bounds[0], bounds[0])
        global_bounds[1] = min(global_bounds[1], bounds[1])
        global_bounds[2] = max(global_bounds[2], bounds[2])
        global_bounds[3] = max(global_bounds[3], bounds[3])

    # Convert bounds to meters (origin at SW corner)
    width_deg = global_bounds[2] - global_bounds[0]
    height_deg = global_bounds[3] - global_bounds[1]
    ref_lat = (global_bounds[1] + global_bounds[3]) / 2

    width_m, height_m = deg_to_meters(width_deg, height_deg, ref_lat)

    print(f"\nGlobal bounds:")
    print(f"  Longitude: {global_bounds[0]:.4f} to {global_bounds[2]:.4f}")
    print(f"  Latitude: {global_bounds[1]:.4f} to {global_bounds[3]:.4f}")
    print(f"  Size: {width_m/1000:.1f} km x {height_m/1000:.1f} km")

    # Calculate output grid size
    output_width = int(width_m / vertex_spacing)
    output_height = int(height_m / vertex_spacing)

    # Round up to region boundaries
    num_regions_x = (output_width + region_size - 1) // region_size
    num_regions_y = (output_height + region_size - 1) // region_size
    output_width = num_regions_x * region_size
    output_height = num_regions_y * region_size

    print(f"\nOutput configuration:")
    print(f"  Vertex spacing: {vertex_spacing}m")
    print(f"  Region size: {region_size} pixels")
    print(f"  Output grid: {output_width} x {output_height} pixels")
    print(f"  Regions: {num_regions_x} x {num_regions_y} = {num_regions_x * num_regions_y} total")
    print(f"  Coverage: {output_width * vertex_spacing / 1000:.1f} km x {output_height * vertex_spacing / 1000:.1f} km")

    # Create output mosaic
    print(f"\nCreating mosaic...")
    mosaic = np.full((output_height, output_width), np.nan, dtype=np.float32)

    for tile in tiles:
        print(f"  Merging {tile['path'].name}...")

        # Calculate tile position in output grid
        tile_lon_offset = tile['bounds'][0] - global_bounds[0]
        tile_lat_offset = global_bounds[3] - tile['bounds'][3]  # From top

        tile_x_m, _ = deg_to_meters(tile_lon_offset, 0, ref_lat)
        _, tile_y_m = deg_to_meters(0, tile_lat_offset, ref_lat)

        tile_x = int(tile_x_m / vertex_spacing)
        tile_y = int(tile_y_m / vertex_spacing)

        # Calculate source pixel scale in meters (lon and lat have different scales!)
        src_pixel_x_m, src_pixel_y_m = deg_to_meters(tile['pixel_scale'][0], tile['pixel_scale'][1], ref_lat)

        # Resample tile to output resolution
        src_h, src_w = tile['shape']
        dst_w = int(src_w * src_pixel_x_m / vertex_spacing)
        dst_h = int(src_h * src_pixel_y_m / vertex_spacing)

        # Simple resampling (good enough for 2m -> 6m)
        data = tile['data']

        # Replace nodata values
        data = np.where(data < -1000, np.nan, data)

        # Calculate scale factors for x and y separately
        scale_factor_x = src_pixel_x_m / vertex_spacing
        scale_factor_y = src_pixel_y_m / vertex_spacing

        # Use proper resampling that produces exactly dst_h x dst_w output
        if dst_h <= 0 or dst_w <= 0:
            continue

        # Create index arrays that map output pixels to source pixels
        y_indices = (np.arange(dst_h) * vertex_spacing / src_pixel_y_m).astype(int)
        x_indices = (np.arange(dst_w) * vertex_spacing / src_pixel_x_m).astype(int)
        y_indices = np.clip(y_indices, 0, src_h - 1)
        x_indices = np.clip(x_indices, 0, src_w - 1)

        # Use nearest neighbor sampling (fast and produces exact size needed)
        # Block averaging was causing size mismatches
        resampled = data[y_indices][:, x_indices]

        # Copy to mosaic (handling bounds)
        dst_y1 = tile_y
        dst_y2 = min(tile_y + resampled.shape[0], output_height)
        dst_x1 = tile_x
        dst_x2 = min(tile_x + resampled.shape[1], output_width)

        src_y2 = dst_y2 - dst_y1
        src_x2 = dst_x2 - dst_x1

        if dst_y1 >= 0 and dst_x1 >= 0 and src_y2 > 0 and src_x2 > 0:
            # Only copy where we don't already have data (handle overlaps)
            target = mosaic[dst_y1:dst_y2, dst_x1:dst_x2]
            source = resampled[:src_y2, :src_x2]
            mask = np.isnan(target)
            target[mask] = source[mask]

    # Fill remaining NaN with sea level (0)
    mosaic = np.nan_to_num(mosaic, nan=0.0)

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
    print(f"\nSaving {num_regions_x * num_regions_y} regions...")
    region_list = []

    for ry in range(num_regions_y):
        for rx in range(num_regions_x):
            # Extract region
            y1 = ry * region_size
            y2 = y1 + region_size
            x1 = rx * region_size
            x2 = x1 + region_size

            region_data = mosaic[y1:y2, x1:x2]

            # Check if region has terrain (not all zeros)
            has_terrain = np.any(region_data > 1.0)  # Above sea level

            if has_terrain:
                # Save as raw float32
                # Godot coordinate system: region (0,0) is at world origin
                # We offset so that regions are centered around (0,0)
                godot_rx = rx - num_regions_x // 2
                godot_ry = num_regions_y // 2 - ry - 1  # Flip Y for Godot

                filename = f"region_{godot_rx}_{godot_ry}.raw"
                filepath = regions_dir / filename

                # Flip vertically for Godot (image y=0 is top, Godot z=0 is north)
                region_flipped = np.flipud(region_data)

                with open(filepath, 'wb') as f:
                    f.write(region_flipped.astype(np.float32).tobytes())

                region_list.append({
                    'x': godot_rx,
                    'y': godot_ry,
                    'file': filename,
                    'min_height': float(np.min(region_data)),
                    'max_height': float(np.max(region_data)),
                })

    print(f"  Saved {len(region_list)} terrain regions (skipped {num_regions_x * num_regions_y - len(region_list)} ocean regions)")

    # Save metadata
    metadata = {
        'world_name': 'La Palma',
        'vertex_spacing': vertex_spacing,
        'region_size': region_size,
        'num_regions_x': num_regions_x,
        'num_regions_y': num_regions_y,
        'world_width_m': output_width * vertex_spacing,
        'world_height_m': output_height * vertex_spacing,
        'origin_lon': global_bounds[0],
        'origin_lat': global_bounds[1],
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


if __name__ == '__main__':
    main()
