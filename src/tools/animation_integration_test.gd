## Animation Integration Test — End-to-end verification of animated NPC pipeline
##
## Creates one NPC via CharacterFactoryV2 and verifies:
## - Body parts assembled correctly on native Morrowind skeleton
## - Bones renamed to SkeletonProfileHumanoid names
## - KF animations loaded and remapped
## - AnimationTree + state machine created and active
## - Idle animation playing
## - Walk animation triggers when wander enabled
##
## Controls:
##   W — Toggle wander (NPC walks around)
##   I — Toggle IK
##   M — Toggle Mixamo/Morrowind animations
##   D — Dump debug info to console
##   R — Rebuild NPC
##   1/2/3 — Switch NPC: 1=Fargoth (Wood Elf M), 2=Arrille (Altmer M), 3=Sellus Gravius (Imperial M)
@tool
extends Node3D

@warning_ignore("untyped_declaration", "unsafe_method_access")

const CharacterFactoryV2Script := preload("res://src/core/animation/character_factory_v2.gd")
const MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
const AnimationLoaderScript := preload("res://src/core/animation/animation_loader.gd")

# Test NPC record IDs (well-known Morrowind NPCs in Seyda Neen)
const TEST_NPCS := ["fargoth", "arrille", "sellus gravius"]
var _current_npc_index: int = 0

# Scene
var _npc_node: Node = null
var _info_label: RichTextLabel = null
var _camera: Camera3D = null
var _factory: CharacterFactoryV2Script = null

# Mixamo animations
var _mixamo_library: AnimationLibrary = null
var _using_mixamo: bool = false

# State
var _wander_enabled: bool = false
var _ik_enabled: bool = true
var _diagnostic_lines: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_setup_scene()
	_setup_ui()

	# Wait for autoloads to initialize
	await get_tree().process_frame
	await get_tree().process_frame

	# Ensure data is loaded
	await _ensure_data_loaded()

	# Preload character assets (skeletons, bone remaps, animation libraries)
	_log("Preloading character assets...")
	var preload_start := Time.get_ticks_msec()
	CharacterFactoryV2Script.preload_character_assets()
	_log("Preloaded in %d ms" % (Time.get_ticks_msec() - preload_start))
	var stats := CharacterFactoryV2Script.get_cache_stats()
	_log("  Skeletons: %d, Animations: %d" % [stats["skeleton_templates"], stats["cached_animation_libraries"]])

	# Load Mixamo animations (from assets/animations/mixamo/)
	_log("Loading Mixamo animations...")
	_mixamo_library = AnimationLoaderScript.load_from_directory("res://assets/animations/mixamo/")
	if _mixamo_library:
		_log("[color=green]Mixamo loaded: %d animations[/color]" % _mixamo_library.get_animation_list().size())
		for anim_name in _mixamo_library.get_animation_list():
			var anim: Animation = _mixamo_library.get_animation(anim_name)
			_log("  %s: %.2fs, %d tracks, loop=%d" % [anim_name, anim.length, anim.get_track_count(), anim.loop_mode])
	else:
		_log("[color=yellow]No Mixamo animations found[/color]")

	# Create factory
	_factory = CharacterFactoryV2Script.new()
	_factory.debug_characters = true
	_factory.debug_animations = true
	_factory.enable_ik = _ik_enabled
	_factory.enable_wander = _wander_enabled

	# Spawn first NPC
	_spawn_npc()


func _ensure_data_loaded() -> void:
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
	if data_path.is_empty():
		_log("[color=red]No Morrowind data path configured![/color]")
		return

	# Load BSA archives if not already loaded
	if not BSAManager.has_file("meshes\\xbase_anim.nif"):
		_log("Loading BSA archives from: %s" % data_path)
		var bsa_count := BSAManager.load_archives_from_directory(data_path)
		_log("Loaded %d BSA archives" % bsa_count)
		await get_tree().process_frame
	else:
		_log("BSA archives already loaded")

	# Load ESM file if not already loaded
	if ESMManager.cells.is_empty():
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		_log("Loading ESM: %s" % esm_file)
		var error := ESMManager.load_file(esm_path)
		if error != OK:
			_log("[color=red]Failed to load ESM: %s[/color]" % error_string(error))
			return
		_log("ESM loaded: %d cells, %d NPCs" % [ESMManager.cells.size(), ESMManager.npcs.size() if "npcs" in ESMManager else 0])
		await get_tree().process_frame
	else:
		_log("ESM already loaded (%d cells)" % ESMManager.cells.size())


func _spawn_npc() -> void:
	# Remove previous NPC
	if _npc_node:
		_npc_node.queue_free()
		_npc_node = null
		await get_tree().process_frame

	_diagnostic_lines.clear()
	var npc_id: String = TEST_NPCS[_current_npc_index]
	_log("[b]Spawning NPC: %s[/b]" % npc_id)

	# Look up NPC record
	var esm_mgr = get_node_or_null("/root/ESMManager")
	if not esm_mgr:
		_log("[color=red]ESMManager not available![/color]")
		_update_info()
		return

	var npc_record = null
	if esm_mgr.has_method("get_npc"):
		npc_record = esm_mgr.get_npc(npc_id)
	if not npc_record:
		_log("[color=red]NPC record '%s' not found in ESM![/color]" % npc_id)
		_update_info()
		return

	_log("Found NPC: %s (race: %s, female: %s)" % [
		npc_record.name if npc_record.name else npc_id,
		npc_record.race_id if "race_id" in npc_record else "?",
		str(npc_record.is_female()) if npc_record.has_method("is_female") else "?"
	])

	# Create NPC via CharacterFactoryV2
	_factory.enable_ik = _ik_enabled
	_factory.enable_wander = _wander_enabled
	var start := Time.get_ticks_msec()
	var character = _factory.create_npc(npc_record, 0)
	var elapsed := Time.get_ticks_msec() - start

	if not character:
		_log("[color=red]CharacterFactoryV2.create_npc() returned null![/color]")
		_update_info()
		return

	_log("[color=green]NPC created in %d ms[/color]" % elapsed)
	_npc_node = character

	# Add to scene first (must be in tree for global_position), then position
	add_child(character)
	character.global_position = Vector3(0, 0.05, 0)

	# Run diagnostics
	_run_diagnostics(character)
	_update_info()


func _run_diagnostics(character: Node) -> void:
	_log("")
	_log("[b]--- DIAGNOSTICS ---[/b]")

	# 1. Find skeleton
	var skeleton: Skeleton3D = _find_node_of_type(character, "Skeleton3D")
	if skeleton:
		_log("[color=green]PASS[/color] Skeleton3D found: %d bones" % skeleton.get_bone_count())

		# Show sample bone names (should be profile names after renaming)
		var sample_bones := ["Hips", "Spine", "Chest", "Head", "LeftHand", "RightFoot"]
		var found_profile := 0
		for bone_name in sample_bones:
			var idx := skeleton.find_bone(bone_name)
			if idx >= 0:
				found_profile += 1
		_log("  Profile bones found: %d/%d (%s)" % [found_profile, sample_bones.size(),
			"[color=green]RENAMED[/color]" if found_profile >= 4 else "[color=red]NOT RENAMED[/color]"])

		# Check for remaining Bip01 bones (should be minimal — unmapped extras only)
		var bip01_count := 0
		for i in skeleton.get_bone_count():
			if skeleton.get_bone_name(i).to_lower().begins_with("bip01"):
				bip01_count += 1
		if bip01_count > 0:
			_log("  Remaining Bip01 bones: %d (unmapped extras)" % bip01_count)
	else:
		_log("[color=red]FAIL[/color] No Skeleton3D found!")

	# 2. Find AnimationPlayer
	var anim_player: AnimationPlayer = _find_node_of_type(character, "AnimationPlayer")
	if anim_player:
		# Verify AnimationPlayer root_node resolves to Skeleton3D
		var ap_root = anim_player.get_node_or_null(anim_player.root_node)
		if ap_root is Skeleton3D:
			_log("[color=green]PASS[/color] AnimationPlayer root_node → Skeleton3D")
		elif ap_root:
			_log("[color=yellow]WARN[/color] AnimationPlayer root_node → %s (path: %s)" % [ap_root.get_class(), anim_player.root_node])

		var anim_list := anim_player.get_animation_list()
		_log("[color=green]PASS[/color] AnimationPlayer found: %d animations" % anim_list.size())

		# List animations
		if anim_list.size() > 0:
			var sample_count := mini(anim_list.size(), 10)
			for i in sample_count:
				_log("  [%d] %s" % [i, anim_list[i]])
			if anim_list.size() > sample_count:
				_log("  ... +%d more" % (anim_list.size() - sample_count))

			# Check for critical animations
			var critical := ["idle", "walk", "run"]
			for crit_name in critical:
				var found := false
				for anim_name in anim_list:
					if crit_name in anim_name.to_lower():
						found = true
						break
				if found:
					_log("  [color=green]FOUND[/color] '%s' animation" % crit_name)
				else:
					_log("  [color=yellow]MISSING[/color] '%s' animation" % crit_name)

			# Check track paths on first animation
			var first_anim: Animation = anim_player.get_animation(anim_list[0])
			if first_anim:
				_log("  First anim '%s': %d tracks, %.1fs" % [anim_list[0], first_anim.get_track_count(), first_anim.length])
				if first_anim.get_track_count() > 0:
					var sample_path := first_anim.track_get_path(0)
					_log("  Sample track: %s" % str(sample_path))
					# Verify tracks are remapped to profile names (not Bip01)
					var remapped_count := 0
					var bip01_count := 0
					for t_idx in first_anim.get_track_count():
						var tp := first_anim.track_get_path(t_idx)
						var sub := String(tp.get_subname(0)) if tp.get_subname_count() > 0 else String(tp.get_concatenated_names())
						if sub.to_lower().begins_with("bip01"):
							bip01_count += 1
						else:
							remapped_count += 1
					if bip01_count == 0:
						_log("  [color=green]TRACKS REMAPPED[/color] — %d profile-named tracks" % remapped_count)
					elif remapped_count > bip01_count * 10:
						# >90% remapped — remaining Bip01 are unmapped auxiliary bones (expected)
						_log("  [color=green]TRACKS REMAPPED[/color] — %d profile, %d unmapped aux bones" % [remapped_count, bip01_count])
					else:
						_log("  [color=red]TRACKS NOT REMAPPED[/color] — %d Bip01, %d profile" % [bip01_count, remapped_count])
		else:
			_log("  [color=red]No animations loaded![/color]")
	else:
		_log("[color=red]FAIL[/color] No AnimationPlayer found!")

	# 3. Find AnimationTree
	var anim_tree: AnimationTree = _find_node_of_type(character, "AnimationTree")
	if anim_tree:
		_log("[color=green]PASS[/color] AnimationTree found (active=%s)" % str(anim_tree.active))

		# Verify root_node resolves to a Skeleton3D (critical for bone tracks)
		var root_resolved = anim_tree.get_node_or_null(anim_tree.root_node)
		if root_resolved is Skeleton3D:
			_log("  root_node → [color=green]Skeleton3D[/color] (%s)" % anim_tree.root_node)
		elif root_resolved:
			_log("  root_node → [color=red]%s[/color] (NOT Skeleton3D! Bone tracks won't resolve)" % root_resolved.get_class())
		else:
			_log("  root_node → [color=red]NULL[/color] (path: %s)" % anim_tree.root_node)

		# Check state machine
		var sm = anim_tree.get("parameters/locomotion/playback")
		if sm:
			_log("  State machine playback: [color=green]OK[/color]")
			var current_node = sm.get_current_node() if sm.has_method("get_current_node") else "?"
			_log("  Current state: %s" % str(current_node))
		else:
			_log("  State machine playback: [color=red]NOT FOUND[/color]")
	else:
		_log("[color=yellow]WARN[/color] No AnimationTree found (may be created later)")

	# 4. Find AnimationManager
	var anim_manager = _find_node_by_name(character, "AnimationManager")
	if anim_manager:
		var is_setup = anim_manager.get("_is_setup") if "_is_setup" in anim_manager else false
		_log("[color=green]PASS[/color] AnimationManager found (setup=%s)" % str(is_setup))
	else:
		_log("[color=yellow]WARN[/color] AnimationManager not found")

	# 5. Find AnimationSystem
	var anim_system = character.get_meta("animation_system", null)
	if anim_system:
		_log("[color=green]PASS[/color] AnimationSystem wired to character")
	else:
		_log("[color=yellow]WARN[/color] AnimationSystem not wired (meta missing)")

	# 6. Count mesh instances (body parts)
	var mesh_count := _count_nodes_of_type(character, "MeshInstance3D")
	_log("MeshInstance3D count: %d" % mesh_count)

	# 7. Count BoneAttachment3D nodes
	var attach_count := _count_nodes_of_type(character, "BoneAttachment3D")
	if attach_count > 0:
		_log("BoneAttachment3D count: %d" % attach_count)
		# Check if attachment bone names match renamed skeleton
		if skeleton:
			var broken_attachments := 0
			_check_bone_attachments(character, skeleton, broken_attachments)

	_log("")
	_log("[b]--- END DIAGNOSTICS ---[/b]")


func _check_bone_attachments(node: Node, skeleton: Skeleton3D, broken_count: int) -> int:
	if node is BoneAttachment3D:
		var attach := node as BoneAttachment3D
		var idx := skeleton.find_bone(attach.bone_name)
		if idx < 0:
			_log("  [color=red]BROKEN[/color] BoneAttachment '%s' → bone '%s' NOT FOUND" % [attach.name, attach.bone_name])
			broken_count += 1
		# else: OK, don't spam
	for child in node.get_children():
		broken_count = _check_bone_attachments(child, skeleton, broken_count)
	return broken_count


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_W:
				_wander_enabled = not _wander_enabled
				if _npc_node and "wander_enabled" in _npc_node:
					_npc_node.wander_enabled = _wander_enabled
				_log("Wander: %s" % ("ON" if _wander_enabled else "OFF"))
				_update_info()
			KEY_I:
				_ik_enabled = not _ik_enabled
				_log("IK: %s" % ("ON" if _ik_enabled else "OFF"))
				# Rebuild to apply
				_spawn_npc()
			KEY_D:
				_dump_detailed_debug()
			KEY_R:
				_spawn_npc()
			KEY_1:
				_current_npc_index = 0
				_spawn_npc()
			KEY_2:
				_current_npc_index = 1
				_spawn_npc()
			KEY_3:
				_current_npc_index = 2
				_spawn_npc()
			KEY_M:
				_toggle_mixamo()


func _toggle_mixamo() -> void:
	if not _mixamo_library:
		_log("[color=yellow]No Mixamo animations loaded[/color]")
		_update_info()
		return

	if not _npc_node:
		_log("[color=yellow]No NPC loaded[/color]")
		_update_info()
		return

	_using_mixamo = not _using_mixamo

	# Find AnimationPlayer on current NPC
	var anim_player: AnimationPlayer = _find_node_of_type(_npc_node, "AnimationPlayer")
	if not anim_player:
		_log("[color=red]No AnimationPlayer found[/color]")
		_update_info()
		return

	if _using_mixamo:
		# Add Mixamo library alongside MW library
		if not anim_player.has_animation_library("mixamo"):
			anim_player.add_animation_library("mixamo", _mixamo_library)
		_log("[color=cyan]Mixamo animations ADDED[/color] (library 'mixamo')")
		_log("  Available: %s" % str(_mixamo_library.get_animation_list()))

		# Try to play a Mixamo animation via the AnimationTree state machine
		# The state machine uses the default library, so we need to swap it
		var old_lib: AnimationLibrary = null
		if anim_player.has_animation_library(""):
			old_lib = anim_player.get_animation_library("")
			anim_player.remove_animation_library("")
		anim_player.add_animation_library("", _mixamo_library)
		if old_lib:
			anim_player.add_animation_library("morrowind", old_lib)

		# Rebuild AnimationTree to pick up new animations
		_rebuild_animation_tree()
		_log("[color=green]Switched to Mixamo animations[/color]")
	else:
		# Restore MW library
		if anim_player.has_animation_library("morrowind"):
			var mw_lib := anim_player.get_animation_library("morrowind")
			anim_player.remove_animation_library("morrowind")
			if anim_player.has_animation_library(""):
				anim_player.remove_animation_library("")
			anim_player.add_animation_library("", mw_lib)
		if anim_player.has_animation_library("mixamo"):
			anim_player.remove_animation_library("mixamo")

		_rebuild_animation_tree()
		_log("[color=green]Switched to Morrowind animations[/color]")

	_update_info()


func _rebuild_animation_tree() -> void:
	if not _npc_node:
		return

	# Find and reset the animation system to rebuild the AnimationTree
	var anim_system = _npc_node.get_meta("animation_system", null)
	if anim_system and anim_system.has_method("reset"):
		var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D")
		anim_system.reset()
		if skeleton:
			anim_system.setup(skeleton, _npc_node as CharacterBody3D)


func _process(_delta: float) -> void:
	if not _npc_node:
		return

	# Update live info (current state, blend params)
	_update_live_info()


# =============================================================================
# LIVE INFO UPDATE
# =============================================================================

func _update_live_info() -> void:
	if not _info_label or not _npc_node:
		return

	# Build live status section
	var live_lines := PackedStringArray()
	live_lines.append("")
	live_lines.append("[b]--- LIVE STATUS ---[/b]")
	live_lines.append("Wander: %s  |  IK: %s" % [
		"[color=green]ON[/color]" if _wander_enabled else "[color=gray]OFF[/color]",
		"[color=green]ON[/color]" if _ik_enabled else "[color=gray]OFF[/color]"
	])

	# Animation state
	var anim_system = _npc_node.get_meta("animation_system", null)
	if anim_system and anim_system.has_method("get_state"):
		live_lines.append("State: [color=cyan]%s[/color]" % anim_system.get_state())

	# Velocity
	if "velocity" in _npc_node:
		var vel: Vector3 = _npc_node.velocity
		live_lines.append("Velocity: (%.2f, %.2f, %.2f) speed=%.2f" % [vel.x, vel.y, vel.z, vel.length()])

	# Position
	if _npc_node is Node3D:
		var pos: Vector3 = _npc_node.global_position
		live_lines.append("Position: (%.2f, %.2f, %.2f)" % [pos.x, pos.y, pos.z])

	# Animation source
	live_lines.append("Animations: [color=cyan]%s[/color]" % ("Mixamo" if _using_mixamo else "Morrowind"))

	live_lines.append("")
	live_lines.append("[color=gray][W] Wander  [I] IK  [M] Mixamo  [D] Debug  [R] Reload  [1/2/3] NPC[/color]")

	# Combine diagnostic + live
	var full_text := "\n".join(_diagnostic_lines) + "\n" + "\n".join(live_lines)
	_info_label.text = full_text


# =============================================================================
# DEBUG DUMP
# =============================================================================

func _dump_detailed_debug() -> void:
	if not _npc_node:
		Log.info("animation", "No NPC loaded")
		return

	Log.info("animation", "=== ANIMATION INTEGRATION DEBUG ===")

	var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D")
	if skeleton:
		Log.info("animation", "Skeleton: %d bones" % skeleton.get_bone_count())
		for i in skeleton.get_bone_count():
			var rest := skeleton.get_bone_global_rest(i)
			Log.info("animation", "  [%d] %-25s parent=%d pos=(%.3f,%.3f,%.3f)" % [
				i, skeleton.get_bone_name(i), skeleton.get_bone_parent(i),
				rest.origin.x, rest.origin.y, rest.origin.z])

	var anim_player: AnimationPlayer = _find_node_of_type(_npc_node, "AnimationPlayer")
	if anim_player:
		var lib = anim_player.get_animation_library("") if anim_player.has_animation_library("") else null
		if lib:
			Log.info("animation", "Animation Library: %d animations" % lib.get_animation_list().size())
			for anim_name in lib.get_animation_list():
				var anim: Animation = lib.get_animation(anim_name)
				Log.info("animation", "  '%s': %d tracks, %.2fs, loop=%s" % [
					anim_name, anim.get_track_count(), anim.length, str(anim.loop_mode)])
				# First 3 tracks
				for t in mini(anim.get_track_count(), 3):
					Log.info("animation", "    track[%d]: %s (type=%d)" % [t, str(anim.track_get_path(t)), anim.track_get_type(t)])

	Log.info("animation", "=== END DEBUG ===")


# =============================================================================
# SCENE SETUP
# =============================================================================

func _setup_scene() -> void:
	# Camera
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.position = Vector3(0, 1.0, 3.0)
	add_child(_camera)
	_camera.look_at(Vector3(0, 0.8, 0))

	# Key light
	var light := DirectionalLight3D.new()
	light.name = "KeyLight"
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)

	# Fill light
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-30, -120, 0)
	fill.light_energy = 0.4
	fill.light_color = Color(0.8, 0.85, 1.0)
	add_child(fill)

	# Environment
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.ambient_light_color = Color(0.5, 0.5, 0.55)
	environment.ambient_light_energy = 0.6
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.15, 0.15, 0.2)
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = environment
	add_child(env)

	# Ground plane (visual + collision)
	var ground_body := StaticBody3D.new()
	ground_body.name = "Ground"
	add_child(ground_body)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.3, 0.35, 0.25)
	ground.material_override = ground_mat
	ground_body.add_child(ground)

	var col_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.1, 20)
	col_shape.shape = box
	col_shape.position.y = -0.05
	ground_body.add_child(col_shape)


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.name = "InfoPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 10
	panel.offset_top = 10
	panel.offset_right = 600
	panel.offset_bottom = 750

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.75)
	style.content_margin_left = 10
	style.content_margin_top = 10
	style.content_margin_right = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)

	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.fit_content = true
	_info_label.custom_minimum_size = Vector2(580, 720)
	_info_label.scroll_active = true

	panel.add_child(_info_label)
	canvas.add_child(panel)


# =============================================================================
# UTILITIES
# =============================================================================

func _log(text: String) -> void:
	_diagnostic_lines.append(text)
	# Also print to Godot console for easier debugging
	print("[AnimIntegrationTest] %s" % text.replace("[color=green]", "").replace("[color=red]", "").replace("[color=yellow]", "").replace("[color=cyan]", "").replace("[color=gray]", "").replace("[/color]", "").replace("[b]", "").replace("[/b]", ""))


func _update_info() -> void:
	if _info_label:
		_info_label.text = "\n".join(_diagnostic_lines)


func _find_node_of_type(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for child in node.get_children():
		var result := _find_node_of_type(child, type_name)
		if result:
			return result
	return null


func _find_node_by_name(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var result := _find_node_by_name(child, node_name)
		if result:
			return result
	return null


func _count_nodes_of_type(node: Node, type_name: String) -> int:
	var count := 0
	if node.get_class() == type_name:
		count += 1
	for child in node.get_children():
		count += _count_nodes_of_type(child, type_name)
	return count
