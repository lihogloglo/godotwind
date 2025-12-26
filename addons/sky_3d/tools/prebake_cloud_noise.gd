@tool
extends EditorScript

## Prebake Cloud Noise Textures
##
## This script generates 3D noise textures for volumetric cloud rendering.
## Run this once from the editor (Script > Run) to generate the textures.
## After running, the textures will be saved to:
##   res://addons/sky_3d/assets/resources/cloud_shape_noise.tres
##   res://addons/sky_3d/assets/resources/cloud_detail_noise.tres

const OUTPUT_PATH := "res://addons/sky_3d/assets/resources/"

# Texture resolutions - higher = better quality but larger files and longer generation
const SHAPE_RESOLUTION := 64   # Shape noise (main cloud forms)
const DETAIL_RESOLUTION := 32  # Detail noise (fine erosion)


func _run() -> void:
	print("=" * 60)
	print("Cloud Noise Prebaker")
	print("=" * 60)

	# Ensure output directory exists
	var dir := DirAccess.open("res://addons/sky_3d/assets/")
	if dir and not dir.dir_exists("resources"):
		dir.make_dir("resources")

	var start_time := Time.get_ticks_msec()

	# Generate shape noise
	print("\n[1/2] Generating shape noise (%dx%dx%d)..." % [SHAPE_RESOLUTION, SHAPE_RESOLUTION, SHAPE_RESOLUTION])
	var shape_tex := CloudNoiseGenerator.generate_shape_noise(SHAPE_RESOLUTION)
	var shape_path := OUTPUT_PATH + "cloud_shape_noise.tres"
	var err := ResourceSaver.save(shape_tex, shape_path)
	if err == OK:
		print("  Saved: %s" % shape_path)
	else:
		push_error("  Failed to save shape noise: %d" % err)

	# Generate detail noise
	print("\n[2/2] Generating detail noise (%dx%dx%d)..." % [DETAIL_RESOLUTION, DETAIL_RESOLUTION, DETAIL_RESOLUTION])
	var detail_tex := CloudNoiseGenerator.generate_detail_noise(DETAIL_RESOLUTION)
	var detail_path := OUTPUT_PATH + "cloud_detail_noise.tres"
	err = ResourceSaver.save(detail_tex, detail_path)
	if err == OK:
		print("  Saved: %s" % detail_path)
	else:
		push_error("  Failed to save detail noise: %d" % err)

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0

	print("\n" + "=" * 60)
	print("Prebaking complete! (%.1f seconds)" % elapsed)
	print("=" * 60)
	print("\nTo use prebaked textures:")
	print("  1. Set 'Use Procedural Noise' to false in SkyDomeVolumetric")
	print("  2. The textures will be loaded automatically")
	print("\nNote: Re-import the project (Project > Reload Current Project)")
	print("      if the textures don't appear immediately.")
