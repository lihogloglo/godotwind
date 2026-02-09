extends SceneTree

func _init() -> void:
	await process_frame
	await process_frame

	var bsa = root.get_node_or_null("/root/BSAManager")
	if not bsa:
		print("No BSAManager")
		quit(1)
		return

	# Load archives
	var data_path: String = root.get_node("/root/SettingsManager").get_data_path()
	if data_path.is_empty():
		data_path = root.get_node("/root/SettingsManager").auto_detect_installation()
	bsa.load_archives_from_directory(data_path)

	# Search for dark elf body parts
	var results = bsa.find_files("meshes\\b\\b_n_dark*")
	print("=== Dark Elf body parts (%d) ===" % results.size())
	for r in results:
		print("  %s" % r["path"])

	# Also search for any chest/hand body parts
	print("\n=== Chest parts ===")
	results = bsa.find_files("meshes\\b\\*chest*")
	for r in results:
		var path: String = r["path"]
		if "dark" in path.to_lower():
			print("  %s" % path)

	print("\n=== Hand parts ===")
	results = bsa.find_files("meshes\\b\\*hand*")
	for r in results:
		var path: String = r["path"]
		if "dark" in path.to_lower():
			print("  %s" % path)

	quit(0)
