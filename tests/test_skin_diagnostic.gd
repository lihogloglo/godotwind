## Diagnostic test for character skinning pipeline
## Identifies bugs in NIF inverse bind extraction and Skin resource construction
## Run with: godot --headless --script res://tests/test_skin_diagnostic.gd
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_cast")
extends SceneTree

const BSAReader := preload("res://src/core/bsa/bsa_reader.gd")
const NIFDefs := preload("res://src/core/nif/nif_defs.gd")
const CS := preload("res://src/core/coordinate_system.gd")

# Late-loaded to avoid compile errors (these scripts use Log autoload)
var NIFReader: GDScript
var NIFSkeletonBuilder: GDScript
var MeshExtractor: GDScript

var _bsa: BSAReader
var _pass_count := 0
var _fail_count := 0
var _info_messages: Array[String] = []


func _init() -> void:
	await process_frame
	_run_all()
	_report()
	quit(1 if _fail_count > 0 else 0)


func _run_all() -> void:
	print("=" .repeat(70))
	print("SKIN DIAGNOSTIC TEST")
	print("=" .repeat(70))
	print("")

	# Late-load scripts that depend on Log autoload (bypass compilation cache)
	NIFReader = ResourceLoader.load("res://src/core/nif/nif_reader.gd", "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	NIFSkeletonBuilder = ResourceLoader.load("res://src/core/nif/nif_skeleton_builder.gd", "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	MeshExtractor = ResourceLoader.load("res://src/core/character/mesh_extractor.gd", "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	# Find BSA
	var bsa_path := _find_morrowind_bsa()
	if bsa_path.is_empty():
		print("ERROR: Could not find Morrowind.bsa — cannot run diagnostic")
		_fail_count += 1
		return

	_bsa = BSAReader.new()
	if _bsa.open(bsa_path) != OK:
		print("ERROR: Could not open BSA")
		_fail_count += 1
		return

	# Test 1: Empirical Skin.add_bind() verification
	_test_skin_add_bind_semantics()

	# Test 2: Load skeleton from xbase_anim.nif
	var skeleton := _load_skeleton()
	if skeleton == null:
		print("ERROR: Could not load skeleton — skipping body part tests")
		_bsa.close()
		return

	# Test 3: Check skin_transform and inverse binds for body parts
	var body_parts := [
		"meshes\\b\\b_n_dark elf_m_head_01.nif",
		"meshes\\b\\b_n_dark elf_m_chest.nif",
		"meshes\\b\\b_n_dark elf_m_wrist.nif",
		"meshes\\b\\b_n_dark elf_m_forearm.nif",
		"meshes\\b\\b_n_dark elf_m_upper arm.nif",
		"meshes\\b\\b_n_dark elf_m_groin.nif",
		"meshes\\b\\b_n_dark elf_m_knee.nif",
		"meshes\\b\\b_n_dark elf_m_upper leg.nif",
		"meshes\\b\\b_n_dark elf_m_ankle.nif",
		"meshes\\b\\b_n_dark elf_m_foot.nif",
		"meshes\\b\\b_n_dark elf_m_neck.nif",
		"meshes\\b\\b_n_breton_m_hair_01.nif",
	]

	print("")
	print("-" .repeat(70))
	print("SUITE: NiSkinData.skin_transform Analysis")
	print("-" .repeat(70))

	var non_identity_count := 0
	var total_skinned := 0
	var total_static := 0

	for path in body_parts:
		if not _bsa.has_file(path):
			print("  SKIP: %s (not in BSA)" % path)
			continue

		@warning_ignore("untyped_declaration")
		var result = _analyze_body_part(path, skeleton)
		if result == null:
			continue

		if result["is_skinned"]:
			total_skinned += 1
			if not result["skin_transform_is_identity"]:
				non_identity_count += 1
		else:
			total_static += 1

	_assert_true(total_skinned > 0, "At least one skinned body part found")
	print("")
	_info("Skinned body parts: %d, Static: %d" % [total_skinned, total_static])
	_info("Body parts with non-identity skin_transform: %d / %d" % [non_identity_count, total_skinned])

	# Test 4: Compare NIF inverse binds vs skeleton-rest-computed
	print("")
	print("-" .repeat(70))
	print("SUITE: NIF Inverse Binds vs Skeleton-Rest Comparison")
	print("-" .repeat(70))

	_compare_inverse_binds(skeleton, body_parts)

	# Cleanup
	skeleton.free()
	_bsa.close()


## ============================================================================
## TEST: Skin.add_bind() semantics
## ============================================================================

func _test_skin_add_bind_semantics() -> void:
	print("-" .repeat(70))
	print("SUITE: Skin.add_bind() Semantics")
	print("-" .repeat(70))

	# Create a simple 2-bone skeleton: root at origin, child at (0, 1, 0)
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("Root")
	skeleton.add_bone("Child")
	skeleton.set_bone_parent(1, 0)
	skeleton.set_bone_rest(0, Transform3D.IDENTITY)
	skeleton.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))

	# The global rest of Child = Root_rest * Child_rest = Identity * T(0,1,0) = T(0,1,0)
	var child_global_rest := skeleton.get_bone_global_rest(1)
	_assert_approx_vec3(child_global_rest.origin, Vector3(0, 1, 0), 0.001,
		"Child bone global rest at (0,1,0)")

	# The inverse bind for Child = inv(child_global_rest)
	var inv_bind := child_global_rest.affine_inverse()
	_assert_approx_vec3(inv_bind.origin, Vector3(0, -1, 0), 0.001,
		"Inverse bind origin at (0,-1,0)")

	# The bind pose (non-inverse) for Child = child_global_rest itself
	var bind_pose := child_global_rest

	# Create two skins — one with inverse bind, one with bind pose
	var skin_inv := Skin.new()
	skin_inv.add_bind(0, Transform3D.IDENTITY)  # Root: identity inv bind
	skin_inv.add_bind(1, inv_bind)  # Child: inverse bind

	var skin_bp := Skin.new()
	skin_bp.add_bind(0, Transform3D.IDENTITY)  # Root: identity
	skin_bp.add_bind(1, bind_pose)  # Child: bind pose (NOT inverse)

	# Check what get_bind_pose returns
	var stored_inv := skin_inv.get_bind_pose(1)
	var stored_bp := skin_bp.get_bind_pose(1)

	_assert_approx_vec3(stored_inv.origin, inv_bind.origin, 0.001,
		"Skin stores inv_bind as-is")
	_assert_approx_vec3(stored_bp.origin, bind_pose.origin, 0.001,
		"Skin stores bind_pose as-is")

	# Godot docs: Skin stores what you pass to add_bind() directly.
	# The rendering pipeline then uses it. We need to determine which
	# interpretation (inv_bind or bind_pose) produces correct results.
	# Based on Godot glTF importer: it passes inverse_bind directly.
	# So add_bind() expects INVERSE BIND MATRIX.
	_info("Skin.add_bind() stores values as-is (no inversion)")
	_info("glTF importer passes inverse bind matrices → add_bind() expects inverse bind")

	skeleton.free()


## ============================================================================
## SKELETON LOADING
## ============================================================================

func _load_skeleton() -> Skeleton3D:
	print("")
	print("-" .repeat(70))
	print("SUITE: Skeleton Loading")
	print("-" .repeat(70))

	var skel_path := "meshes\\xbase_anim.nif"
	if not _bsa.has_file(skel_path):
		print("  SKIP: xbase_anim.nif not in BSA")
		return null

	var data := _bsa.extract_file(skel_path)
	_assert_true(data.size() > 0, "xbase_anim.nif extracted (%d bytes)" % data.size())

	var reader = NIFReader.new()
	var err = reader.load_buffer(data)
	_assert_true(err == OK, "xbase_anim.nif parsed successfully")

	var builder = NIFSkeletonBuilder.new()
	builder.init(reader)

	# Find root node (Bip01)
	var root_node: NIFDefs.NiNode = null
	for record in reader.records:
		if record is NIFDefs.NiNode:
			var node := record as NIFDefs.NiNode
			if node.name and node.name.to_lower() == "bip01":
				root_node = node
				break

	_assert_true(root_node != null, "Found Bip01 root node")
	if root_node == null:
		return null

	var skeleton: Skeleton3D = builder.build_skeleton_from_hierarchy(root_node)
	_assert_true(skeleton != null, "Built skeleton from hierarchy")
	if skeleton == null:
		return null

	_assert_true(skeleton.get_bone_count() >= 20, "Skeleton has >= 20 bones (got %d)" % skeleton.get_bone_count())

	print("  Skeleton bones:")
	for i in mini(skeleton.get_bone_count(), 10):
		var bone_name: String = skeleton.get_bone_name(i)
		var bone_parent: int = skeleton.get_bone_parent(i)
		var bone_rest: Transform3D = skeleton.get_bone_rest(i)
		print("    %2d: %-25s parent=%2d pos=%s" % [i, bone_name, bone_parent, bone_rest.origin])
	if skeleton.get_bone_count() > 10:
		print("    ... and %d more" % (skeleton.get_bone_count() - 10))

	return skeleton


## ============================================================================
## BODY PART ANALYSIS
## ============================================================================

func _analyze_body_part(path: String, skeleton: Skeleton3D) -> Variant:
	var data := _bsa.extract_file(path)
	if data.is_empty():
		print("  FAIL: Could not extract %s" % path)
		return null

	var reader = NIFReader.new()
	if reader.load_buffer(data) != OK:
		print("  FAIL: Could not parse %s" % path)
		return null

	# Find NiSkinData to check skin_transform
	var skin_data_record: NIFDefs.NiSkinData = null
	var skin_inst_record: NIFDefs.NiSkinInstance = null
	var skinned_geom: NIFDefs.NiGeometry = null

	for record in reader.records:
		if record is NIFDefs.NiSkinData:
			skin_data_record = record as NIFDefs.NiSkinData
		elif record is NIFDefs.NiSkinInstance:
			skin_inst_record = record as NIFDefs.NiSkinInstance
		elif record is NIFDefs.NiGeometry:
			var geom := record as NIFDefs.NiGeometry
			if geom.skin_index >= 0 and skinned_geom == null:
				skinned_geom = geom

	var short_name := path.get_file()

	if skin_data_record == null:
		print("  %-40s → STATIC (no skin data)" % short_name)
		return {"is_skinned": false, "skin_transform_is_identity": true}

	# Check skin_transform
	var st := skin_data_record.skin_transform
	var st_t3d := st.to_transform3d()
	var is_identity := _is_transform_identity(st_t3d, 0.01)

	var st_godot := CS.transform_to_godot(st_t3d)
	print("  %-40s → SKINNED, %d bones, skin_transform=%s" % [
		short_name,
		skin_data_record.bones.size(),
		"IDENTITY" if is_identity else "NON-IDENTITY pos=%s" % str(st_godot.origin)
	])

	if not is_identity:
		print("    skin_transform (NIF): translate=%s scale=%.3f" % [str(st.translation), st.scale])
		print("    skin_transform (Godot): translate=%s" % str(st_godot.origin))

	return {
		"is_skinned": true,
		"skin_transform_is_identity": is_identity,
		"skin_data": skin_data_record,
		"skin_instance": skin_inst_record,
		"reader": reader,
	}


## ============================================================================
## INVERSE BIND COMPARISON
## ============================================================================

func _compare_inverse_binds(skeleton: Skeleton3D, body_parts: Array) -> void:
	# Pick first available skinned body part
	var test_path := ""
	var test_reader: NIFReader = null
	var test_skin_data: NIFDefs.NiSkinData = null
	var test_skin_inst: NIFDefs.NiSkinInstance = null

	for path in body_parts:
		if not _bsa.has_file(path):
			continue

		var data := _bsa.extract_file(path)
		if data.is_empty():
			continue

		var reader = NIFReader.new()
		if reader.load_buffer(data) != OK:
			continue

		for record in reader.records:
			if record is NIFDefs.NiSkinInstance:
				test_skin_inst = record as NIFDefs.NiSkinInstance
			elif record is NIFDefs.NiSkinData:
				test_skin_data = record as NIFDefs.NiSkinData

		if test_skin_data != null and test_skin_inst != null:
			test_path = path
			test_reader = reader
			break

	if test_skin_data == null:
		print("  SKIP: No skinned body part found for comparison")
		return

	print("  Comparing for: %s" % test_path.get_file())

	# Get the skin_transform
	var skin_xform_nif := test_skin_data.skin_transform.to_transform3d()
	var skin_xform_godot := CS.transform_to_godot(skin_xform_nif)
	var skin_xform_is_identity := _is_transform_identity(skin_xform_nif, 0.01)

	print("  skin_transform is identity: %s" % str(skin_xform_is_identity))

	var max_pos_delta := 0.0
	var max_rot_delta := 0.0
	var bones_compared := 0
	var bones_mismatched := 0

	for i in test_skin_data.bones.size():
		if i >= test_skin_inst.bone_indices.size():
			break

		# Get bone name from NIF
		var bone_node_idx: int = test_skin_inst.bone_indices[i]
		var bone_node := test_reader.get_record(bone_node_idx) as NIFDefs.NiNode
		if bone_node == null or bone_node.name == null:
			continue

		var bone_name: String = bone_node.name

		# Find matching bone in skeleton
		var skel_idx := skeleton.find_bone(bone_name)
		if skel_idx < 0:
			# Try case-insensitive
			for j in skeleton.get_bone_count():
				if skeleton.get_bone_name(j).to_lower() == bone_name.to_lower():
					skel_idx = j
					break

		if skel_idx < 0:
			continue

		bones_compared += 1

		# Method A: NIF's per-bone inverse bind (converted to Godot)
		var bone_info: Dictionary = test_skin_data.bones[i]
		var bone_xform: NIFDefs.NIFTransform = bone_info["transform"]
		var nif_inv_bind := CS.transform_to_godot(bone_xform.to_transform3d())

		# Method B: Composed with skin_transform
		var nif_composed := nif_inv_bind * skin_xform_godot

		# Method C: Computed from skeleton rest
		var skel_inv_bind := skeleton.get_bone_global_rest(skel_idx).affine_inverse()

		# Compare Method C (current code) vs Method B (correct for NIF)
		var pos_delta := (skel_inv_bind.origin - nif_composed.origin).length()
		var rot_delta := skel_inv_bind.basis.get_euler().distance_to(nif_composed.basis.get_euler())

		max_pos_delta = maxf(max_pos_delta, pos_delta)
		max_rot_delta = maxf(max_rot_delta, rot_delta)

		if pos_delta > 0.01 or rot_delta > 0.01:
			bones_mismatched += 1
			if bones_mismatched <= 5:
				print("    MISMATCH bone '%s':" % bone_name)
				print("      Skeleton rest inv:  pos=%s" % str(skel_inv_bind.origin))
				print("      NIF composed:       pos=%s" % str(nif_composed.origin))
				print("      Delta:              pos=%.6f rot=%.6f" % [pos_delta, rot_delta])

	_assert_true(bones_compared > 0, "Compared %d bones" % bones_compared)
	_info("Bones compared: %d, Mismatched: %d" % [bones_compared, bones_mismatched])
	_info("Max position delta: %.6f meters" % max_pos_delta)
	_info("Max rotation delta: %.6f radians" % max_rot_delta)

	if bones_mismatched > 0:
		print("  WARNING: %d bones have mismatched inverse binds!" % bones_mismatched)
		print("  This confirms Bug #1 and #2 — NIF data differs from skeleton-rest computation")
	else:
		print("  INFO: All inverse binds match — skin_transform may be identity for these parts")
		print("  The fix still improves robustness (uses NIF source data)")


## ============================================================================
## HELPERS
## ============================================================================

func _is_transform_identity(t: Transform3D, epsilon: float) -> bool:
	var pos_len := t.origin.length()
	# Compare basis columns to identity basis columns
	var dx := (t.basis.x - Basis.IDENTITY.x).length()
	var dy := (t.basis.y - Basis.IDENTITY.y).length()
	var dz := (t.basis.z - Basis.IDENTITY.z).length()
	var basis_dist := Vector3(dx, dy, dz).length()
	return pos_len < epsilon and basis_dist < epsilon and absf(1.0 - t.basis.determinant()) < epsilon


func _assert_true(condition: bool, desc: String) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % desc)
	else:
		_fail_count += 1
		print("  FAIL: %s" % desc)


func _assert_approx_vec3(actual: Vector3, expected: Vector3, epsilon: float, desc: String) -> void:
	if actual.distance_to(expected) < epsilon:
		_pass_count += 1
		print("  PASS: %s" % desc)
	else:
		_fail_count += 1
		print("  FAIL: %s (got %s, expected %s)" % [desc, str(actual), str(expected)])


func _info(msg: String) -> void:
	_info_messages.append(msg)
	print("  INFO: %s" % msg)


func _report() -> void:
	print("")
	print("=" .repeat(70))
	print("  Total: %d | Passed: %d | Failed: %d" % [
		_pass_count + _fail_count, _pass_count, _fail_count])
	if _fail_count == 0:
		print("  ALL TESTS PASSED")
	else:
		print("  SOME TESTS FAILED")
	print("=" .repeat(70))


func _find_morrowind_bsa() -> String:
	# Try SettingsManager first (if autoloads are loaded)
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		var settings := main_loop.root.get_node_or_null("/root/SettingsManager")
		if settings and settings.has_method("get_morrowind_install_path"):
			var mw_path: String = settings.get_morrowind_install_path()
			if not mw_path.is_empty():
				var bsa := mw_path.path_join("Data Files").path_join("Morrowind.bsa")
				if FileAccess.file_exists(bsa):
					return bsa

	# Fallback: common paths
	var possible_paths := [
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"C:/Program Files/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"D:/Games/Morrowind/Data Files/Morrowind.bsa",
		"D:/SteamLibrary/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
	]
	for path in possible_paths:
		if FileAccess.file_exists(path):
			return path
	return ""
