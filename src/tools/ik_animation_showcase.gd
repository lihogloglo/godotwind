## IK + Animation Showcase — Demonstrates all IK features with Mixamo walk on a real NPC
##
## Spawns a Morrowind NPC via CharacterFactoryV2, loads Mixamo Walking animation,
## and showcases foot IK (bumpy terrain), look-at IK (orbiting orb around head),
## and hand IK (floating cube that follows the character) all working together
## on an infinite straight walkway with procedurally generated obstacles.
##
## Controls:
##   Z / W        — Walk forward (overrides auto-walk)
##   S            — Walk backward (overrides auto-walk)
##   (no input)   — Auto-walk forward infinitely
##   RMB drag     — Orbit camera
##   Scroll       — Zoom in/out
##   L-click drag — Move look orb or hand cube
##   Space        — Resume auto-motion for targets
##   1            — Toggle foot IK
##   2            — Toggle look-at IK
##   3            — Toggle hand IK
##   4            — Toggle walk (pause/resume NPC movement)
##   M            — Switch Mixamo/Morrowind animations
##   N            — Switch NPC (cycle presets)
##   D            — Dump debug info
@tool
extends Node3D

@warning_ignore("untyped_declaration", "unsafe_method_access")

const CharacterFactoryV2Script := preload("res://src/core/animation/character_factory_v2.gd")
const AnimationLoaderScript := preload("res://src/core/animation/animation_loader.gd")

# Test NPCs
const TEST_NPCS := ["fargoth", "arrille", "sellus gravius"]

# Straight-line walking
const WALK_TARGET_AHEAD := 20.0

# Ground strip
const GROUND_LENGTH := 500.0
const GROUND_WIDTH := 6.0

# Procedural terrain bumps (for foot IK)
const BUMP_SPACING := 2.5
const BUMP_ZONE_AHEAD := 40.0
const BUMP_ZONE_BEHIND := 20.0

# Scene objects
var _camera: Camera3D
var _npc_node: Node = null
var _factory: CharacterFactoryV2Script = null
var _info_label: RichTextLabel
var _look_orb: MeshInstance3D
var _hand_cube: MeshInstance3D

# Mixamo
var _mixamo_library: AnimationLibrary = null
var _using_mixamo: bool = false

# NPC state
var _current_npc_index: int = 0
var _walk_enabled: bool = true
var _walk_target_z: float = WALK_TARGET_AHEAD

# IK state
var _foot_ik_enabled: bool = true
var _look_ik_enabled: bool = true
var _hand_ik_enabled: bool = true

# Auto-motion
var _look_auto: bool = true
var _hand_auto: bool = true
var _time: float = 0.0

# Mouse drag
var _dragged_target: MeshInstance3D = null
var _drag_plane_y: float = 0.0
var _dragging: bool = false

# Camera orbit
var _yaw: float = 30.0
var _pitch: float = -20.0
var _distance: float = 6.0
var _orbiting: bool = false

# Direct look-at (applied in _process AFTER AnimationTree to avoid overwrite)
var _look_smooth_quat: Quaternion = Quaternion.IDENTITY
var _look_initialized: bool = false

# Log lines for info panel
var _log_lines: PackedStringArray = PackedStringArray()

# Procedural obstacle generation
var _bumps: Array[Node3D] = []
var _furthest_bump_z: float = 3.0
var _bump_mat: StandardMaterial3D
var _rock_mat: StandardMaterial3D


func _ready() -> void:
	# Run _process AFTER AnimationTree so look-at bone writes aren't overwritten
	process_priority = 100

	_create_environment()
	_create_ground_strip()
	_create_look_target()
	_create_hand_target()
	_create_ui()

	# Generate initial bumps along the walkway
	_generate_bumps_to(BUMP_ZONE_AHEAD)

	# Wait for autoloads
	await get_tree().process_frame
	await get_tree().process_frame

	# Load data
	await _ensure_data_loaded()

	# Preload character assets
	_log("Preloading character assets...")
	var t := Time.get_ticks_msec()
	CharacterFactoryV2Script.preload_character_assets()
	_log("Preloaded in %d ms" % (Time.get_ticks_msec() - t))

	# Load Mixamo Walking animation only
	_log("Loading Mixamo Walking animation...")
	_mixamo_library = AnimationLoaderScript.load_from_fbx("res://assets/animations/mixamo/Walking.fbx")
	if _mixamo_library:
		# Ensure loop + strip head/neck tracks so look-at IK can override them
		# (AnimationTree processes in _process AFTER IK runs in _physics_process,
		#  so walk's head track would overwrite look-at every frame)
		for anim_name in _mixamo_library.get_animation_list():
			var anim: Animation = _mixamo_library.get_animation(anim_name)
			anim.loop_mode = Animation.LOOP_LINEAR
			_strip_bone_tracks(anim, ["Head", "Neck"])
			_log("  %s: %.2fs, %d tracks (looped, head/neck stripped)" % [anim_name, anim.length, anim.get_track_count()])
		_log("[color=green]Mixamo: %d animations[/color]" % _mixamo_library.get_animation_list().size())
	else:
		_log("[color=yellow]No Walking animation found[/color]")

	# Create factory
	_factory = CharacterFactoryV2Script.new()
	_factory.debug_characters = true
	_factory.debug_animations = true
	_factory.enable_ik = true
	_factory.enable_wander = false

	# Spawn first NPC with Mixamo animations
	_spawn_npc()
	_switch_to_mixamo()

	_update_camera()


# =============================================================================
# DATA LOADING
# =============================================================================

func _ensure_data_loaded() -> void:
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
	if data_path.is_empty():
		_log("[color=red]No Morrowind data path![/color]")
		return

	if not BSAManager.has_file("meshes\\xbase_anim.nif"):
		_log("Loading BSA archives...")
		var count := BSAManager.load_archives_from_directory(data_path)
		_log("Loaded %d BSA archives" % count)
		await get_tree().process_frame
	else:
		_log("BSA already loaded")

	if ESMManager.cells.is_empty():
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		_log("Loading ESM: %s" % esm_file)
		var error := ESMManager.load_file(esm_path)
		if error != OK:
			_log("[color=red]Failed to load ESM![/color]")
			return
		_log("ESM loaded: %d cells" % ESMManager.cells.size())
		await get_tree().process_frame
	else:
		_log("ESM already loaded")


# =============================================================================
# NPC SPAWNING
# =============================================================================

func _spawn_npc() -> void:
	if _npc_node:
		_npc_node.queue_free()
		_npc_node = null
		await get_tree().process_frame

	_log_lines.clear()
	_look_initialized = false
	var npc_id: String = TEST_NPCS[_current_npc_index]
	_log("[b]Spawning: %s[/b]" % npc_id)

	var esm_mgr = get_node_or_null("/root/ESMManager")
	if not esm_mgr:
		_log("[color=red]ESMManager not available![/color]")
		return

	var npc_record = esm_mgr.get_npc(npc_id) if esm_mgr.has_method("get_npc") else null
	if not npc_record:
		_log("[color=red]NPC '%s' not found![/color]" % npc_id)
		return

	_log("Race: %s, Female: %s" % [
		npc_record.race_id if "race_id" in npc_record else "?",
		str(npc_record.is_female()) if npc_record.has_method("is_female") else "?"
	])

	_factory.enable_ik = true
	_factory.enable_wander = false
	var start := Time.get_ticks_msec()
	var character = _factory.create_npc(npc_record, 0)
	_log("[color=green]Created in %d ms[/color]" % (Time.get_ticks_msec() - start))

	if not character:
		_log("[color=red]create_npc returned null![/color]")
		return

	_npc_node = character
	add_child(character)
	character.global_position = Vector3(0, 0.1, 0)

	# Reset walk target and start walking straight ahead
	_walk_target_z = WALK_TARGET_AHEAD
	if _walk_enabled:
		_npc_node.move_to(Vector3(0, 0, _walk_target_z))

	_run_diagnostics()
	# Wire up IK targets to the new NPC
	_apply_ik_state()
	_update_live_info()


func _switch_to_mixamo() -> void:
	if not _mixamo_library or not _npc_node:
		return

	var anim_player: AnimationPlayer = _find_node_of_type(_npc_node, "AnimationPlayer")
	if not anim_player:
		return

	# Swap: current default -> "morrowind", mixamo -> default ""
	var old_lib: AnimationLibrary = null
	if anim_player.has_animation_library(""):
		old_lib = anim_player.get_animation_library("")
		anim_player.remove_animation_library("")
	anim_player.add_animation_library("", _mixamo_library)
	if old_lib:
		anim_player.add_animation_library("morrowind", old_lib)

	_using_mixamo = true
	_rebuild_animation_tree()
	_log("[color=green]Switched to Mixamo[/color]")


func _switch_to_morrowind() -> void:
	if not _npc_node:
		return

	var anim_player: AnimationPlayer = _find_node_of_type(_npc_node, "AnimationPlayer")
	if not anim_player:
		return

	if anim_player.has_animation_library("morrowind"):
		var mw_lib := anim_player.get_animation_library("morrowind")
		anim_player.remove_animation_library("morrowind")
		if anim_player.has_animation_library(""):
			anim_player.remove_animation_library("")
		anim_player.add_animation_library("", mw_lib)
	if anim_player.has_animation_library("mixamo"):
		anim_player.remove_animation_library("mixamo")

	_using_mixamo = false
	_rebuild_animation_tree()
	_log("[color=green]Switched to Morrowind[/color]")


func _rebuild_animation_tree() -> void:
	if not _npc_node:
		return
	var anim_system = _npc_node.get_meta("animation_system", null)
	if anim_system and anim_system.has_method("reset"):
		var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D")
		anim_system.reset()
		if skeleton:
			anim_system.enable_ik = true
			anim_system.setup(skeleton, _npc_node as CharacterBody3D)
			# Re-apply IK state
			_apply_ik_state()


# =============================================================================
# ENVIRONMENT & TERRAIN
# =============================================================================

func _create_environment() -> void:
	# Camera
	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)

	# Key light
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 30, 0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)

	# Fill light
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-30, -120, 0)
	fill.light_energy = 0.3
	fill.light_color = Color(0.8, 0.85, 1.0)
	add_child(fill)

	# Environment
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.14, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.5)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _create_ground_strip() -> void:
	# Materials for bumps (create early so _generate_bumps_to can use them)
	_bump_mat = StandardMaterial3D.new()
	_bump_mat.albedo_color = Color(0.28, 0.30, 0.22)
	_rock_mat = StandardMaterial3D.new()
	_rock_mat.albedo_color = Color(0.35, 0.32, 0.25)

	# Long ground strip along +Z axis
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.22, 0.26, 0.18)
	_add_box(Vector3(0, -0.25, GROUND_LENGTH * 0.5), Vector3(GROUND_WIDTH, 0.5, GROUND_LENGTH), ground_mat)

	# Side rails (visual guides)
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.18, 0.20, 0.15)
	var rail_width := 0.15
	var rail_x := GROUND_WIDTH * 0.5 + rail_width * 0.5
	_add_box(Vector3(-rail_x, 0.01, GROUND_LENGTH * 0.5), Vector3(rail_width, 0.02, GROUND_LENGTH), rail_mat)
	_add_box(Vector3(rail_x, 0.01, GROUND_LENGTH * 0.5), Vector3(rail_width, 0.02, GROUND_LENGTH), rail_mat)


func _add_box(pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var sb := StaticBody3D.new()
	sb.position = pos
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	sb.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sb.add_child(cs)
	add_child(sb)


# =============================================================================
# PROCEDURAL OBSTACLES (terrain bumps for foot IK)
# =============================================================================

func _generate_bumps_to(target_z: float) -> void:
	while _furthest_bump_z < target_z:
		_furthest_bump_z += BUMP_SPACING
		# 1-3 random bumps per row
		var count := randi_range(1, 3)
		for i in count:
			var x := randf_range(-GROUND_WIDTH * 0.4, GROUND_WIDTH * 0.4)
			var height := randf_range(0.03, 0.14)
			var width := randf_range(0.5, 1.5)
			var depth := randf_range(0.3, 1.0)
			var mat := _bump_mat if height < 0.08 else _rock_mat
			var bump := _add_bump(Vector3(x, height * 0.5, _furthest_bump_z), Vector3(width, height, depth), mat)
			_bumps.append(bump)


func _add_bump(pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.position = pos
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	sb.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sb.add_child(cs)
	add_child(sb)
	return sb


func _cleanup_bumps_behind(npc_z: float) -> void:
	var cutoff := npc_z - BUMP_ZONE_BEHIND
	var i := 0
	while i < _bumps.size():
		if _bumps[i].position.z < cutoff:
			_bumps[i].queue_free()
			_bumps.remove_at(i)
		else:
			i += 1


func _update_obstacles() -> void:
	if not _npc_node or not _npc_node is Node3D:
		return
	var npc_z: float = _npc_node.global_position.z
	_generate_bumps_to(npc_z + BUMP_ZONE_AHEAD)
	_cleanup_bumps_behind(npc_z)


# =============================================================================
# IK TARGETS
# =============================================================================

func _create_look_target() -> void:
	_look_orb = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.16
	_look_orb.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0.6, 0.1)
	mat.emission_energy_multiplier = 2.0
	_look_orb.material_override = mat
	add_child(_look_orb)


func _create_hand_target() -> void:
	_hand_cube = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.1, 0.1, 0.1)
	_hand_cube.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.9, 0.5)
	mat.emission_enabled = true
	mat.emission = Color(0.1, 0.4, 0.2)
	mat.emission_energy_multiplier = 1.5
	_hand_cube.material_override = mat
	add_child(_hand_cube)


# =============================================================================
# IK DRIVING
# =============================================================================

func _apply_ik_state() -> void:
	if not _npc_node:
		return
	var anim_system = _npc_node.get_meta("animation_system", null)
	if not anim_system:
		return

	# Foot IK
	if anim_system.has_method("set_foot_ik_enabled"):
		anim_system.set_foot_ik_enabled(_foot_ik_enabled)

	# Look-at IK
	if _look_ik_enabled:
		if anim_system.has_method("set_look_position"):
			anim_system.set_look_position(_look_orb.global_position)
	else:
		if anim_system.has_method("clear_look_target"):
			anim_system.clear_look_target()

	# Hand IK
	if _hand_ik_enabled:
		if anim_system.has_method("set_hand_target"):
			anim_system.set_hand_target(&"right", _hand_cube, 1.0)
	else:
		if anim_system.has_method("clear_hand_target"):
			anim_system.clear_hand_target(&"right")


func _update_ik_targets(delta: float) -> void:
	if not _npc_node:
		return

	_time += delta

	# Get head position for look-at orbit
	var head_pos := _get_head_position()

	# Update look orb position (orbits around the HEAD)
	if _look_auto and not _is_dragging(_look_orb):
		var radius := 1.5
		_look_orb.global_position = Vector3(
			head_pos.x + sin(_time * 0.5) * radius,
			head_pos.y + sin(_time * 0.7) * 0.3,
			head_pos.z + cos(_time * 0.5) * radius
		)

	# Update hand cube position (follows the character, floats near the right hand)
	if _hand_auto and not _is_dragging(_hand_cube):
		var npc_pos := Vector3.ZERO
		var npc_basis := Basis.IDENTITY
		if _npc_node is Node3D:
			var n3d: Node3D = _npc_node as Node3D
			npc_pos = n3d.global_position
			npc_basis = n3d.global_transform.basis
		# Offset relative to character facing direction
		var right: Vector3 = npc_basis.x * 0.5
		var forward: Vector3 = -npc_basis.z * 0.2
		var base: Vector3 = npc_pos + right + forward + Vector3.UP * 1.3
		_hand_cube.global_position = Vector3(
			base.x + sin(_time * 0.8) * 0.1,
			base.y + sin(_time * 1.2) * 0.1,
			base.z + cos(_time * 0.6) * 0.1
		)

	# Drive look-at position each frame (hand IK auto-tracks via IKController)
	var anim_system = _npc_node.get_meta("animation_system", null)
	if not anim_system:
		return

	if _look_ik_enabled and anim_system.has_method("set_look_position"):
		anim_system.set_look_position(_look_orb.global_position)


func _get_head_position() -> Vector3:
	if not _npc_node or not _npc_node is Node3D:
		return Vector3(0, 1.6, 0)
	var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D")
	if not skeleton:
		return _npc_node.global_position + Vector3(0, 1.6, 0)
	var head_idx := skeleton.find_bone("Head")
	if head_idx < 0:
		return _npc_node.global_position + Vector3(0, 1.6, 0)
	return skeleton.global_transform * skeleton.get_bone_global_pose(head_idx).origin


func _is_dragging(target: MeshInstance3D) -> bool:
	return _dragging and _dragged_target == target


## Apply head look-at directly in _process (after AnimationTree has run).
## The IK controller's look-at runs in _physics_process which gets overwritten
## by AnimationTree in _process. This bypasses that by running late in _process.
func _apply_direct_look_at(delta: float) -> void:
	if not _look_orb:
		return
	var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D")
	if not skeleton:
		return
	var head_idx := skeleton.find_bone("Head")
	if head_idx < 0:
		return

	# Head position in world space
	var head_global_xf := skeleton.global_transform * skeleton.get_bone_global_pose(head_idx)
	var head_pos := head_global_xf.origin

	# Direction to look target
	var to_target := _look_orb.global_position - head_pos
	if to_target.length_squared() < 0.001:
		return
	to_target = to_target.normalized()

	# Angle check vs character forward
	var char_forward := -skeleton.global_transform.basis.z.normalized()
	var angle := rad_to_deg(char_forward.angle_to(to_target))
	if angle > 90.0:
		# Outside cone — smoothly return to rest
		_look_initialized = false
		return

	# Desired global rotation (look at target)
	var target_q := Transform3D.IDENTITY.looking_at(to_target, Vector3.UP).basis.get_rotation_quaternion()

	# Track smoothed rotation ourselves (NOT reading bone pose which returns rest)
	if not _look_initialized:
		_look_smooth_quat = target_q
		_look_initialized = true
	_look_smooth_quat = _look_smooth_quat.slerp(target_q, clampf(5.0 * delta, 0.0, 1.0))

	# Parent global rotation for local conversion
	var parent_idx := skeleton.get_bone_parent(head_idx)
	var parent_global_q := Quaternion.IDENTITY
	if parent_idx >= 0:
		parent_global_q = (skeleton.global_transform * skeleton.get_bone_global_pose(parent_idx)).basis.orthonormalized().get_rotation_quaternion()
	var rest_q := skeleton.get_bone_rest(head_idx).basis.get_rotation_quaternion()
	var rest_global_q := parent_global_q * rest_q

	# Blend rest → look direction with angle-based weight
	var weight := smoothstep(0.0, 1.0, 1.0 - angle / 90.0) * 0.7
	var final_global_q := rest_global_q.slerp(_look_smooth_quat, weight)

	# Convert to local bone space: pose = rest^-1 * parent_global^-1 * final_global
	var local_q := rest_q.inverse() * parent_global_q.inverse() * final_global_q
	skeleton.set_bone_pose_rotation(head_idx, local_q)


# =============================================================================
# STRAIGHT-LINE WALKING
# =============================================================================

func _update_walking() -> void:
	if not _npc_node:
		return

	var npc_pos: Vector3 = _npc_node.global_position

	# Z/W = forward, S = backward (overrides auto-walk)
	var user_forward := Input.is_key_pressed(KEY_Z) or Input.is_key_pressed(KEY_W)
	var user_backward := Input.is_key_pressed(KEY_S)

	if user_forward or user_backward:
		var dir := 1.0 if user_forward else -1.0
		_walk_target_z = npc_pos.z + dir * WALK_TARGET_AHEAD
		_npc_node.move_to(Vector3(0, 0, _walk_target_z))
	elif _walk_enabled:
		# Auto-walk: always keep target far ahead so NPC never stops
		if npc_pos.z > _walk_target_z - 10.0 or not _npc_node.has_movement_target:
			_walk_target_z = npc_pos.z + WALK_TARGET_AHEAD
			_npc_node.move_to(Vector3(0, 0, _walk_target_z))
	elif not _walk_enabled and _npc_node.has_movement_target:
		_npc_node.stop_movement()


# =============================================================================
# MAIN LOOP
# =============================================================================

func _physics_process(delta: float) -> void:
	_update_walking()
	_update_ik_targets(delta)
	_update_obstacles()

	# Drag update
	if _dragging and _dragged_target:
		_update_drag()


func _process(delta: float) -> void:
	_update_camera()
	_update_live_info()
	# Apply look-at AFTER AnimationTree (process_priority=100 ensures this)
	if _look_ik_enabled and _npc_node:
		_apply_direct_look_at(delta)


# =============================================================================
# CAMERA
# =============================================================================

func _update_camera() -> void:
	var target_center := Vector3(0, 1.0, 0)
	if _npc_node and _npc_node is Node3D:
		target_center = _npc_node.global_position + Vector3(0, 1.0, 0)

	var ry := deg_to_rad(_yaw)
	var rp := deg_to_rad(_pitch)
	var offset := Vector3(
		_distance * cos(rp) * sin(ry),
		_distance * sin(rp),
		_distance * cos(rp) * cos(ry)
	)
	_camera.global_position = target_center + offset
	_camera.look_at(target_center)


# =============================================================================
# MOUSE DRAG
# =============================================================================

func _try_pick_target(screen_pos: Vector2) -> void:
	if not _camera:
		return

	var orb_screen := _camera.unproject_position(_look_orb.global_position)
	var cube_screen := _camera.unproject_position(_hand_cube.global_position)

	var orb_dist := orb_screen.distance_to(screen_pos)
	var cube_dist := cube_screen.distance_to(screen_pos)
	var threshold := 80.0

	if orb_dist < threshold and orb_dist < cube_dist:
		_dragged_target = _look_orb
		_drag_plane_y = _look_orb.global_position.y
		_dragging = true
		_look_auto = false
	elif cube_dist < threshold:
		_dragged_target = _hand_cube
		_drag_plane_y = _hand_cube.global_position.y
		_dragging = true
		_hand_auto = false


func _update_drag() -> void:
	if not _camera or not _dragged_target:
		return

	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := _camera.project_ray_origin(mouse_pos)
	var ray_dir := _camera.project_ray_normal(mouse_pos)

	if absf(ray_dir.y) < 0.001:
		return

	var t := (_drag_plane_y - ray_origin.y) / ray_dir.y
	if t < 0:
		return

	_dragged_target.global_position = ray_origin + ray_dir * t


func _stop_drag() -> void:
	_dragging = false
	_dragged_target = null


# =============================================================================
# INPUT
# =============================================================================

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_foot_ik_enabled = not _foot_ik_enabled
				_apply_ik_state()
				_log("Foot IK: %s" % ("ON" if _foot_ik_enabled else "OFF"))
			KEY_2:
				_look_ik_enabled = not _look_ik_enabled
				_look_initialized = false
				_apply_ik_state()
				_log("Look-at IK: %s" % ("ON" if _look_ik_enabled else "OFF"))
			KEY_3:
				_hand_ik_enabled = not _hand_ik_enabled
				_apply_ik_state()
				_log("Hand IK: %s" % ("ON" if _hand_ik_enabled else "OFF"))
			KEY_4:
				_walk_enabled = not _walk_enabled
				if not _walk_enabled and _npc_node:
					_npc_node.stop_movement()
				elif _walk_enabled and _npc_node:
					_walk_target_z = _npc_node.global_position.z + WALK_TARGET_AHEAD
					_npc_node.move_to(Vector3(0, 0, _walk_target_z))
				_log("Auto-walk: %s (Z/S still works)" % ("ON" if _walk_enabled else "OFF"))
			KEY_M:
				if _using_mixamo:
					_switch_to_morrowind()
				else:
					_switch_to_mixamo()
			KEY_N:
				_current_npc_index = (_current_npc_index + 1) % TEST_NPCS.size()
				_spawn_npc()
				if _using_mixamo:
					_switch_to_mixamo()
			KEY_D:
				_dump_debug()
			KEY_SPACE:
				_look_auto = true
				_hand_auto = true

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_try_pick_target(event.position)
			else:
				_stop_drag()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_distance = maxf(2.0, _distance - 0.5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_distance = minf(15.0, _distance + 0.5)
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * 0.3
		_pitch = clampf(_pitch - event.relative.y * 0.3, -80.0, 80.0)


# =============================================================================
# UI
# =============================================================================

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 10
	panel.offset_top = 10
	panel.offset_right = 420
	panel.offset_bottom = 500

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.content_margin_left = 10
	style.content_margin_top = 10
	style.content_margin_right = 10
	style.content_margin_bottom = 10
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)

	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.fit_content = true
	_info_label.custom_minimum_size = Vector2(400, 480)
	_info_label.scroll_active = true

	panel.add_child(_info_label)
	canvas.add_child(panel)


func _update_live_info() -> void:
	if not _info_label:
		return

	var lines := PackedStringArray()
	lines.append("[b]IK + Animation Showcase[/b]")
	lines.append("===========================")

	# NPC info
	lines.append("NPC: [color=cyan]%s[/color]" % TEST_NPCS[_current_npc_index])
	lines.append("Animations: [color=cyan]%s[/color]" % ("Mixamo" if _using_mixamo else "Morrowind"))

	# IK toggles
	lines.append("")
	lines.append("[1] Foot IK:    %s" % _ik_status(_foot_ik_enabled))
	lines.append("[2] Look-at IK: %s" % _ik_status(_look_ik_enabled))
	lines.append("[3] Hand IK:    %s" % _ik_status(_hand_ik_enabled))
	lines.append("[4] Walking:    %s" % _ik_status(_walk_enabled))

	# NPC position & state
	if _npc_node and _npc_node is Node3D:
		var pos: Vector3 = _npc_node.global_position
		lines.append("")
		lines.append("Position: %.2f, %.2f, %.2f" % [pos.x, pos.y, pos.z])
		if "velocity" in _npc_node:
			var vel: Vector3 = _npc_node.velocity
			lines.append("Speed: %.2f m/s" % vel.length())
		lines.append("Walk target Z: %.1f" % _walk_target_z)

	# Animation state
	if _npc_node:
		var anim_system = _npc_node.get_meta("animation_system", null)
		if anim_system and anim_system.has_method("get_state"):
			lines.append("Anim state: [color=cyan]%s[/color]" % anim_system.get_state())

	# Look-at info
	if _look_orb:
		lines.append("")
		lines.append("Look target: %.1f, %.1f, %.1f %s" % [
			_look_orb.global_position.x, _look_orb.global_position.y, _look_orb.global_position.z,
			"[color=gray](auto)[/color]" if _look_auto else "[color=yellow](manual)[/color]"])

	# Drag state
	if _dragging and _dragged_target:
		var tname := "Look Orb" if _dragged_target == _look_orb else "Hand Cube"
		lines.append("[color=yellow]DRAGGING: %s[/color]" % tname)

	# Bump count
	lines.append("")
	lines.append("Active bumps: %d" % _bumps.size())

	# User input state
	var user_fwd := Input.is_key_pressed(KEY_Z) or Input.is_key_pressed(KEY_W)
	var user_bwd := Input.is_key_pressed(KEY_S)
	if user_fwd:
		lines.append("Input: [color=green]FORWARD (Z/W)[/color]")
	elif user_bwd:
		lines.append("Input: [color=green]BACKWARD (S)[/color]")
	else:
		lines.append("Input: [color=gray]auto-walk[/color]")

	lines.append("")
	lines.append("[color=gray][Z/W] Forward  [S] Backward  (auto if none)[/color]")
	lines.append("[color=gray][M] Anims  [N] NPC  [D] Debug  [Space] Auto[/color]")
	lines.append("[color=gray][RMB] Orbit  [Scroll] Zoom  [LMB] Drag[/color]")

	# Append log lines at bottom
	if _log_lines.size() > 0:
		lines.append("")
		lines.append("-------------------------------")
		var start_idx := maxi(0, _log_lines.size() - 8)
		for i in range(start_idx, _log_lines.size()):
			lines.append(_log_lines[i])

	_info_label.text = "\n".join(lines)


func _ik_status(enabled: bool) -> String:
	return "[color=green]ON[/color]" if enabled else "[color=red]OFF[/color]"


# =============================================================================
# DIAGNOSTICS
# =============================================================================

func _run_diagnostics() -> void:
	if not _npc_node:
		return

	var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D")
	if skeleton:
		_log("Skeleton: %d bones" % skeleton.get_bone_count())
		var profile_found := 0
		for bone_name in ["Hips", "Head", "LeftHand", "RightFoot", "LeftUpperLeg"]:
			if skeleton.find_bone(bone_name) >= 0:
				profile_found += 1
		_log("Profile bones: %d/5 %s" % [profile_found,
			"[color=green]OK[/color]" if profile_found >= 4 else "[color=red]MISSING[/color]"])

	var anim_player: AnimationPlayer = _find_node_of_type(_npc_node, "AnimationPlayer")
	if anim_player:
		_log("Animations: %d" % anim_player.get_animation_list().size())

	var anim_tree: AnimationTree = _find_node_of_type(_npc_node, "AnimationTree")
	if anim_tree:
		_log("AnimationTree: active=%s" % str(anim_tree.active))

	var anim_system = _npc_node.get_meta("animation_system", null)
	if anim_system:
		_log("AnimSystem: [color=green]wired[/color]")
		if anim_system.get("ik_controller"):
			_log("IK Controller: [color=green]present[/color]")
		else:
			_log("IK Controller: [color=red]missing[/color]")


func _dump_debug() -> void:
	if not _npc_node:
		return

	Log.info("animation", "=== IK SHOWCASE DEBUG ===")

	var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D")
	if skeleton:
		Log.info("animation", "Skeleton: %d bones" % skeleton.get_bone_count())
		for i in skeleton.get_bone_count():
			Log.info("animation", "  [%d] %s" % [i, skeleton.get_bone_name(i)])

	var anim_system = _npc_node.get_meta("animation_system", null)
	if anim_system:
		Log.info("animation", "AnimSystem: ik_enabled=%s" % str(anim_system.enable_ik))
		var ik = anim_system.get("ik_controller")
		if ik:
			Log.info("animation", "IK Controller: foot=%s look=%s hand=%s" % [
				str(ik.enable_foot_ik), str(ik.enable_look_at), str(ik.enable_hand_ik)])

	Log.info("animation", "=== END DEBUG ===")


# =============================================================================
# UTILITIES
# =============================================================================

func _log(text: String) -> void:
	_log_lines.append(text)
	var stripped := text
	for tag in ["[color=green]", "[color=red]", "[color=yellow]", "[color=cyan]", "[color=gray]", "[/color]", "[b]", "[/b]"]:
		stripped = stripped.replace(tag, "")
	print("[IKShowcase] %s" % stripped)


func _strip_bone_tracks(anim: Animation, bone_names: Array) -> void:
	var to_remove := []
	for i in anim.get_track_count():
		var path := anim.track_get_path(i)
		if path.get_subname_count() > 0:
			var bone_name := String(path.get_subname(0))
			if bone_name in bone_names:
				to_remove.append(i)
	to_remove.reverse()
	for idx in to_remove:
		anim.remove_track(idx)


func _find_node_of_type(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for child in node.get_children():
		var result := _find_node_of_type(child, type_name)
		if result:
			return result
	return null
