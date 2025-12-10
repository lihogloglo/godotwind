## Debug script to find exactly where NIF parsing goes wrong
## Run with: godot --headless --script res://tests/debug_nif_parse.gd
extends SceneTree

const BSAReader := preload("res://src/core/bsa/bsa_reader.gd")
const NIFReader := preload("res://src/core/nif/nif_reader.gd")
const NIFDefs := preload("res://src/core/nif/nif_defs.gd")
const NIFSkeletonBuilder := preload("res://src/core/nif/nif_skeleton_builder.gd")

func _init():
	print("=" .repeat(60))
	print("NIF PARSE DEBUG")
	print("=" .repeat(60))

	var bsa_path := _find_morrowind_bsa()
	if bsa_path.is_empty():
		print("ERROR: Could not find Morrowind.bsa")
		quit(1)
		return

	var bsa := BSAReader.new()
	print("Trying to open: %s" % bsa_path)
	print("File exists: %s" % FileAccess.file_exists(bsa_path))
	var open_result := bsa.open(bsa_path)
	if open_result != OK:
		print("ERROR: Could not open BSA - error code: %d" % open_result)
		quit(1)
		return
	print("BSA opened: %d files" % bsa.get_file_count())

	# Try to load the problematic file
	# Note: Morrowind uses different naming - base_anim_female.1st.nif is the first person version
	var test_file := "meshes\\base_anim_female.1st.nif"

	if not bsa.has_file(test_file):
		print("ERROR: File not found: %s" % test_file)
		# Try listing some files that match 'base_anim'
		print("Looking for similar files...")
		for f in bsa.get_file_list():
			if f.name.containsn("base_anim"):
				print("  Found: %s" % f.name)
		quit(1)
		return

	var data := bsa.extract_file(test_file)
	print("File size: %d bytes" % data.size())

	var reader := NIFReader.new()
	reader.debug_mode = false  # Disable verbose logging for cleaner output

	var result := reader.load_buffer(data)

	if result == OK:
		print("SUCCESS: Parsed %d records" % reader.get_num_records())

		# Count record types for debugging
		var skin_instances := 0
		var skin_data := 0
		var keyframe_controllers := 0
		var keyframe_data := 0
		var skinned_geom := 0

		for record in reader.records:
			if record.record_type == "NiSkinInstance":
				skin_instances += 1
			elif record.record_type == "NiSkinData":
				skin_data += 1
			elif record.record_type == "NiKeyframeController":
				keyframe_controllers += 1
			elif record.record_type == "NiKeyframeData":
				keyframe_data += 1

			if record is NIFDefs.NiGeometry:
				var geom := record as NIFDefs.NiGeometry
				if geom.skin_index >= 0:
					skinned_geom += 1

		print("")
		print("Record summary:")
		print("  NiSkinInstance: %d" % skin_instances)
		print("  NiSkinData: %d" % skin_data)
		print("  Skinned geometry: %d" % skinned_geom)
		print("  NiKeyframeController: %d" % keyframe_controllers)
		print("  NiKeyframeData: %d" % keyframe_data)

		# Test skeleton building if we have skinning data
		if skin_instances > 0:
			print("")
			print("Testing skeleton building...")
			var skin_instance: NIFDefs.NiSkinInstance = null
			for record in reader.records:
				if record is NIFDefs.NiSkinInstance:
					skin_instance = record
					break

			if skin_instance:
				var builder := NIFSkeletonBuilder.new()
				builder.init(reader)
				builder.debug_mode = true

				print("Building skeleton from NiSkinInstance:")
				print("  data_index: %d" % skin_instance.data_index)
				print("  root_index: %d" % skin_instance.root_index)
				print("  bone_indices: %d bones" % skin_instance.bone_indices.size())

				var skeleton := builder.build_skeleton(skin_instance)
				if skeleton:
					print("SUCCESS: Built skeleton with %d bones" % skeleton.get_bone_count())

					# Print bone info
					for i in range(mini(skeleton.get_bone_count(), 10)):
						var bone_name := skeleton.get_bone_name(i)
						var rest := skeleton.get_bone_rest(i)
						var pos := rest.origin
						var rot := rest.basis.get_euler() * 180.0 / PI  # to degrees
						print("  Bone %2d: %-20s pos=(%.2f, %.2f, %.2f) rot=(%.1f, %.1f, %.1f)" % [
							i, bone_name, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z
						])

					if skeleton.get_bone_count() > 10:
						print("  ... and %d more bones" % (skeleton.get_bone_count() - 10))

					skeleton.free()
				else:
					print("FAILED: Could not build skeleton")
	else:
		print("FAILED: Error code %d" % result)

	quit(0 if result == OK else 1)


func _find_morrowind_bsa() -> String:
	var possible_paths := [
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"C:/Program Files/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"D:/Games/Morrowind/Data Files/Morrowind.bsa",
		"D:/SteamLibrary/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"E:/SteamLibrary/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
	]
	# Also check with backslashes
	possible_paths.append("C:\\Program Files (x86)\\Steam\\steamapps\\common\\Morrowind\\Data Files\\Morrowind.bsa")

	for path in possible_paths:
		if FileAccess.file_exists(path):
			return path

	return ""
