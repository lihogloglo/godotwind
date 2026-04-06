## Screenshot capture tool
##
## Launches a target scene, waits for it to stabilize, saves a PNG of the
## viewport, then quits. Used for visual regression testing.
##
## Usage:
##   godot --path <project> res://tests/tools/capture_screenshot.tscn -- \
##       --target res://tests/visual/test_dialogue.tscn \
##       --out /tmp/shots/test_dialogue.png \
##       --wait 6.0 \
##       --key J        (optional: press a key after the wait, e.g. to open a panel)
##
## ## Why the window flags matter
##
## This tool sets WINDOW_FLAG_MOUSE_PASSTHROUGH + WINDOW_FLAG_NO_FOCUS at the
## start of _ready(). DO NOT REMOVE unless you understand the consequences:
## without these flags, if the user is using the mouse/keyboard while the
## capture runs, OS input bleeds into the Godot window and perturbs scene
## state. This actually bit us during Phase A theme extraction — the cursor
## happened to be over a RichTextLabel [url] link in test_dialogue, and the
## meta_clicked signal fired mid-capture, producing a screenshot of the wrong
## dialogue state. The flags isolate the capture window from the host desktop
## so scene state is deterministic regardless of what the user is doing.
##
## If --target is missing, exits immediately.
extends Node


func _ready() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	if not args.has("target"):
		push_error("capture_screenshot: --target required")
		get_tree().quit(1)
		return
	var target_path: String = args["target"]
	var out_path: String = args.get("out", "user://screenshot.png")
	var wait_seconds: float = float(args.get("wait", "2.0"))

	# CRITICAL: block OS-level input from reaching the scene.
	# Without this, if the user is using the mouse/keyboard while capture runs,
	# clicks and keypresses reach the Godot window and perturb scene state (e.g.
	# triggering RichTextLabel meta_clicked on a URL the cursor happens to be over).
	# Making the window non-focusable and mouse-passthrough isolates the scene
	# from the host desktop for the duration of the capture.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)

	# Load the target scene
	var packed: PackedScene = load(target_path) as PackedScene
	if packed == null:
		push_error("capture_screenshot: failed to load %s" % target_path)
		get_tree().quit(1)
		return

	var instance := packed.instantiate()
	add_child(instance)

	# Wait for the scene to settle
	await get_tree().create_timer(wait_seconds).timeout

	# Optionally simulate a key press before capturing (for scenes that need input
	# to reach their visible state — e.g. test_journal needs J to open the panel)
	if args.has("key"):
		var key_name: String = args["key"]
		var keycode := OS.find_keycode_from_string(key_name)
		if keycode != 0:
			# Set both keycode AND physical_keycode — InputMap actions bound
			# via `physical_keycode` (the project.godot default for new bindings)
			# will not match if only keycode is set.
			var ev_down := InputEventKey.new()
			ev_down.keycode = keycode
			ev_down.physical_keycode = keycode
			ev_down.pressed = true
			Input.parse_input_event(ev_down)
			await get_tree().process_frame
			await get_tree().create_timer(0.3).timeout
			var ev_up := InputEventKey.new()
			ev_up.keycode = keycode
			ev_up.physical_keycode = keycode
			ev_up.pressed = false
			Input.parse_input_event(ev_up)
			await get_tree().create_timer(0.8).timeout
		else:
			push_warning("capture_screenshot: unknown key '%s'" % key_name)

	# Flush any pending draws
	await RenderingServer.frame_post_draw

	# Capture viewport
	var viewport := get_viewport()
	var img: Image = viewport.get_texture().get_image()
	if img == null:
		push_error("capture_screenshot: failed to grab viewport image")
		get_tree().quit(1)
		return

	# Ensure parent directory exists
	var dir_path := out_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var err := img.save_png(out_path)
	if err != OK:
		push_error("capture_screenshot: save_png failed (%d) for %s" % [err, out_path])
		get_tree().quit(1)
		return

	print("capture_screenshot: saved %s (%dx%d)" % [out_path, img.get_width(), img.get_height()])
	get_tree().quit(0)


static func _parse_args(argv: PackedStringArray) -> Dictionary:
	var result := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--"):
			var key := a.substr(2)
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				result[key] = argv[i + 1]
				i += 2
				continue
			result[key] = "true"
		i += 1
	return result
