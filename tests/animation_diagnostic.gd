## Animation Diagnostic Tool — Structured data dump for debugging animation pipeline
##
## Produces text output that Claude can analyze to identify animation issues
## without visual confirmation. Tests at multiple levels:
## - Raw data (skeleton rest vs KF keyframes)
## - Conversion correctness (rest^-1 * kf → identity for idle)
## - Bone name mapping (Bip01 → profile completeness)
## - Full pipeline (CharacterFactoryV2 scene tree verification)
## - Manual pose injection (bypass AnimationPlayer/Tree, test data directly)
## - AnimationPlayer direct playback (bypass AnimationTree)
## - Full AnimationTree pipeline
## - A/B comparison (converted vs raw animations)
##
## Run: Open tests/animation_diagnostic.tscn in editor and press F5
## Output: Console (print) + on-screen RichTextLabel
@tool
extends Node3D

@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast", "inferred_declaration")

const CharacterFactoryV2Script := preload("res://src/core/animation/character_factory_v2.gd")
const MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
const NIFKFLoaderScript := preload("res://src/core/nif/nif_kf_loader.gd")
const RetargetSetupScript := preload("res://src/core/animation/skeleton_utils.gd")
const TestNPCLoaderScript := preload("res://tests/test_npc_loader.gd")

# Results tracking
var _results: Array[Dictionary] = []  # { section, key, value, status }
var _section_pass: Dictionary = {}  # section_name -> [pass_count, fail_count]
var _label: RichTextLabel = null
var _ran: bool = false

# Test NPCs
var _npc_a: Node = null  # Full pipeline (with conversion)
var _npc_b: Node = null  # Raw pipeline (without conversion)

# Fast-path mode
var _using_prebaked: bool = false
var _auto_quit_timer: float = -1.0  # -1 = disabled
var _output_file_path: String = "res://tests/diagnostic_output.log"


func _ready() -> void:
	_parse_command_args()
	_setup_ui()
	_setup_scene()

	# Wait for autoloads
	await get_tree().process_frame
	await get_tree().process_frame

	# Check for prebaked NPC (fast path)
	_using_prebaked = TestNPCLoaderScript.has_prebaked("fargoth")

	if _using_prebaked:
		_log("[color=green]FAST PATH: Using prebaked NPC[/color]")
		_log("Skipping S1-S3 (require raw BSA data)")
		_log("")
	else:
		await _ensure_data_loaded()
		# Clear animation caches to ensure fresh (unconverted) libraries
		CharacterFactoryV2Script.clear_all_caches()

	_print_header("ANIMATION DIAGNOSTIC TOOL")
	_log("Starting diagnostic sections...")
	_log("")

	# S1-S3: Raw data validation (requires BSA — skipped in prebaked mode)
	if _using_prebaked:
		_result("S1", "status", "SKIPPED (prebaked mode)", "INFO")
		_result("S2", "status", "SKIPPED (prebaked mode)", "INFO")
		_result("S3", "status", "SKIPPED (prebaked mode)", "INFO")
	else:
		await _section_1_raw_data()
		await _section_2_conversion()
		await _section_3_bone_mapping()

	# S4-S10: Pipeline tests (work with prebaked or full pipeline)
	await _section_4_pipeline()
	await _section_5_manual_pose()
	await _section_6_player_direct()
	await _section_7_animation_tree()
	await _section_8_ab_comparison()
	await _section_9_walk_test()
	_section_10_verdict()

	_log("")
	_print_header("DIAGNOSTIC COMPLETE")
	_save_results_to_file()

	if _auto_quit_timer > 0:
		_log("Auto-quit in %.0f seconds..." % _auto_quit_timer)
	else:
		_log("Press D to dump full report again, R to re-run")
	_ran = true


func _parse_command_args() -> void:
	# Godot puts args after "--" in get_cmdline_user_args()
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for arg in args:
		if arg == "--auto-quit":
			_auto_quit_timer = 2.0
		elif arg.begins_with("--output="):
			_output_file_path = arg.substr("--output=".length())


func _process(delta: float) -> void:
	if _auto_quit_timer > 0 and _ran:
		_auto_quit_timer -= delta
		if _auto_quit_timer <= 0:
			get_tree().quit()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_D:
				_dump_full_report()
			KEY_R:
				if _ran:
					_cleanup_npcs()
					_results.clear()
					_section_pass.clear()
					_ran = false
					_ready()
			KEY_ESCAPE:
				get_tree().quit()


# =============================================================================
# SECTION 1: RAW DATA VERIFICATION
# =============================================================================

func _section_1_raw_data() -> void:
	_print_header("SECTION 1: RAW DATA VERIFICATION")

	# Load skeleton from NIF (same as CharacterFactoryV2 does)
	var skel_key := "humanoid"
	if skel_key not in MorrowindNPCAssembler._skeleton_cache:
		MorrowindNPCAssembler.preload_skeleton(false, false)
	var cached_skel: Skeleton3D = MorrowindNPCAssembler._skeleton_cache.get(skel_key)
	if not cached_skel:
		_result("S1", "skeleton_loaded", "MISSING", "FAIL")
		return

	_result("S1", "skeleton_bones", str(cached_skel.get_bone_count()), "INFO")

	# Load raw KF animations (no conversion, no remap)
	var kf_data := BSAManager.extract_file("meshes\\xbase_anim.kf")
	if kf_data.is_empty():
		_result("S1", "kf_loaded", "MISSING from BSA", "FAIL")
		return

	var loader := NIFKFLoaderScript.new()
	var animations: Dictionary = loader.load_kf_buffer(kf_data, null)
	_result("S1", "animations_loaded", str(animations.size()), "INFO")

	# Find idle animation
	var idle_anim: Animation = _find_idle_anim(animations)
	if not idle_anim:
		_result("S1", "idle_found", "NOT FOUND", "FAIL")
		return
	_result("S1", "idle_found", "%.2fs, %d tracks" % [idle_anim.length, idle_anim.get_track_count()], "PASS")

	# Compare rest vs KF frame 0 for each bone
	var bone_tracks := _map_bone_tracks(idle_anim)
	var absolute_count := 0
	var total_checked := 0

	for i in cached_skel.get_bone_count():
		var bone_name := cached_skel.get_bone_name(i)
		var rest := cached_skel.get_bone_rest(i)
		var rest_q := rest.basis.get_rotation_quaternion()
		var track_key := bone_name.to_lower()

		if track_key not in bone_tracks:
			continue

		var info: Dictionary = bone_tracks[track_key]
		if not info.has("rot_idx"):
			continue

		var rot_idx: int = info["rot_idx"]
		if idle_anim.track_get_key_count(rot_idx) == 0:
			continue

		var kf_rot: Quaternion = idle_anim.rotation_track_interpolate(rot_idx, 0.0)
		var angle := _quat_angle_deg(rest_q, kf_rot)
		total_checked += 1
		if angle < 1.0:
			absolute_count += 1

	var pct := (float(absolute_count) / maxf(1.0, float(total_checked))) * 100.0
	var status := "PASS" if pct > 95.0 else "FAIL"
	_result("S1", "kf_is_absolute", "%d/%d bones match rest (%.0f%%)" % [absolute_count, total_checked, pct], status)
	_log("")


# =============================================================================
# SECTION 2: CONVERSION CORRECTNESS
# =============================================================================

func _section_2_conversion() -> void:
	_print_header("SECTION 2: CONVERSION CORRECTNESS (SKIPPED — rest-relative conversion removed from pipeline)")
	_result("S2", "status", "rest-relative conversion removed — raw KF absolute values used directly", "INFO")
	_log("")


# =============================================================================
# SECTION 3: BONE NAME MAPPING
# =============================================================================

func _section_3_bone_mapping() -> void:
	_print_header("SECTION 3: BONE NAME MAPPING")

	var remap: Dictionary = CharacterFactoryV2Script._humanoid_bone_remap
	if remap.is_empty():
		# Try to build it
		CharacterFactoryV2Script._preload_bone_remaps()
		remap = CharacterFactoryV2Script._humanoid_bone_remap

	_result("S3", "remap_entries", str(remap.size()), "INFO")

	# Load raw KF to check track bone names
	var kf_data := BSAManager.extract_file("meshes\\xbase_anim.kf")
	if kf_data.is_empty():
		_result("S3", "kf_data", "MISSING", "FAIL")
		return

	var loader := NIFKFLoaderScript.new()
	var animations: Dictionary = loader.load_kf_buffer(kf_data, null)
	var idle_anim: Animation = _find_idle_anim(animations)
	if not idle_anim:
		return

	var mapped := 0
	var unmapped := 0
	var unmapped_names: PackedStringArray = []

	for t in idle_anim.get_track_count():
		var path := idle_anim.track_get_path(t)
		if path.get_subname_count() == 0:
			continue
		var bone_name := String(path.get_subname(0))
		if bone_name in remap:
			mapped += 1
		else:
			unmapped += 1
			if bone_name not in unmapped_names:
				unmapped_names.append(bone_name)

	_result("S3", "tracks_mapped", "%d mapped, %d unmapped" % [mapped, unmapped], "PASS" if unmapped <= 3 else "WARN")
	if unmapped_names.size() > 0:
		_result("S3", "unmapped_bones", ", ".join(unmapped_names), "INFO")
	_log("")


# =============================================================================
# SECTION 4: FULL PIPELINE NPC CREATION
# =============================================================================

func _section_4_pipeline() -> void:
	_print_header("SECTION 4: NPC CREATION")

	var start_ms := Time.get_ticks_msec()

	if _using_prebaked:
		# Fast path: load prebaked NPC
		var character = TestNPCLoaderScript.load_test_npc("fargoth")
		if not character:
			_result("S4", "prebaked_load", "FAILED — falling back to full pipeline", "FAIL")
			_using_prebaked = false
			await _ensure_data_loaded()
			CharacterFactoryV2Script.clear_all_caches()
			# Fall through to full pipeline below
		else:
			add_child(character)
			character.global_position = Vector3.ZERO
			_npc_a = character
			var elapsed := Time.get_ticks_msec() - start_ms
			_result("S4", "load_method", "PREBAKED (%d ms)" % elapsed, "PASS")
			await get_tree().process_frame
			_verify_npc_structure(character)
			_log("")
			return

	# Full pipeline path (original behavior)
	CharacterFactoryV2Script.preload_character_assets()

	var factory := CharacterFactoryV2Script.new()
	factory.enable_ik = false
	factory.enable_wander = false
	factory.debug_characters = true

	# Trigger on-demand record creation from C# cache
	var _out_type: Array = [""]
	ESMManager.get_any_record("fargoth", _out_type)
	var npc_record = ESMManager.get_npc("fargoth")
	if not npc_record:
		_result("S4", "npc_record", "fargoth NOT FOUND in ESM", "FAIL")
		return

	_result("S4", "npc_record", "fargoth found", "PASS")

	var character := factory.create_npc(npc_record, 0)
	if not character:
		_result("S4", "create_npc", "RETURNED NULL", "FAIL")
		return

	add_child(character)
	character.global_position = Vector3.ZERO
	_npc_a = character
	var elapsed := Time.get_ticks_msec() - start_ms
	_result("S4", "load_method", "FULL PIPELINE (%d ms)" % elapsed, "INFO")

	# Wait for scene tree
	await get_tree().process_frame

	_verify_npc_structure(character)
	_log("")


# =============================================================================
# SECTION 5: MANUAL POSE INJECTION (THE CRITICAL TEST)
# =============================================================================

func _section_5_manual_pose() -> void:
	_print_header("SECTION 5: MANUAL POSE INJECTION")

	if not _npc_a:
		_result("S5", "prerequisite", "No NPC from Section 4", "FAIL")
		return

	var skeleton := _find_node_of_type(_npc_a, "Skeleton3D") as Skeleton3D
	if not skeleton:
		_result("S5", "skeleton", "NOT FOUND", "FAIL")
		return

	# Disable AnimationTree so we control poses directly
	var anim_tree := _find_node_of_type(_npc_a, "AnimationTree") as AnimationTree
	if anim_tree:
		anim_tree.active = false

	var anim_player := _find_node_of_type(_npc_a, "AnimationPlayer") as AnimationPlayer
	if anim_player:
		anim_player.stop()

	await get_tree().process_frame

	# --- 5.0: REST POSE INVESTIGATION (Hypothesis A vs B) ---
	_log("  5.0: Dumping NPC skeleton rest poses vs cached skeleton...")
	var cached_skel: Skeleton3D = MorrowindNPCAssembler._skeleton_cache.get("humanoid") if not _using_prebaked else null
	var identity_count := 0
	var nif_match_count := 0
	var check_bones := ["Bip01", "Bip01 NonAccum", "Hips", "Spine", "Head", "LeftUpperArm", "LeftFoot"]
	for bone_name in check_bones:
		var idx := skeleton.find_bone(bone_name)
		if idx < 0:
			continue
		var rest := skeleton.get_bone_rest(idx)
		var rest_rot := rest.basis.get_rotation_quaternion()
		var rest_pos := rest.origin
		var is_identity := _quat_angle_deg(Quaternion.IDENTITY, rest_rot) < 0.1 and rest_pos.length() < 0.001
		if is_identity:
			identity_count += 1
		_result("S5", "5.0_rest_%s" % bone_name,
			"rot=(%.3f,%.3f,%.3f,%.3f) pos=(%.4f,%.4f,%.4f) %s" % [
				rest_rot.x, rest_rot.y, rest_rot.z, rest_rot.w,
				rest_pos.x, rest_pos.y, rest_pos.z,
				"IDENTITY" if is_identity else "NIF"],
			"INFO")

		# Compare with cached skeleton (original Bip01 names — need reverse lookup)
		if cached_skel:
			for ci in cached_skel.get_bone_count():
				var cached_rest := cached_skel.get_bone_rest(ci)
				var cached_rot := cached_rest.basis.get_rotation_quaternion()
				if _quat_angle_deg(rest_rot, cached_rot) < 0.5:
					nif_match_count += 1
					break

	var rest_verdict := "IDENTITY" if identity_count == check_bones.size() else "NIF TRANSFORMS" if identity_count == 0 else "MIXED (%d identity)" % identity_count
	_result("S5", "5.0_rest_verdict", rest_verdict, "INFO")
	_result("S5", "5.0_cached_matches", "%d/%d" % [nif_match_count, check_bones.size()], "INFO")

	# --- 5A: Identity pose (baseline = rest positions) ---
	_log("  5A: Setting identity poses...")
	for i in skeleton.get_bone_count():
		skeleton.set_bone_pose_rotation(i, Quaternion.IDENTITY)
		skeleton.set_bone_pose_position(i, Vector3.ZERO)
		skeleton.set_bone_pose_scale(i, Vector3.ONE)

	await get_tree().process_frame
	await get_tree().process_frame

	var anatomy_a := _check_anatomy(skeleton)
	_result("S5", "5A_identity_head", _v3str(anatomy_a.head), "INFO")
	_result("S5", "5A_identity_hips", _v3str(anatomy_a.hips), "INFO")
	_result("S5", "5A_identity_l_foot", _v3str(anatomy_a.l_foot), "INFO")
	_result("S5", "5A_identity_r_foot", _v3str(anatomy_a.r_foot), "INFO")
	_result("S5", "5A_identity_anatomy", _anatomy_summary(anatomy_a), "PASS" if anatomy_a.pass else "FAIL")

	# --- 5B & 5C: Require BSA for raw KF data ---
	if _using_prebaked:
		_result("S5", "5B_converted", "SKIPPED (prebaked mode)", "INFO")
		_result("S5", "5C_raw", "SKIPPED (prebaked mode)", "INFO")
	else:
		# --- 5B: Converted pose (rest^-1 * kf_idle[0]) ---
		_log("  5B: Setting converted (rest^-1 * kf) poses...")
		var converted_idle := _get_converted_idle(skeleton)
		if converted_idle:
			_apply_animation_frame(skeleton, converted_idle, 0.0)
			await get_tree().process_frame
			await get_tree().process_frame

			var anatomy_b := _check_anatomy(skeleton)
			_result("S5", "5B_converted_head", _v3str(anatomy_b.head), "INFO")
			_result("S5", "5B_converted_hips", _v3str(anatomy_b.hips), "INFO")
			_result("S5", "5B_converted_l_foot", _v3str(anatomy_b.l_foot), "INFO")
			_result("S5", "5B_converted_anatomy", _anatomy_summary(anatomy_b), "PASS" if anatomy_b.pass else "FAIL")

			var max_diff := _max_anatomy_diff(anatomy_a, anatomy_b)
			_result("S5", "5B_vs_5A_max_diff", "%.4fm" % max_diff, "PASS" if max_diff < 0.01 else "WARN")
		else:
			_result("S5", "5B_converted", "Could not load converted idle", "FAIL")

		# --- 5C: Raw absolute pose (KF values directly as pose) ---
		_log("  5C: Setting raw absolute poses (KF values as-is)...")
		var raw_idle := _get_raw_idle(skeleton)
		if raw_idle:
			_apply_animation_frame(skeleton, raw_idle, 0.0)
			await get_tree().process_frame
			await get_tree().process_frame

			var anatomy_c := _check_anatomy(skeleton)
			_result("S5", "5C_raw_head", _v3str(anatomy_c.head), "INFO")
			_result("S5", "5C_raw_hips", _v3str(anatomy_c.hips), "INFO")
			_result("S5", "5C_raw_l_foot", _v3str(anatomy_c.l_foot), "INFO")
			_result("S5", "5C_raw_anatomy", _anatomy_summary(anatomy_c), "PASS" if anatomy_c.pass else "FAIL")

			var max_diff_c := _max_anatomy_diff(anatomy_a, anatomy_c)
			_result("S5", "5C_vs_5A_max_diff", "%.4fm" % max_diff_c, "INFO")
		else:
			_result("S5", "5C_raw", "Could not load raw idle", "FAIL")

	# Reset to identity
	for i in skeleton.get_bone_count():
		skeleton.set_bone_pose_rotation(i, Quaternion.IDENTITY)
		skeleton.set_bone_pose_position(i, Vector3.ZERO)
		skeleton.set_bone_pose_scale(i, Vector3.ONE)

	_log("")


# =============================================================================
# SECTION 6: ANIMATIONPLAYER DIRECT PLAYBACK
# =============================================================================

func _section_6_player_direct() -> void:
	_print_header("SECTION 6: ANIMATIONPLAYER DIRECT PLAYBACK")

	if not _npc_a:
		_result("S6", "prerequisite", "No NPC", "FAIL")
		return

	var skeleton := _find_node_of_type(_npc_a, "Skeleton3D") as Skeleton3D
	var anim_player := _find_node_of_type(_npc_a, "AnimationPlayer") as AnimationPlayer
	var anim_tree := _find_node_of_type(_npc_a, "AnimationTree") as AnimationTree

	if not skeleton or not anim_player:
		_result("S6", "prerequisites", "skeleton=%s player=%s" % [skeleton != null, anim_player != null], "FAIL")
		return

	# Ensure AnimationTree is OFF
	if anim_tree:
		anim_tree.active = false
	await get_tree().process_frame

	# Find idle animation name
	var idle_name := ""
	for anim_name in anim_player.get_animation_list():
		if "idle" in String(anim_name).to_lower():
			idle_name = anim_name
			break

	if idle_name.is_empty():
		_result("S6", "idle_found", "NO IDLE IN PLAYER", "FAIL")
		return

	_result("S6", "playing", idle_name, "INFO")

	# Play idle directly
	anim_player.play(idle_name)
	anim_player.seek(0.0, true)

	# Wait for animation to apply
	for i in 5:
		await get_tree().process_frame

	var anatomy := _check_anatomy(skeleton)
	_result("S6", "player_head", _v3str(anatomy.head), "INFO")
	_result("S6", "player_hips", _v3str(anatomy.hips), "INFO")
	_result("S6", "player_l_foot", _v3str(anatomy.l_foot), "INFO")
	_result("S6", "player_anatomy", _anatomy_summary(anatomy), "PASS" if anatomy.pass else "FAIL")

	# Check if poses are non-identity (animation is actually driving bones)
	var non_identity := 0
	for i in skeleton.get_bone_count():
		var pose_rot := skeleton.get_bone_pose_rotation(i)
		if _quat_angle_deg(Quaternion.IDENTITY, pose_rot) > 0.1:
			non_identity += 1

	_result("S6", "non_identity_bones", "%d/%d" % [non_identity, skeleton.get_bone_count()],
		"INFO")

	anim_player.stop()
	_log("")


# =============================================================================
# SECTION 7: FULL ANIMATIONTREE PIPELINE
# =============================================================================

func _section_7_animation_tree() -> void:
	_print_header("SECTION 7: FULL ANIMATIONTREE PIPELINE")

	if not _npc_a:
		_result("S7", "prerequisite", "No NPC", "FAIL")
		return

	var skeleton := _find_node_of_type(_npc_a, "Skeleton3D") as Skeleton3D
	var anim_player := _find_node_of_type(_npc_a, "AnimationPlayer") as AnimationPlayer
	var anim_tree := _find_node_of_type(_npc_a, "AnimationTree") as AnimationTree

	if not skeleton or not anim_tree:
		_result("S7", "prerequisites", "skeleton=%s tree=%s" % [skeleton != null, anim_tree != null], "FAIL")
		return

	# Stop AnimationPlayer direct playback, re-enable tree
	if anim_player:
		anim_player.stop()
	anim_tree.active = true

	# Try to travel to Idle
	var sm = anim_tree.get("parameters/locomotion/playback")
	if sm:
		sm.travel(&"Idle")
		_result("S7", "travel_idle", "OK", "INFO")
	else:
		_result("S7", "state_machine", "PLAYBACK NOT FOUND", "FAIL")

	# Wait for tree to process
	for i in 10:
		await get_tree().process_frame

	var anatomy := _check_anatomy(skeleton)
	_result("S7", "tree_head", _v3str(anatomy.head), "INFO")
	_result("S7", "tree_hips", _v3str(anatomy.hips), "INFO")
	_result("S7", "tree_l_foot", _v3str(anatomy.l_foot), "INFO")
	_result("S7", "tree_anatomy", _anatomy_summary(anatomy), "PASS" if anatomy.pass else "FAIL")

	if sm:
		_result("S7", "current_state", str(sm.get_current_node()), "INFO")

	_log("")


# =============================================================================
# SECTION 8: A/B CONVERSION COMPARISON
# =============================================================================

func _section_8_ab_comparison() -> void:
	_print_header("SECTION 8: A/B PIPELINE vs RAW COMPARISON")

	if _using_prebaked:
		# Can't create NPC B without BSA — just verify NPC A
		if _npc_a:
			var skel_a := _find_node_of_type(_npc_a, "Skeleton3D") as Skeleton3D
			if skel_a:
				var anatomy_a := _check_anatomy(skel_a)
				_result("S8", "A_anatomy", _anatomy_summary(anatomy_a), "PASS" if anatomy_a.pass else "FAIL")
		_result("S8", "npc_b", "SKIPPED (prebaked mode — needs BSA)", "INFO")
		_log("")
		return

	# Full pipeline path
	if not _npc_a:
		_result("S8", "npc_a", "MISSING (Section 4 failed)", "FAIL")
		return

	var skel_a := _find_node_of_type(_npc_a, "Skeleton3D") as Skeleton3D
	if not skel_a:
		_result("S8", "skel_a", "NOT FOUND", "FAIL")
		return

	var anatomy_a := _check_anatomy(skel_a)
	_result("S8", "A_pipeline_head", _v3str(anatomy_a.head), "INFO")
	_result("S8", "A_pipeline_hips", _v3str(anatomy_a.hips), "INFO")
	_result("S8", "A_pipeline_anatomy", _anatomy_summary(anatomy_a), "PASS" if anatomy_a.pass else "FAIL")

	var skel_b := _create_raw_animation_npc()
	if not skel_b:
		_result("S8", "npc_b", "FAILED TO CREATE", "FAIL")
		return

	for i in 10:
		await get_tree().process_frame

	var anatomy_b := _check_anatomy(skel_b)
	_result("S8", "B_raw_head", _v3str(anatomy_b.head), "INFO")
	_result("S8", "B_raw_hips", _v3str(anatomy_b.hips), "INFO")
	_result("S8", "B_raw_anatomy", _anatomy_summary(anatomy_b), "PASS" if anatomy_b.pass else "FAIL")

	if anatomy_a.pass and anatomy_b.pass:
		_result("S8", "verdict", "BOTH PASS — pipeline fix confirmed", "PASS")
	elif anatomy_a.pass and not anatomy_b.pass:
		_result("S8", "verdict", "Pipeline PASS, raw FAIL — unexpected", "WARN")
	elif anatomy_b.pass and not anatomy_a.pass:
		_result("S8", "verdict", "Pipeline FAIL, raw PASS — pipeline still broken", "FAIL")
	else:
		_result("S8", "verdict", "BOTH FAIL — deeper issue", "FAIL")

	_log("")


# =============================================================================
# SECTION 9: WALK ANIMATION TEST
# =============================================================================

func _section_9_walk_test() -> void:
	_print_header("SECTION 9: WALK ANIMATION TEST")

	if not _npc_a:
		_result("S9", "prerequisite", "No NPC", "FAIL")
		return

	var skeleton := _find_node_of_type(_npc_a, "Skeleton3D") as Skeleton3D
	var anim_player := _find_node_of_type(_npc_a, "AnimationPlayer") as AnimationPlayer
	var anim_tree := _find_node_of_type(_npc_a, "AnimationTree") as AnimationTree

	if not skeleton or not anim_player:
		_result("S9", "prerequisites", "MISSING", "FAIL")
		return

	# Disable tree, play walk directly
	if anim_tree:
		anim_tree.active = false
	await get_tree().process_frame

	# Find walk animation
	var walk_name := ""
	for anim_name in anim_player.get_animation_list():
		var lower := String(anim_name).to_lower()
		if "walk" in lower:
			walk_name = anim_name
			break

	if walk_name.is_empty():
		_result("S9", "walk_found", "NO WALK ANIMATION", "FAIL")
		return

	_result("S9", "walk_anim", walk_name, "INFO")

	# Play at mid-point
	var walk_anim: Animation = anim_player.get_animation(walk_name)
	var mid_time := walk_anim.length * 0.5

	anim_player.play(walk_name)
	anim_player.seek(mid_time, true)

	for i in 5:
		await get_tree().process_frame

	var anatomy := _check_anatomy(skeleton)
	_result("S9", "walk_head", _v3str(anatomy.head), "INFO")
	_result("S9", "walk_hips", _v3str(anatomy.hips), "INFO")
	_result("S9", "walk_l_foot", _v3str(anatomy.l_foot), "INFO")
	_result("S9", "walk_r_foot", _v3str(anatomy.r_foot), "INFO")
	_result("S9", "walk_anatomy", _anatomy_summary(anatomy), "PASS" if anatomy.pass else "FAIL")

	# Check feet are at different heights (mid-stride)
	var foot_y_diff := absf(anatomy.l_foot.y - anatomy.r_foot.y)
	_result("S9", "foot_y_difference", "%.4fm" % foot_y_diff, "INFO")

	anim_player.stop()
	if anim_tree:
		anim_tree.active = true
	_log("")


# =============================================================================
# SECTION 10: SUMMARY VERDICT
# =============================================================================

func _section_10_verdict() -> void:
	_print_header("SECTION 10: SUMMARY VERDICT")

	# Gather section results
	for section_name in ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9"]:
		var p := 0
		var f := 0
		for r: Dictionary in _results:
			if r.section == section_name:
				if r.status == "PASS":
					p += 1
				elif r.status == "FAIL":
					f += 1
		_section_pass[section_name] = [p, f]

	_log("=== VERDICT ===")
	var sections := {
		"S1": "Raw data valid",
		"S2": "Conversion formula correct",
		"S3": "Bone name mapping complete",
		"S4": "Pipeline wiring correct",
		"S5": "Manual pose works",
		"S6": "AnimationPlayer works",
		"S7": "AnimationTree works",
		"S8": "Pipeline vs raw comparison",
		"S9": "Walk animation works",
	}

	for key: String in sections:
		var counts: Array = _section_pass.get(key, [0, 0])
		var status := "YES" if counts[1] == 0 and counts[0] > 0 else "NO" if counts[1] > 0 else "N/A"
		_log("  %s: %s (%d pass, %d fail)" % [sections[key], status, counts[0], counts[1]])

	_log("")
	_log("If S5 fails → animation DATA is wrong (conversion/coordinate issue)")
	_log("If S5 passes but S6 fails → AnimationPlayer wiring is wrong")
	_log("If S6 passes but S7 fails → AnimationTree/state machine is wrong")
	_log("If all pass → visual issue may be in body part assembly, not animation")


# =============================================================================
# HELPERS: NPC VERIFICATION
# =============================================================================

func _verify_npc_structure(character: Node) -> void:
	var skeleton := _find_node_of_type(character, "Skeleton3D") as Skeleton3D
	_result("S4", "skeleton_found", str(skeleton != null), "PASS" if skeleton else "FAIL")

	if skeleton:
		_result("S4", "bone_count", str(skeleton.get_bone_count()), "INFO")

		var has_hips := skeleton.find_bone("Hips") >= 0
		var has_spine := skeleton.find_bone("Spine") >= 0
		var has_head := skeleton.find_bone("Head") >= 0
		_result("S4", "profile_names", "Hips=%s Spine=%s Head=%s" % [has_hips, has_spine, has_head],
			"PASS" if (has_hips and has_spine and has_head) else "FAIL")

	var anim_player := _find_node_of_type(character, "AnimationPlayer") as AnimationPlayer
	_result("S4", "anim_player_found", str(anim_player != null), "PASS" if anim_player else "FAIL")

	if anim_player:
		var anims := anim_player.get_animation_list()
		_result("S4", "animation_count", str(anims.size()), "PASS" if anims.size() > 0 else "FAIL")

		var has_idle := false
		for anim_name in anims:
			if "idle" in String(anim_name).to_lower():
				has_idle = true
				break
		_result("S4", "has_idle_anim", str(has_idle), "PASS" if has_idle else "FAIL")

		var ap_parent := anim_player.get_parent()
		_result("S4", "anim_player_parent", ap_parent.get_class() if ap_parent else "NONE",
			"PASS" if ap_parent is Skeleton3D else "WARN")

		for anim_name in anims:
			if "idle" in String(anim_name).to_lower():
				var anim: Animation = anim_player.get_animation(anim_name)
				for t in mini(5, anim.get_track_count()):
					var path := anim.track_get_path(t)
					var track_type := anim.track_get_type(t)
					var type_name := "ROT" if track_type == Animation.TYPE_ROTATION_3D else "POS" if track_type == Animation.TYPE_POSITION_3D else "OTHER"
					_result("S4", "track_%d" % t, "%s (%s)" % [path, type_name], "INFO")
				break

	var anim_tree := _find_node_of_type(character, "AnimationTree") as AnimationTree
	_result("S4", "anim_tree_found", str(anim_tree != null), "PASS" if anim_tree else "FAIL")

	if anim_tree:
		_result("S4", "tree_active", str(anim_tree.active), "PASS" if anim_tree.active else "FAIL")

		var sm = anim_tree.get("parameters/locomotion/playback")
		if sm:
			var current = sm.get_current_node()
			_result("S4", "state_machine", "current=%s" % current, "PASS" if not String(current).is_empty() else "WARN")
		else:
			_result("S4", "state_machine", "PLAYBACK NOT FOUND", "FAIL")


# =============================================================================
# HELPERS: FILE OUTPUT
# =============================================================================

func _save_results_to_file() -> void:
	var file := FileAccess.open(_output_file_path, FileAccess.WRITE)
	if not file:
		_log("[color=red]Failed to open output file: %s[/color]" % _output_file_path)
		return

	file.store_line("ANIMATION DIAGNOSTIC REPORT")
	file.store_line("Date: %s" % Time.get_datetime_string_from_system())
	file.store_line("Mode: %s" % ("PREBAKED" if _using_prebaked else "FULL_PIPELINE"))
	file.store_line("=" .repeat(70))
	file.store_line("")

	for r: Dictionary in _results:
		file.store_line("[%s] %s: %s | %s" % [r.section, r.key, r.value, r.status])

	file.store_line("")
	file.store_line("=" .repeat(70))

	for section_name in ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9"]:
		var p := 0
		var f := 0
		for r: Dictionary in _results:
			if r.section == section_name:
				if r.status == "PASS": p += 1
				elif r.status == "FAIL": f += 1
		file.store_line("%s: %d pass, %d fail" % [section_name, p, f])

	file.close()
	_log("Results saved to: %s" % _output_file_path)


# =============================================================================
# HELPERS: DATA LOADING
# =============================================================================

func _get_converted_idle(skeleton: Skeleton3D) -> Animation:
	var kf_data := BSAManager.extract_file("meshes\\xbase_anim.kf")
	if kf_data.is_empty():
		return null

	var cached_skel: Skeleton3D = MorrowindNPCAssembler._skeleton_cache.get("humanoid")
	if not cached_skel:
		return null

	var loader := NIFKFLoaderScript.new()
	var animations: Dictionary = loader.load_kf_buffer(kf_data, null)

	var raw_lib := AnimationLibrary.new()
	for anim_name: String in animations:
		raw_lib.add_animation(anim_name, animations[anim_name])

	# Remap bone names to profile (matching skeleton) — no rest-relative conversion
	var remap := CharacterFactoryV2Script._humanoid_bone_remap
	if not remap.is_empty():
		raw_lib = RetargetSetupScript.remap_library(raw_lib, remap)
	return _find_idle_in_lib(raw_lib)


func _get_raw_idle(skeleton: Skeleton3D) -> Animation:
	var kf_data := BSAManager.extract_file("meshes\\xbase_anim.kf")
	if kf_data.is_empty():
		return null

	var loader := NIFKFLoaderScript.new()
	var animations: Dictionary = loader.load_kf_buffer(kf_data, null)

	# Remap bone names to profile (matching skeleton) but NO rest-relative conversion
	var raw_lib := AnimationLibrary.new()
	for anim_name: String in animations:
		raw_lib.add_animation(anim_name, animations[anim_name])
	var remap := CharacterFactoryV2Script._humanoid_bone_remap
	if not remap.is_empty():
		raw_lib = RetargetSetupScript.remap_library(raw_lib, remap)
	return _find_idle_in_lib(raw_lib)


func _create_raw_animation_npc() -> Skeleton3D:
	# Build a second skeleton with RAW (unconverted) animations
	var cached_skel: Skeleton3D = MorrowindNPCAssembler._skeleton_cache.get("humanoid")
	if not cached_skel:
		return null

	# Duplicate skeleton
	var skeleton := MorrowindNPCAssembler._duplicate_skeleton(cached_skel)
	var container := Node3D.new()
	container.name = "NPC_B_Raw"
	container.add_child(skeleton)
	add_child(container)
	container.global_position = Vector3(2, 0, 0)  # Offset from NPC A
	_npc_b = container

	# Rename bones to profile names
	var rename_map := RetargetSetupScript.rename_bones_to_profile(skeleton)

	# Load raw KF animations (NO conversion)
	var kf_data := BSAManager.extract_file("meshes\\xbase_anim.kf")
	if kf_data.is_empty():
		return null

	var loader := NIFKFLoaderScript.new()
	var animations: Dictionary = loader.load_kf_buffer(kf_data, null)

	# Build library with remap only (no rest-relative conversion)
	var lib := AnimationLibrary.new()
	for anim_name: String in animations:
		lib.add_animation(anim_name, animations[anim_name])

	# Remap bone names in tracks
	var remap := CharacterFactoryV2Script._humanoid_bone_remap
	if not remap.is_empty():
		lib = RetargetSetupScript.remap_library(lib, remap)

	# Create AnimationPlayer
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	skeleton.add_child(player)
	player.add_animation_library("", lib)

	# Play idle directly (no AnimationTree)
	var idle_name := ""
	for anim_name in player.get_animation_list():
		if "idle" in String(anim_name).to_lower():
			idle_name = anim_name
			break
	if not idle_name.is_empty():
		player.play(idle_name)

	return skeleton


# =============================================================================
# HELPERS: POSE APPLICATION
# =============================================================================

func _apply_animation_frame(skeleton: Skeleton3D, anim: Animation, time: float) -> void:
	var bone_tracks := _map_bone_tracks(anim)

	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i).to_lower()
		if bone_name not in bone_tracks:
			skeleton.set_bone_pose_rotation(i, Quaternion.IDENTITY)
			skeleton.set_bone_pose_position(i, Vector3.ZERO)
			continue

		var info: Dictionary = bone_tracks[bone_name]

		if info.has("rot_idx"):
			var rot_idx: int = info["rot_idx"]
			if anim.track_get_key_count(rot_idx) > 0:
				var rot: Quaternion = anim.rotation_track_interpolate(rot_idx, time)
				skeleton.set_bone_pose_rotation(i, rot)

		if info.has("pos_idx"):
			var pos_idx: int = info["pos_idx"]
			if anim.track_get_key_count(pos_idx) > 0:
				var pos: Vector3 = anim.position_track_interpolate(pos_idx, time)
				skeleton.set_bone_pose_position(i, pos)


# =============================================================================
# HELPERS: ANATOMY CHECK
# =============================================================================

func _check_anatomy(skeleton: Skeleton3D) -> Dictionary:
	var head := _get_bone_world_pos(skeleton, "Head")
	var hips := _get_bone_world_pos(skeleton, "Hips")
	var l_foot := _get_bone_world_pos(skeleton, "LeftFoot")
	var r_foot := _get_bone_world_pos(skeleton, "RightFoot")
	var l_hand := _get_bone_world_pos(skeleton, "LeftHand")
	var r_hand := _get_bone_world_pos(skeleton, "RightHand")

	var head_above_hips := head.y > hips.y if head.y != INF and hips.y != INF else false
	var feet_below_hips := (l_foot.y < hips.y or l_foot.y == INF) and (r_foot.y < hips.y or r_foot.y == INF)
	var body_height := (head.y - minf(l_foot.y, r_foot.y)) if head.y != INF else 0.0
	# Hips should be between head and feet (relative check, not absolute Y)
	var hips_between := (hips.y < head.y and hips.y > minf(l_foot.y, r_foot.y)) if (head.y != INF and hips.y != INF) else false
	var no_collapse := head.distance_to(hips) > 0.1 if head.y != INF and hips.y != INF else false

	var all_pass := head_above_hips and feet_below_hips and body_height > 0.3 and hips_between and no_collapse

	return {
		"pass": all_pass,
		"head": head, "hips": hips,
		"l_foot": l_foot, "r_foot": r_foot,
		"l_hand": l_hand, "r_hand": r_hand,
		"head_above_hips": head_above_hips,
		"feet_below_hips": feet_below_hips,
		"body_height": body_height,
		"hips_between": hips_between,
		"no_collapse": no_collapse,
	}


func _anatomy_summary(a: Dictionary) -> String:
	return "head_above=%s feet_below=%s height=%.2fm hips_between=%s no_collapse=%s" % [
		a.head_above_hips, a.feet_below_hips, a.body_height, a.hips_between, a.no_collapse]


func _max_anatomy_diff(a: Dictionary, b: Dictionary) -> float:
	var max_diff := 0.0
	for key in ["head", "hips", "l_foot", "r_foot"]:
		var va: Vector3 = a[key]
		var vb: Vector3 = b[key]
		if va.y != INF and vb.y != INF:
			max_diff = maxf(max_diff, va.distance_to(vb))
	return max_diff


func _get_bone_world_pos(skeleton: Skeleton3D, bone_name: String) -> Vector3:
	var idx := skeleton.find_bone(bone_name)
	if idx < 0:
		return Vector3(INF, INF, INF)
	var global_pose := skeleton.get_bone_global_pose(idx)
	return skeleton.global_transform * global_pose.origin


# =============================================================================
# HELPERS: ANIMATION UTILITIES
# =============================================================================

func _find_idle_anim(animations: Dictionary) -> Animation:
	for anim_name: String in animations:
		if anim_name.to_lower() == "idle":
			return animations[anim_name]
	for anim_name: String in animations:
		if "idle" in anim_name.to_lower():
			return animations[anim_name]
	return null


func _find_idle_in_lib(lib: AnimationLibrary) -> Animation:
	for anim_name in lib.get_animation_list():
		if String(anim_name).to_lower() == "idle":
			return lib.get_animation(anim_name)
	for anim_name in lib.get_animation_list():
		if "idle" in String(anim_name).to_lower():
			return lib.get_animation(anim_name)
	return null


func _map_bone_tracks(anim: Animation) -> Dictionary:
	var result: Dictionary = {}
	for t in anim.get_track_count():
		var path := anim.track_get_path(t)
		if path.get_subname_count() == 0:
			continue
		var bone_name := String(path.get_subname(0)).to_lower()
		if bone_name not in result:
			result[bone_name] = {}
		var track_type := anim.track_get_type(t)
		match track_type:
			Animation.TYPE_ROTATION_3D:
				result[bone_name]["rot_idx"] = t
			Animation.TYPE_POSITION_3D:
				result[bone_name]["pos_idx"] = t
			Animation.TYPE_SCALE_3D:
				result[bone_name]["scale_idx"] = t
	return result


func _quat_angle_deg(a: Quaternion, b: Quaternion) -> float:
	var dot := a.dot(b)
	if dot < 0:
		b = -b
		dot = -dot
	dot = clampf(dot, -1.0, 1.0)
	return rad_to_deg(2.0 * acos(dot))


# =============================================================================
# HELPERS: SCENE / UI
# =============================================================================

func _find_node_of_type(root: Node, type_name: String) -> Node:
	if root.get_class() == type_name:
		return root
	for child in root.get_children():
		var found := _find_node_of_type(child, type_name)
		if found:
			return found
	return null


func _setup_scene() -> void:
	# Camera
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.position = Vector3(0, 1.2, 3)
	camera.look_at(Vector3(0, 0.8, 0))
	add_child(camera)

	# Light
	var light := DirectionalLight3D.new()
	light.name = "Light"
	light.rotation_degrees = Vector3(-45, -30, 0)
	add_child(light)

	# Ground (visual + collision)
	var ground_body := StaticBody3D.new()
	ground_body.name = "Ground"
	add_child(ground_body)

	var ground_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(10, 10)
	ground_mesh.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.3, 0.3)
	ground_mesh.material_override = mat
	ground_body.add_child(ground_mesh)

	var ground_col := CollisionShape3D.new()
	ground_col.shape = WorldBoundaryShape3D.new()
	ground_body.add_child(ground_col)


func _setup_ui() -> void:
	_label = RichTextLabel.new()
	_label.name = "OutputLabel"
	_label.bbcode_enabled = true
	_label.scroll_following = true
	_label.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_label.size = Vector2(600, 700)
	_label.position = Vector2(10, 10)
	_label.add_theme_font_size_override("normal_font_size", 11)
	add_child(_label)


func _ensure_data_loaded() -> void:
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
	if data_path.is_empty():
		_log("[color=red]No Morrowind data path![/color]")
		return

	if not BSAManager.has_file("meshes\\xbase_anim.nif"):
		_log("Loading BSA archives...")
		BSAManager.load_archives_from_directory(data_path)
		await get_tree().process_frame

	if ESMManager.cells.is_empty():
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		_log("Loading ESM: %s" % esm_file)
		ESMManager.load_file(esm_path)
		await get_tree().process_frame


func _cleanup_npcs() -> void:
	if _npc_a:
		_npc_a.queue_free()
		_npc_a = null
	if _npc_b:
		_npc_b.queue_free()
		_npc_b = null


# =============================================================================
# HELPERS: LOGGING / RESULTS
# =============================================================================

func _result(section: String, key: String, value: String, status: String) -> void:
	_results.append({"section": section, "key": key, "value": value, "status": status})

	var color := "white"
	match status:
		"PASS": color = "green"
		"FAIL": color = "red"
		"WARN": color = "yellow"
		"INFO": color = "gray"

	var line := "[%s] %s: %s | [color=%s]%s[/color]" % [section, key, value, color, status]
	print("[%s] %s: %s | %s" % [section, key, value, status])

	if _label:
		_label.append_text(line + "\n")


func _log(text: String) -> void:
	# Strip BBCode for print
	var plain := text
	while "[color=" in plain:
		var start := plain.find("[color=")
		var end := plain.find("]", start)
		if end >= 0:
			plain = plain.substr(0, start) + plain.substr(end + 1)
	plain = plain.replace("[/color]", "")
	print(plain)

	if _label:
		_label.append_text(text + "\n")


func _print_header(title: String) -> void:
	var sep := "=" .repeat(70)
	_log(sep)
	_log("[b]%s[/b]" % title)
	_log(sep)


func _v3str(v: Vector3) -> String:
	if v.y == INF:
		return "(MISSING)"
	return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]


func _dump_full_report() -> void:
	print("")
	print("=" .repeat(70))
	print("FULL DIAGNOSTIC REPORT")
	print("=" .repeat(70))
	for r: Dictionary in _results:
		print("[%s] %s: %s | %s" % [r.section, r.key, r.value, r.status])
	print("=" .repeat(70))
