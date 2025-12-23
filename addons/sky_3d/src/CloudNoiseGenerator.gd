@tool
class_name CloudNoiseGenerator
extends RefCounted

## Generates 3D noise textures for volumetric cloud rendering.
## Based on techniques from GPU Gems and Shadertoy cloud implementations.

const NOISE_SIZE := 128  # Resolution of each dimension

## Generate a 3D Worley noise texture for cloud shape
static func generate_shape_noise(size: int = NOISE_SIZE) -> ImageTexture3D:
	var images: Array[Image] = []

	# Pre-generate random points for Worley noise
	var num_cells := 4
	var points := _generate_worley_points(num_cells, size)

	for z in range(size):
		var img := Image.create(size, size, false, Image.FORMAT_RF)

		for y in range(size):
			for x in range(size):
				var pos := Vector3(x, y, z) / float(size)

				# Multi-octave Worley noise
				var worley1 := _worley_noise_3d(pos * 4.0, points, num_cells)
				var worley2 := _worley_noise_3d(pos * 8.0, points, num_cells)
				var worley3 := _worley_noise_3d(pos * 16.0, points, num_cells)

				# Perlin-Worley combination (inverted Worley for puffy clouds)
				var perlin := _perlin_noise_3d(pos * 8.0)
				var worley := worley1 * 0.625 + worley2 * 0.25 + worley3 * 0.125

				# Remap to get cloud-like shapes
				var value := _remap(perlin, worley - 1.0, 1.0, 0.0, 1.0)
				value = clamp(value, 0.0, 1.0)

				img.set_pixel(x, y, Color(value, value, value, 1.0))

		images.append(img)

		if z % 16 == 0:
			print("Generating shape noise: %d%%" % [int(float(z) / float(size) * 100.0)])

	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RF, size, size, size, false, images)
	return tex


## Generate a 3D detail noise texture for cloud erosion
static func generate_detail_noise(size: int = NOISE_SIZE / 2) -> ImageTexture3D:
	var images: Array[Image] = []

	var num_cells := 4
	var points := _generate_worley_points(num_cells, size)

	for z in range(size):
		var img := Image.create(size, size, false, Image.FORMAT_RF)

		for y in range(size):
			for x in range(size):
				var pos := Vector3(x, y, z) / float(size)

				# Higher frequency Worley for detail
				var worley1 := _worley_noise_3d(pos * 8.0, points, num_cells)
				var worley2 := _worley_noise_3d(pos * 16.0, points, num_cells)
				var worley3 := _worley_noise_3d(pos * 32.0, points, num_cells)

				var value := worley1 * 0.625 + worley2 * 0.25 + worley3 * 0.125
				value = clamp(value, 0.0, 1.0)

				img.set_pixel(x, y, Color(value, value, value, 1.0))

		images.append(img)

		if z % 8 == 0:
			print("Generating detail noise: %d%%" % [int(float(z) / float(size) * 100.0)])

	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RF, size, size, size, false, images)
	return tex


## Save generated noise textures to files
static func save_noise_textures(base_path: String) -> void:
	print("Generating cloud shape noise...")
	var shape := generate_shape_noise(64)  # Lower res for faster generation
	ResourceSaver.save(shape, base_path + "cloud_shape_noise.tres")
	print("Saved shape noise to: " + base_path + "cloud_shape_noise.tres")

	print("Generating cloud detail noise...")
	var detail := generate_detail_noise(32)  # Even lower for detail
	ResourceSaver.save(detail, base_path + "cloud_detail_noise.tres")
	print("Saved detail noise to: " + base_path + "cloud_detail_noise.tres")

	print("Cloud noise generation complete!")


# =============================================================================
# Private Helper Functions
# =============================================================================

static func _generate_worley_points(num_cells: int, size: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345  # Fixed seed for reproducibility

	var points := []
	var total_cells := num_cells * num_cells * num_cells

	for i in range(total_cells):
		var cell_x := i % num_cells
		var cell_y := (i / num_cells) % num_cells
		var cell_z := i / (num_cells * num_cells)

		var base := Vector3(cell_x, cell_y, cell_z) / float(num_cells)
		var offset := Vector3(
			rng.randf(),
			rng.randf(),
			rng.randf()
		) / float(num_cells)

		points.append(base + offset)

	return points


static func _worley_noise_3d(pos: Vector3, points: Array, num_cells: int) -> float:
	# Wrap position to [0, 1]
	pos = Vector3(
		fposmod(pos.x, 1.0),
		fposmod(pos.y, 1.0),
		fposmod(pos.z, 1.0)
	)

	var min_dist := 1.0

	# Check current cell and neighbors
	var cell := Vector3i(
		int(pos.x * num_cells),
		int(pos.y * num_cells),
		int(pos.z * num_cells)
	)

	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var neighbor := Vector3i(
					(cell.x + dx + num_cells) % num_cells,
					(cell.y + dy + num_cells) % num_cells,
					(cell.z + dz + num_cells) % num_cells
				)

				var idx := neighbor.x + neighbor.y * num_cells + neighbor.z * num_cells * num_cells
				if idx >= 0 and idx < points.size():
					var point: Vector3 = points[idx]

					# Handle wrapping
					var wrapped_point := point + Vector3(dx, dy, dz) / float(num_cells)
					if dx == -1 and cell.x == 0:
						wrapped_point.x -= 1.0
					elif dx == 1 and cell.x == num_cells - 1:
						wrapped_point.x += 1.0
					if dy == -1 and cell.y == 0:
						wrapped_point.y -= 1.0
					elif dy == 1 and cell.y == num_cells - 1:
						wrapped_point.y += 1.0
					if dz == -1 and cell.z == 0:
						wrapped_point.z -= 1.0
					elif dz == 1 and cell.z == num_cells - 1:
						wrapped_point.z += 1.0

					var dist := pos.distance_to(wrapped_point)
					min_dist = min(min_dist, dist)

	# Invert for cloud-like shapes (puffy in center, thin at edges)
	return 1.0 - min_dist * num_cells


static func _perlin_noise_3d(pos: Vector3) -> float:
	# Simple 3D Perlin noise approximation using gradient noise
	var p := Vector3(floor(pos.x), floor(pos.y), floor(pos.z))
	var f := Vector3(
		pos.x - p.x,
		pos.y - p.y,
		pos.z - p.z
	)

	# Smoothstep
	f = f * f * (Vector3.ONE * 3.0 - f * 2.0)

	# Hash corners
	var n := p.x + p.y * 157.0 + p.z * 113.0

	var h000 := _hash(n)
	var h100 := _hash(n + 1.0)
	var h010 := _hash(n + 157.0)
	var h110 := _hash(n + 158.0)
	var h001 := _hash(n + 113.0)
	var h101 := _hash(n + 114.0)
	var h011 := _hash(n + 270.0)
	var h111 := _hash(n + 271.0)

	# Trilinear interpolation
	var x00 := lerp(h000, h100, f.x)
	var x10 := lerp(h010, h110, f.x)
	var x01 := lerp(h001, h101, f.x)
	var x11 := lerp(h011, h111, f.x)

	var y0 := lerp(x00, x10, f.y)
	var y1 := lerp(x01, x11, f.y)

	return lerp(y0, y1, f.z)


static func _hash(n: float) -> float:
	# fract equivalent: get fractional part (value - floor(value))
	var v := sin(n) * 43758.5453123
	return v - floor(v)


static func _remap(value: float, old_min: float, old_max: float, new_min: float, new_max: float) -> float:
	return new_min + (value - old_min) * (new_max - new_min) / (old_max - old_min)
