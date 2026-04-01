## Bakes horizon maps from heightmap data for terrain self-shadowing.
##
## For each heightmap texel, marches outward in 8 compass directions and records
## the maximum elevation angle encountered. At runtime the shader compares the
## sun's elevation against the stored angle to determine shadow.
##
## Output: 2 RGBA8 images per region (4 directions each = 8 total).
##   Texture 1: N, NE, E, SE
##   Texture 2: S, SW, W, NW
##
## Reference: "Fun With Horizon Maps" — Gabriel Felipe da Silva
## https://dasilvagf.github.io/posts/2020/08/fun-with-horizon-maps/
class_name HorizonMapBaker
extends RefCounted

## 8 compass directions as XY offsets (N, NE, E, SE, S, SW, W, NW)
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(0, -1),   # N  (image y decreases = north)
	Vector2i(1, -1),   # NE
	Vector2i(1, 0),    # E
	Vector2i(1, 1),    # SE
	Vector2i(0, 1),    # S
	Vector2i(-1, 1),   # SW
	Vector2i(-1, 0),   # W
	Vector2i(-1, -1),  # NW
]

## Maximum march distance in texels. Higher = more accurate for large terrain features,
## but slower baking. 64 covers one full MW cell width.
var max_march_distance: int = 64

## World-space distance per texel (vertex_spacing). Used to compute elevation angles.
var texel_spacing: float = 1.828


## Bake horizon maps for a combined region heightmap, with neighbor context.
## [param heightmap] The region heightmap (256x256, FORMAT_RF)
## [param neighbors] Dictionary of Vector2i offset -> Image for adjacent regions.
##   e.g. {Vector2i(-1,0): left_heightmap, Vector2i(1,0): right_heightmap, ...}
##   Neighbors provide context so rays don't stop at region boundaries.
## Returns: [tex1, tex2] as RGBA8 images at the region resolution.
func bake_with_neighbors(heightmap: Image, neighbors: Dictionary) -> Array[Image]:
	var region_w: int = heightmap.get_width()
	var region_h: int = heightmap.get_height()

	# Build padded heightmap: region + max_march_distance border on each side
	var pad: int = max_march_distance
	var total_w: int = region_w + pad * 2
	var total_h: int = region_h + pad * 2

	# Create padded height array filled with ocean floor (no shadow contribution)
	var heights := PackedFloat32Array()
	heights.resize(total_w * total_h)
	heights.fill(-30.0)  # Below ocean floor

	# Copy center region
	for y in range(region_h):
		for x in range(region_w):
			heights[(y + pad) * total_w + (x + pad)] = heightmap.get_pixel(x, y).r

	# Copy neighbor data into the padding
	for offset: Vector2i in neighbors:
		var neighbor: Image = neighbors[offset]
		if not neighbor:
			continue
		var nw: int = neighbor.get_width()
		var nh: int = neighbor.get_height()

		# Calculate where this neighbor's data goes in padded space
		var dst_x_start: int = pad + offset.x * region_w
		var dst_y_start: int = pad + offset.y * region_h

		for ny in range(nh):
			for nx in range(nw):
				var dx: int = dst_x_start + nx
				var dy: int = dst_y_start + ny
				if dx >= 0 and dx < total_w and dy >= 0 and dy < total_h:
					heights[dy * total_w + dx] = neighbor.get_pixel(nx, ny).r

	# Output images at region resolution
	var tex1 := Image.create(region_w, region_h, false, Image.FORMAT_RGBA8)
	var tex2 := Image.create(region_w, region_h, false, Image.FORMAT_RGBA8)

	# March from each region texel using padded array for context
	for y in range(region_h):
		for x in range(region_w):
			var px: int = x + pad
			var py: int = y + pad
			var center_h: float = heights[py * total_w + px]
			var angles := PackedFloat32Array()
			angles.resize(8)

			for dir_idx in range(8):
				var dir: Vector2i = DIRECTIONS[dir_idx]
				var step_dist: float = texel_spacing
				if dir.x != 0 and dir.y != 0:
					step_dist *= 1.41421356

				var max_angle: float = 0.0
				var sx: int = px
				var sy: int = py

				for step in range(1, max_march_distance + 1):
					sx += dir.x
					sy += dir.y

					if sx < 0 or sx >= total_w or sy < 0 or sy >= total_h:
						break

					var sample_h: float = heights[sy * total_w + sx]
					var h_diff: float = sample_h - center_h
					var world_dist: float = float(step) * step_dist

					var angle: float = atan2(h_diff, world_dist)
					if angle > max_angle:
						max_angle = angle

				angles[dir_idx] = clampf(max_angle / (PI * 0.5), 0.0, 1.0)

			tex1.set_pixel(x, y, Color(angles[0], angles[1], angles[2], angles[3]))
			tex2.set_pixel(x, y, Color(angles[4], angles[5], angles[6], angles[7]))

	return [tex1, tex2]
