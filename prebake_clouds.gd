extends SceneTree

## Run from command line to prebake cloud noise textures:
## godot --headless --script res://prebake_clouds.gd
##
## This creates image slices that get loaded and combined into 3D textures at runtime.

const OUTPUT_PATH := "res://addons/sky_3d/assets/resources/cloud_noise/"
const SHAPE_RESOLUTION := 64
const DETAIL_RESOLUTION := 32


func _init() -> void:
	print("============================================================")
	print("Cloud Noise Prebaker (Headless)")
	print("============================================================")

	# Ensure output directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_PATH))

	var start_time := Time.get_ticks_msec()

	# Generate and save shape noise slices
	print("\n[1/2] Generating shape noise (%dx%dx%d)..." % [SHAPE_RESOLUTION, SHAPE_RESOLUTION, SHAPE_RESOLUTION])
	_generate_and_save_slices("shape", SHAPE_RESOLUTION)

	# Generate and save detail noise slices
	print("\n[2/2] Generating detail noise (%dx%dx%d)..." % [DETAIL_RESOLUTION, DETAIL_RESOLUTION, DETAIL_RESOLUTION])
	_generate_and_save_detail_slices("detail", DETAIL_RESOLUTION)

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0

	print("\n============================================================")
	print("Prebaking complete! (%.1f seconds)" % elapsed)
	print("============================================================")

	quit(0)


func _generate_and_save_slices(name: String, size: int) -> void:
	var num_cells := 4
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	var points := []
	var total_cells := num_cells * num_cells * num_cells
	for i in range(total_cells):
		var cell_x := i % num_cells
		var cell_y := (i / num_cells) % num_cells
		var cell_z := i / (num_cells * num_cells)
		var base := Vector3(cell_x, cell_y, cell_z) / float(num_cells)
		var offset := Vector3(rng.randf(), rng.randf(), rng.randf()) / float(num_cells)
		points.append(base + offset)

	for z in range(size):
		var img := Image.create(size, size, false, Image.FORMAT_RF)

		for y in range(size):
			for x in range(size):
				var pos := Vector3(x, y, z) / float(size)

				var worley1 := _worley_noise_3d(pos * 4.0, points, num_cells)
				var worley2 := _worley_noise_3d(pos * 8.0, points, num_cells)
				var worley3 := _worley_noise_3d(pos * 16.0, points, num_cells)

				var perlin := _perlin_noise_3d(pos * 8.0)
				var worley := worley1 * 0.625 + worley2 * 0.25 + worley3 * 0.125

				var value := _remap(perlin, worley - 1.0, 1.0, 0.0, 1.0)
				value = clamp(value, 0.0, 1.0)

				img.set_pixel(x, y, Color(value, value, value, 1.0))

		# Save slice as .exr (supports float data)
		var slice_path := OUTPUT_PATH + "%s_%03d.exr" % [name, z]
		img.save_exr(ProjectSettings.globalize_path(slice_path))

		if z % 16 == 0:
			print("  %s: %d%%" % [name, int(float(z) / float(size) * 100.0)])

	# Save metadata
	var meta := {
		"size": size,
		"slices": size,
		"format": "exr"
	}
	var meta_file := FileAccess.open(OUTPUT_PATH + name + "_meta.json", FileAccess.WRITE)
	meta_file.store_string(JSON.stringify(meta))
	meta_file.close()
	print("  Saved %d slices to %s" % [size, OUTPUT_PATH])


func _generate_and_save_detail_slices(name: String, size: int) -> void:
	var num_cells := 4
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	var points := []
	var total_cells := num_cells * num_cells * num_cells
	for i in range(total_cells):
		var cell_x := i % num_cells
		var cell_y := (i / num_cells) % num_cells
		var cell_z := i / (num_cells * num_cells)
		var base := Vector3(cell_x, cell_y, cell_z) / float(num_cells)
		var offset := Vector3(rng.randf(), rng.randf(), rng.randf()) / float(num_cells)
		points.append(base + offset)

	for z in range(size):
		var img := Image.create(size, size, false, Image.FORMAT_RF)

		for y in range(size):
			for x in range(size):
				var pos := Vector3(x, y, z) / float(size)

				var worley1 := _worley_noise_3d(pos * 8.0, points, num_cells)
				var worley2 := _worley_noise_3d(pos * 16.0, points, num_cells)
				var worley3 := _worley_noise_3d(pos * 32.0, points, num_cells)

				var value := worley1 * 0.625 + worley2 * 0.25 + worley3 * 0.125
				value = clamp(value, 0.0, 1.0)

				img.set_pixel(x, y, Color(value, value, value, 1.0))

		var slice_path := OUTPUT_PATH + "%s_%03d.exr" % [name, z]
		img.save_exr(ProjectSettings.globalize_path(slice_path))

		if z % 8 == 0:
			print("  %s: %d%%" % [name, int(float(z) / float(size) * 100.0)])

	var meta := {
		"size": size,
		"slices": size,
		"format": "exr"
	}
	var meta_file := FileAccess.open(OUTPUT_PATH + name + "_meta.json", FileAccess.WRITE)
	meta_file.store_string(JSON.stringify(meta))
	meta_file.close()
	print("  Saved %d slices to %s" % [size, OUTPUT_PATH])


func _worley_noise_3d(pos: Vector3, points: Array, num_cells: int) -> float:
	pos = Vector3(fposmod(pos.x, 1.0), fposmod(pos.y, 1.0), fposmod(pos.z, 1.0))
	var min_dist := 1.0
	var cell := Vector3i(int(pos.x * num_cells), int(pos.y * num_cells), int(pos.z * num_cells))

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
					var wrapped_point := point + Vector3(dx, dy, dz) / float(num_cells)
					if dx == -1 and cell.x == 0: wrapped_point.x -= 1.0
					elif dx == 1 and cell.x == num_cells - 1: wrapped_point.x += 1.0
					if dy == -1 and cell.y == 0: wrapped_point.y -= 1.0
					elif dy == 1 and cell.y == num_cells - 1: wrapped_point.y += 1.0
					if dz == -1 and cell.z == 0: wrapped_point.z -= 1.0
					elif dz == 1 and cell.z == num_cells - 1: wrapped_point.z += 1.0
					min_dist = min(min_dist, pos.distance_to(wrapped_point))

	return 1.0 - min_dist * num_cells


func _perlin_noise_3d(pos: Vector3) -> float:
	var p := Vector3(floorf(pos.x), floorf(pos.y), floorf(pos.z))
	var f := Vector3(pos.x - p.x, pos.y - p.y, pos.z - p.z)
	f = f * f * (Vector3.ONE * 3.0 - f * 2.0)
	var n: float = p.x + p.y * 157.0 + p.z * 113.0

	var h000: float = _hash(n)
	var h100: float = _hash(n + 1.0)
	var h010: float = _hash(n + 157.0)
	var h110: float = _hash(n + 158.0)
	var h001: float = _hash(n + 113.0)
	var h101: float = _hash(n + 114.0)
	var h011: float = _hash(n + 270.0)
	var h111: float = _hash(n + 271.0)

	var x00: float = lerpf(h000, h100, f.x)
	var x10: float = lerpf(h010, h110, f.x)
	var x01: float = lerpf(h001, h101, f.x)
	var x11: float = lerpf(h011, h111, f.x)

	var y0: float = lerpf(x00, x10, f.y)
	var y1: float = lerpf(x01, x11, f.y)

	return lerpf(y0, y1, f.z)


func _hash(n: float) -> float:
	var v := sin(n) * 43758.5453123
	return v - floor(v)


func _remap(value: float, old_min: float, old_max: float, new_min: float, new_max: float) -> float:
	return new_min + (value - old_min) * (new_max - new_min) / (old_max - old_min)
