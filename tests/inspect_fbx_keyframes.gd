extends SceneTree

func _init() -> void:
	print("\n=== FBX Keyframe Inspection ===\n")

	var fbx_path := "res://assets/characters/mixamo/Walking.fbx"
	print("Loading: %s" % fbx_path)

	var scene: PackedScene = load(fbx_path)
	if not scene:
		print("ERROR: Failed to load FBX")
		quit(1)
		return

	var root := scene.instantiate()
	if not root:
		print("ERROR: Failed to instantiate scene")
		quit(1)
		return

	# Find AnimationPlayer
	var anim_player: AnimationPlayer = null
	for child in root.get_children():
		if child is AnimationPlayer:
			anim_player = child
			break
		for grandchild in child.get_children():
			if grandchild is AnimationPlayer:
				anim_player = grandchild
				break
		if anim_player:
			break

	if not anim_player:
		print("ERROR: No AnimationPlayer found")
		quit(1)
		return

	print("AnimationPlayer found: %s" % anim_player.name)
	print("Libraries: %d" % anim_player.get_animation_library_list().size())

	for lib_name in anim_player.get_animation_library_list():
		var lib := anim_player.get_animation_library(lib_name)
		print("\nLibrary '%s':" % lib_name)
		print("  Animations: %d" % lib.get_animation_list().size())

		for anim_name in lib.get_animation_list():
			var anim := lib.get_animation(anim_name)
			print("\n  Animation '%s':" % anim_name)
			print("    Length: %.2fs" % anim.length)
			print("    Tracks: %d" % anim.get_track_count())

			# Check first 3 tracks
			for i in min(3, anim.get_track_count()):
				var path := anim.track_get_path(i)
				var track_type := anim.track_get_type(i)
				var key_count := anim.track_get_key_count(i)
				var type_str := ""
				match track_type:
					Animation.TYPE_POSITION_3D: type_str = "Position3D"
					Animation.TYPE_ROTATION_3D: type_str = "Rotation3D"
					Animation.TYPE_SCALE_3D: type_str = "Scale3D"
					_: type_str = "Other"

				print("      Track %d: %s (%s) - %d keyframes" % [i, path, type_str, key_count])

				# Sample first 5 keyframes if they exist
				if key_count > 1:
					print("        First 5 keyframe times:")
					for k in min(5, key_count):
						var time := anim.track_get_key_time(i, k)
						print("          [%d] t=%.3fs" % [k, time])

	root.queue_free()
	print("\n=== Inspection Complete ===\n")
	quit(0)
