## ModelPrebaker - Converts all unique NIF models to Godot resources ahead of time
##
## This eliminates runtime NIF conversion entirely by pre-converting all models
## referenced in the ESM file. The disk cache in ModelLoader then loads these
## instantly on subsequent runs.
##
## Process:
## 1. Scan all ESM records to collect unique model paths
## 2. For each model: extract from BSA, convert NIF, save as .mesh + .res
## 3. Results saved to Documents/Godotwind/cache/models/
##
## Performance:
## - First run (prebaking): ~5-30 minutes depending on model count
## - Subsequent game loads: Near-instant model loading (0.1-0.2ms per model)
class_name ModelPrebaker
extends RefCounted

const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const NIFKFLoader := preload("res://src/core/nif/nif_kf_loader.gd")
const StreamingPolicyScript := preload("res://src/core/world/streaming_policy.gd")

## Output directory (set from SettingsManager)
var output_dir: String = ""

## Animation output directory
var animation_output_dir: String = ""

## Skip models that already exist in cache
var skip_existing: bool = true

## Progress tracking
signal progress(current: int, total: int, model_name: String)
signal model_baked(model_path: String, success: bool, mesh_count: int)
signal animation_baked(anim_path: String, success: bool, anim_count: int)
signal batch_complete(total: int, success: int, failed: int, skipped: int)

## Statistics
var _total_baked: int = 0
var _total_failed: int = 0
var _total_skipped: int = 0
var _failed_models: Array[String] = []


## Initialize the baker
func initialize() -> Error:
	if output_dir.is_empty():
		output_dir = SettingsManager.get_models_path()

	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("ModelPrebaker: Failed to create cache directories")
		return err

	Log.info("prebaking", "ModelPrebaker initialized - output dir: %s" % output_dir)
	return OK


## Bake all unique models from ESM
func bake_all_models() -> Dictionary:
	if initialize() != OK:
		return {"success": 0, "failed": 0, "skipped": 0}

	_total_baked = 0
	_total_failed = 0
	_total_skipped = 0
	_failed_models.clear()

	# Collect all unique model paths from ESM
	var model_paths := _collect_unique_models()
	Log.info("prebaking", "Found %d unique models to bake" % model_paths.size())

	# Bake each model
	for i in range(model_paths.size()):
		var model_path: String = model_paths[i]
		progress.emit(i + 1, model_paths.size(), model_path.get_file())

		# Check if already cached
		if skip_existing and _model_cached(model_path):
			_total_skipped += 1
			continue

		var result := bake_model(model_path)
		if result.success:
			_total_baked += 1
		else:
			_total_failed += 1
			_failed_models.append(model_path)

		# Yield every 10 models to prevent UI freeze
		if i % 10 == 0:
			var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
			if main_loop:
				await main_loop.process_frame

	batch_complete.emit(model_paths.size(), _total_baked, _total_failed, _total_skipped)

	Log.info("prebaking", "Models complete - %d baked, %d skipped, %d failed" % [
		_total_baked, _total_skipped, _total_failed])

	return {
		"total": model_paths.size(),
		"success": _total_baked,
		"failed": _total_failed,
		"skipped": _total_skipped,
		"failed_models": _failed_models.duplicate()
	}


## Bake a single model
func bake_model(model_path: String) -> Dictionary:
	# Load NIF from BSA
	var nif_data := _load_nif(model_path)
	if nif_data.is_empty():
		Log.warn("prebaking", "FAIL (not in BSA): %s" % model_path)
		model_baked.emit(model_path, false, 0)
		return {"success": false, "error": "NIF not found in BSA"}

	# Check if this is a skeleton or body part (needs animations enabled)
	var path_lower := model_path.to_lower()
	var is_character_model := (
		path_lower.contains("base_anim") or
		path_lower.begins_with("b_") or
		path_lower.contains("/b_") or
		path_lower.contains("\\b_")
	)

	# Convert NIF to Godot scene.
	# LOD generation is DISABLED here — we merge multi-mesh children first,
	# then generate LODs on the combined mesh (one LOD chain per object).
	var converter := NIFConverter.new()
	converter.load_textures = true
	converter.load_animations = is_character_model
	converter.load_collision = not is_character_model
	converter.generate_lods = false  # Deferred — applied after merge below
	converter.generate_occluders = not is_character_model

	var model := converter.convert_buffer(nif_data, model_path)
	if not model:
		Log.warn("prebaking", "FAIL (conversion): %s" % model_path)
		model_baked.emit(model_path, false, 0)
		return {"success": false, "error": "NIF conversion failed"}

	# Merge multi-mesh children into a single MeshInstance3D, then generate LODs
	# on the combined mesh. Produces truly 1 RS instance per object with a proper
	# embedded LOD chain. Character models are excluded (skeleton hierarchy matters).
	if not is_character_model:
		_merge_and_generate_lods(model, model_path)

	# Save meshes and scene
	var cache_key := model_path.to_lower().replace("/", "\\")
	var mesh_count := _save_model_to_cache(model, cache_key)

	model.queue_free()

	if mesh_count > 0:
		model_baked.emit(model_path, true, mesh_count)
		return {"success": true, "mesh_count": mesh_count}
	else:
		Log.warn("prebaking", "FAIL (no meshes): %s" % model_path)
		model_baked.emit(model_path, false, 0)
		return {"success": false, "error": "No meshes to save"}


## Merge all visible MeshInstance3D children in a prototype into a single
## MeshInstance3D with all surfaces combined, then run ImporterMesh.generate_lods()
## on the merged mesh. Produces one ArrayMesh with an embedded LOD chain.
##
## Single-mesh prototypes (1 child) skip the merge and just generate LODs directly.
## Hidden meshes (collision geometry) are left untouched.
func _merge_and_generate_lods(root: Node3D, model_path: String) -> void:
	var visible_meshes: Array[MeshInstance3D] = []
	_collect_visible_meshes(root, visible_meshes)

	if visible_meshes.is_empty():
		return

	# Single mesh — just generate LODs directly (no merge needed)
	if visible_meshes.size() == 1:
		var mi := visible_meshes[0]
		if mi.mesh is ArrayMesh and StreamingPolicyScript.should_generate_lods(model_path):
			_generate_lod_on_mesh(mi, model_path)
		return

	# Multiple meshes — merge into one, then LOD the result
	var merged_mesh := ArrayMesh.new()

	for mi in visible_meshes:
		var child_mesh: Mesh = mi.mesh
		if not child_mesh:
			continue

		# Transform relative to root
		var local_xform := Transform3D.IDENTITY
		var current: Node3D = mi
		while current != null and current != root:
			local_xform = current.transform * local_xform
			var parent_node := current.get_parent()
			current = parent_node as Node3D if parent_node else null

		var is_identity := local_xform.is_equal_approx(Transform3D.IDENTITY)

		# Material from override or per-surface override or mesh surface
		var child_override: Material = mi.material_override

		for si in range(child_mesh.get_surface_count()):
			var arrays := child_mesh.surface_get_arrays(si)
			if arrays.is_empty():
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if verts == null or verts.is_empty():
				continue

			# Transform into root space
			if not is_identity:
				var xformed_verts := PackedVector3Array()
				xformed_verts.resize(verts.size())
				for vi in range(verts.size()):
					xformed_verts[vi] = local_xform * verts[vi]
				arrays[Mesh.ARRAY_VERTEX] = xformed_verts

				var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
				if normals != null and normals is PackedVector3Array and not normals.is_empty():
					var normal_basis := local_xform.basis.inverse().transposed()
					var xformed_normals := PackedVector3Array()
					xformed_normals.resize(normals.size())
					for ni in range(normals.size()):
						xformed_normals[ni] = (normal_basis * normals[ni]).normalized()
					arrays[Mesh.ARRAY_NORMAL] = xformed_normals

				# TODO: tangent arrays (ARRAY_TANGENT) are not transformed here.
				# Vanilla Morrowind NIFs lack tangents so this is moot, but modded
				# NIFs with tangent data would have broken normal mapping on rotated
				# children. Transform tangents by basis (w component = handedness, preserve).

			# Ensure index buffer exists (meshoptimizer requires it)
			var indices: Variant = arrays[Mesh.ARRAY_INDEX]
			if indices == null or (indices is PackedInt32Array and indices.is_empty()):
				var vert_count: int = verts.size()
				var identity_indices := PackedInt32Array()
				identity_indices.resize(vert_count)
				for vi in range(vert_count):
					identity_indices[vi] = vi
				arrays[Mesh.ARRAY_INDEX] = identity_indices

			merged_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

			# Resolve material
			var mat: Material = child_override
			if not mat:
				mat = mi.get_surface_override_material(si)
			if not mat:
				mat = child_mesh.surface_get_material(si)
			if mat:
				merged_mesh.surface_set_material(merged_mesh.get_surface_count() - 1, mat)

	if merged_mesh.get_surface_count() == 0:
		return

	# Remove old mesh children, replace with single merged MeshInstance3D
	for mi in visible_meshes:
		mi.get_parent().remove_child(mi)
		mi.queue_free()

	var merged_mi := MeshInstance3D.new()
	merged_mi.name = "MergedMesh"
	merged_mi.mesh = merged_mesh
	root.add_child(merged_mi)

	# Generate LODs on the merged mesh
	if StreamingPolicyScript.should_generate_lods(model_path):
		_generate_lod_on_mesh(merged_mi, model_path)


## Generate an embedded LOD chain on a MeshInstance3D using ImporterMesh.
## Generate an embedded LOD chain on a MeshInstance3D using ImporterMesh.
## TODO: does not set visibility_range on the MeshInstance3D. Not a runtime bug
## because _create_rs_instance overrides visibility_range at instantiation time,
## but the baked .res lacks it — future-fragile if anyone reads it from cache
## without the RS override. Add visibility_range here for safety.
func _generate_lod_on_mesh(mesh_instance: MeshInstance3D, model_path: String) -> void:
	var original_mesh := mesh_instance.mesh as ArrayMesh
	if not original_mesh or original_mesh.get_surface_count() == 0:
		return

	var importer := ImporterMesh.new()
	for si in range(original_mesh.get_surface_count()):
		var arrays := original_mesh.surface_get_arrays(si)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts == null or verts.is_empty():
			continue

		# Ensure index buffer
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices == null or (indices is PackedInt32Array and indices.is_empty()):
			var vert_count: int = verts.size()
			var identity_indices := PackedInt32Array()
			identity_indices.resize(vert_count)
			for vi in range(vert_count):
				identity_indices[vi] = vi
			arrays[Mesh.ARRAY_INDEX] = identity_indices

		var mat := original_mesh.surface_get_material(si)
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, mat)

	if importer.get_surface_count() == 0:
		return

	importer.generate_lods(60.0, 25.0, [])
	var lod_mesh: ArrayMesh = importer.get_mesh()
	if lod_mesh:
		lod_mesh.set_meta("has_lod_chain", true)
		mesh_instance.mesh = lod_mesh


## Collect all visible MeshInstance3D nodes recursively.
func _collect_visible_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.visible and mi.mesh:
			result.append(mi)
	for child in node.get_children():
		_collect_visible_meshes(child, result)


## Collect all unique model paths from ESM records
func _collect_unique_models() -> Array[String]:
	var models: Array[String] = []
	var seen: Dictionary = {}

	# Ensure all typed dicts are populated (on-demand records need eager load for prebaking)
	ESMManager.ensure_typed_dicts_populated()

	# Scan all record types that have models
	var record_sources := [
		ESMManager.statics,
		ESMManager.activators,
		ESMManager.containers,
		ESMManager.doors,
		ESMManager.lights,
		ESMManager.misc_items,
		ESMManager.weapons,
		ESMManager.armors,
		ESMManager.clothing,
		ESMManager.books,
		ESMManager.ingredients,
		ESMManager.apparatus,
		ESMManager.lockpicks,
		ESMManager.probes,
		ESMManager.repair_items,
		ESMManager.potions,
	]

	for source: Dictionary in record_sources:
		if source == null:
			continue
		for key: String in source:
			var record: Variant = source[key]
			var model_path := _get_model_path_from_record(record)
			if not model_path.is_empty():
				var normalized := model_path.to_lower()
				if normalized not in seen:
					seen[normalized] = true
					models.append(model_path)

	# Add body part models (for NPC assembly)
	for key: String in ESMManager.body_parts:
		var body_part: BodyPartRecord = ESMManager.body_parts[key]
		if body_part and not body_part.model.is_empty():
			var normalized := body_part.model.to_lower()
			if normalized not in seen:
				seen[normalized] = true
				models.append(body_part.model)

	# Add base skeleton NIFs (critical for NPC loading)
	var skeleton_paths := [
		"meshes/base_anim.nif",
		"meshes/base_anim_female.nif",
		"meshes/base_animkna.nif",
	]
	for skel_path: String in skeleton_paths:
		var normalized: String = skel_path.to_lower()
		if normalized not in seen:
			seen[normalized] = true
			models.append(skel_path)

	for key: String in ESMManager.creatures:
		var creature: Variant = ESMManager.creatures[key]
		var model_path := _get_model_path_from_record(creature)
		if not model_path.is_empty():
			var normalized := model_path.to_lower()
			if normalized not in seen:
				seen[normalized] = true
				models.append(model_path)

	# Sort for consistent ordering
	models.sort()
	return models


## Extract model path from a record
func _get_model_path_from_record(record: Variant) -> String:
	if record == null:
		return ""
	if "model" in record and record.model is String:
		return record.model
	if "mesh" in record and record.mesh is String:
		return record.mesh
	return ""


## Load NIF from BSA
func _load_nif(model_path: String) -> PackedByteArray:
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes/" + model_path

	full_path = full_path.replace("\\", "/")

	if BSAManager.has_file(full_path):
		return BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		return BSAManager.extract_file(model_path)

	return PackedByteArray()


## Check if a model is already cached
func _model_cached(model_path: String) -> bool:
	var cache_key := model_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var scene_path := output_dir.path_join(safe_name + ".res")
	return FileAccess.file_exists(scene_path)


## Save model to cache with embedded materials and textures
## LOD meshes are kept in the main scene file for native visibility_range system
func _save_model_to_cache(node: Node3D, cache_key: String) -> int:
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var base_path := output_dir.path_join(safe_name)

	# Prepare all resources for embedding (makes them local to scene)
	_prepare_resources_for_embedding(node)

	# Post-B-wide refactor: LODs are embedded inside the ArrayMesh via
	# surface_lod_indices. No sibling _LODn nodes. visibility_range is set by
	# nif_converter._apply_render_tier_visibility_range at bake time.
	var mesh_count := _count_meshes(node)
	if mesh_count == 0:
		return 0

	# Set owner on all children so PackedScene.pack() includes them
	_set_owner_recursive(node, node)

	# nif_converter already configured visibility_range (0-500m → impostor handoff).
	# The old LODConfigurator.configure_for_prebake walk is obsolete — it would
	# clobber our single-band range with the old per-sub-LOD cascade math.
	node.set_meta("visibility_prebaked", true)

	# Save scene (meshes, materials, textures all embedded)
	var scene_path := base_path + ".res"
	var packed_scene := PackedScene.new()
	var pack_result := packed_scene.pack(node)
	if pack_result != OK:
		push_warning("ModelPrebaker: Failed to pack scene for %s: %s" % [cache_key, error_string(pack_result)])
		return 0

	var save_result := ResourceSaver.save(packed_scene, scene_path)
	if save_result != OK:
		push_warning("ModelPrebaker: Failed to save scene for %s: %s" % [cache_key, error_string(save_result)])
		return 0

	return mesh_count


## Count meshes in node tree (includes LOD meshes now that we keep them)
func _count_meshes(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			count += 1
	for child in node.get_children():
		count += _count_meshes(child)
	return count


## Recursively set owner on all descendants for PackedScene.pack()
func _set_owner_recursive(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_set_owner_recursive(child, owner_node)


## Prepare all materials and textures to be embedded in the PackedScene
## This ensures they don't have external dependencies that break on load
func _prepare_resources_for_embedding(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D

		# Handle material override
		if mesh_inst.material_override:
			_make_material_local(mesh_inst.material_override)

		# Handle surface materials on the mesh itself
		if mesh_inst.mesh:
			for i in range(mesh_inst.mesh.get_surface_count()):
				var mat := mesh_inst.mesh.surface_get_material(i)
				if mat:
					_make_material_local(mat)

		# Handle surface override materials
		for i in range(mesh_inst.get_surface_override_material_count()):
			var mat := mesh_inst.get_surface_override_material(i)
			if mat:
				_make_material_local(mat)

	# Recurse into children
	for child in node.get_children():
		_prepare_resources_for_embedding(child)


## Make a material and its textures local for embedding in saved resources
func _make_material_local(mat: Material) -> void:
	if mat == null:
		return

	# Mark material as local (will be embedded when saved)
	mat.resource_local_to_scene = true
	mat.resource_path = ""  # Clear path so it embeds instead of references

	# Handle StandardMaterial3D textures
	if mat is StandardMaterial3D:
		var std_mat := mat as StandardMaterial3D
		_make_texture_local(std_mat.albedo_texture)
		_make_texture_local(std_mat.normal_texture)
		_make_texture_local(std_mat.roughness_texture)
		_make_texture_local(std_mat.metallic_texture)
		_make_texture_local(std_mat.emission_texture)
		_make_texture_local(std_mat.ao_texture)
		_make_texture_local(std_mat.detail_albedo)
		_make_texture_local(std_mat.detail_normal)


## Make a texture local for embedding in saved resources
func _make_texture_local(tex: Texture2D) -> void:
	if tex == null:
		return

	tex.resource_local_to_scene = true
	tex.resource_path = ""  # Clear path so it embeds instead of references


## Get statistics
func get_stats() -> Dictionary:
	return {
		"total_baked": _total_baked,
		"total_failed": _total_failed,
		"total_skipped": _total_skipped,
		"failed_models": _failed_models.duplicate(),
	}


# =============================================================================
# ANIMATION PREBAKING
# =============================================================================

## Bake all character animation files (.kf) to Godot AnimationLibrary resources
## This eliminates the 10-12 second KF parsing time at runtime
func bake_all_animations() -> Dictionary:
	if animation_output_dir.is_empty():
		animation_output_dir = SettingsManager.get_models_path()

	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("ModelPrebaker: Failed to create cache directories for animations")
		return {"success": 0, "failed": 0, "skipped": 0}

	var anim_paths := _collect_animation_files()
	Log.info("prebaking", "Found %d animation files to bake" % anim_paths.size())

	var success := 0
	var failed := 0
	var skipped := 0

	for i in range(anim_paths.size()):
		var anim_path: String = anim_paths[i]
		progress.emit(i + 1, anim_paths.size(), anim_path.get_file())

		# Check if already cached
		if skip_existing and _animation_cached(anim_path):
			skipped += 1
			continue

		var result := bake_animation(anim_path)
		if result.success:
			success += 1
		else:
			failed += 1

	Log.info("prebaking", "Animations complete - %d baked, %d skipped, %d failed" % [
		success, skipped, failed])

	return {
		"total": anim_paths.size(),
		"success": success,
		"failed": failed,
		"skipped": skipped,
	}


## Bake a single animation file
func bake_animation(anim_path: String) -> Dictionary:
	# Load KF file from BSA
	var kf_data := _load_nif(anim_path)  # KF files are in same location as NIFs
	if kf_data.is_empty():
		animation_baked.emit(anim_path, false, 0)
		return {"success": false, "error": "KF not found in BSA"}

	# Parse animations
	var kf_loader := NIFKFLoader.new()
	var animations: Dictionary = kf_loader.load_kf_buffer(kf_data, null)

	if animations.is_empty():
		animation_baked.emit(anim_path, false, 0)
		return {"success": false, "error": "No animations parsed from KF"}

	# Create AnimationLibrary and add all animations
	var lib := AnimationLibrary.new()
	for anim_name: String in animations:
		var anim: Animation = animations[anim_name]
		lib.add_animation(anim_name, anim)

	# Save to cache
	var cache_key := anim_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var lib_path := animation_output_dir.path_join(safe_name + ".tres")

	var save_result := ResourceSaver.save(lib, lib_path)
	if save_result != OK:
		animation_baked.emit(anim_path, false, 0)
		return {"success": false, "error": "Failed to save AnimationLibrary"}

	animation_baked.emit(anim_path, true, animations.size())
	return {"success": true, "anim_count": animations.size()}


## Collect all animation (.kf) files to prebake
func _collect_animation_files() -> Array[String]:
	var anim_paths: Array[String] = []

	# Character animation files
	anim_paths.append("meshes/xbase_anim.kf")
	anim_paths.append("meshes/xbase_anim_female.kf")
	anim_paths.append("meshes/xbase_animkna.kf")

	# Creature animation files (derived from creature models)
	var seen: Dictionary = {}
	for key: String in ESMManager.creatures:
		var creature: CreatureRecord = ESMManager.creatures[key]
		if creature and not creature.model.is_empty():
			# Creature animations are <model_base>.kf
			var base_path := creature.model.get_base_dir() + "/" + creature.model.get_file().get_basename()
			var kf_path := "meshes/" + base_path + ".kf"
			var normalized := kf_path.to_lower()
			if normalized not in seen:
				# Check if file actually exists in BSA
				if BSAManager.has_file(kf_path) or BSAManager.has_file(normalized):
					seen[normalized] = true
					anim_paths.append(kf_path)

	return anim_paths


## Check if an animation is already cached
func _animation_cached(anim_path: String) -> bool:
	var cache_key := anim_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var lib_path := animation_output_dir.path_join(safe_name + ".tres")
	return FileAccess.file_exists(lib_path)


## Load a cached AnimationLibrary (for use by CharacterFactoryV2)
static func load_cached_animations(anim_path: String) -> AnimationLibrary:
	var cache_dir: String = SettingsManager.get_models_path()
	var cache_key := anim_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var lib_path := cache_dir.path_join(safe_name + ".tres")

	if not FileAccess.file_exists(lib_path):
		return null

	return ResourceLoader.load(lib_path, "AnimationLibrary") as AnimationLibrary


# =============================================================================
# HLOD — CELL-LEVEL GEOMETRY MERGE
# =============================================================================
# Merges all static geometry per exterior cell into a single ArrayMesh.
# Runtime loads ONE RS instance per cell instead of ~125 individual ones.
# Based on OpenMW's "object paging" (objectpaging.cpp, FLATTEN_STATIC_TRANSFORMS + MERGE_GEOMETRY).
# =============================================================================

const CS := preload("res://src/core/coordinate_system.gd")
const DU := preload("res://src/core/world/distance_utils.gd")

signal hlod_progress(current: int, total: int, cell_name: String)
signal hlod_cell_baked(grid: Vector2i, success: bool, surface_count: int)
signal hlod_batch_complete(total: int, success: int, failed: int, skipped: int)

var _hlod_baked: int = 0
var _hlod_failed: int = 0
var _hlod_skipped: int = 0


## Get the HLOD cache directory (separate from individual model cache)
func _get_hlod_dir() -> String:
	var base: String = SettingsManager.get_cache_base_path()
	return base.path_join("hlod")


## Bake HLOD merged meshes for all exterior cells.
## Each cell's static geometry is merged into a single ArrayMesh with LOD chain.
func bake_all_hlods() -> Dictionary:
	if initialize() != OK:
		return {"success": 0, "failed": 0, "skipped": 0}

	_hlod_baked = 0
	_hlod_failed = 0
	_hlod_skipped = 0

	var hlod_dir := _get_hlod_dir()
	DirAccess.make_dir_recursive_absolute(hlod_dir)

	# Collect all exterior cells
	var cells: Array[Vector2i] = []
	for key: String in ESMManager.exterior_cells:
		var parts := key.split(",")
		if parts.size() == 2:
			cells.append(Vector2i(int(parts[0]), int(parts[1])))

	Log.info("prebaking", "HLOD: baking %d exterior cells" % cells.size())

	for i in range(cells.size()):
		var grid := cells[i]
		hlod_progress.emit(i + 1, cells.size(), "cell_%d_%d" % [grid.x, grid.y])

		if _hlod_cached(grid, hlod_dir):
			_hlod_skipped += 1
			continue

		var result := bake_cell_hlod(grid, hlod_dir)
		if result.success:
			_hlod_baked += 1
		else:
			_hlod_failed += 1

		# Yield every 5 cells to prevent UI freeze
		if i % 5 == 0:
			var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
			if main_loop:
				await main_loop.process_frame

	hlod_batch_complete.emit(cells.size(), _hlod_baked, _hlod_failed, _hlod_skipped)
	Log.info("prebaking", "HLOD complete: %d baked, %d skipped, %d failed (of %d cells)" % [
		_hlod_baked, _hlod_skipped, _hlod_failed, cells.size()])

	return {"total": cells.size(), "success": _hlod_baked, "failed": _hlod_failed, "skipped": _hlod_skipped}


## Bake HLOD for a single exterior cell.
## Merges all static geometry into one ArrayMesh with LOD chain.
func bake_cell_hlod(grid: Vector2i, hlod_dir: String = "") -> Dictionary:
	if hlod_dir.is_empty():
		hlod_dir = _get_hlod_dir()

	var cell_record: CellRecord = ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		return {"success": false, "error": "Cell not found"}

	var cell_origin := DU.cell_to_world_origin(grid)
	var models_dir := SettingsManager.get_models_path()
	var merged_mesh := ArrayMesh.new()
	var surface_count := 0
	var ref_count := 0

	# Material dedup: hash -> {material: Material, arrays_list: Array[Array]}
	# We group surfaces by material to minimize surface count in the merged mesh.
	var material_groups: Dictionary = {}

	for ref: CellReference in cell_record.references:
		if ref.is_deleted:
			continue

		# Look up base record to get model path and type
		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# HLOD merge: include all mid-worthy types (STAT, DOOR, CONT, ACTI, flora).
		# Exclude: NPC/creature (animated), small items (invisible at 300m+).
		# Minor visual inconsistency at extreme distance for stateful objects
		# (e.g. opened door shows closed in HLOD) — acceptable per OpenMW precedent.
		var model_path := _get_model_path_from_record(base_record)
		if model_path.is_empty():
			continue
		if not StreamingPolicyScript.is_mid_worthy(type_name, model_path):
			continue

		# Load prebaked prototype from cache
		var prototype := _load_cached_prototype(model_path, models_dir)
		if not prototype:
			continue

		# Compute world transform (then subtract cell origin for cell-local space)
		var pos := CS.vector_to_godot(ref.position) - cell_origin
		var scale := CS.scale_to_godot(ref.scale)
		var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
		basis = basis.scaled(scale)
		var ref_transform := Transform3D(basis, pos)

		# Extract mesh data from prototype
		var mesh_instances: Array[MeshInstance3D] = []
		_collect_visible_meshes(prototype, mesh_instances)

		for mi in mesh_instances:
			if not mi.mesh:
				continue

			# Compute full transform: ref transform * child local transform
			var child_local := Transform3D.IDENTITY
			var current: Node3D = mi
			while current != null and current != prototype:
				child_local = current.transform * child_local
				var parent_node := current.get_parent()
				current = parent_node as Node3D if parent_node else null

			var full_xform := ref_transform * child_local
			var is_identity := full_xform.is_equal_approx(Transform3D.IDENTITY)

			for si in range(mi.mesh.get_surface_count()):
				var arrays := mi.mesh.surface_get_arrays(si)
				if arrays.is_empty():
					continue
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				if verts == null or verts.is_empty():
					continue

				# Transform vertices into cell-local space
				if not is_identity:
					var xformed_verts := PackedVector3Array()
					xformed_verts.resize(verts.size())
					for vi in range(verts.size()):
						xformed_verts[vi] = full_xform * verts[vi]
					arrays[Mesh.ARRAY_VERTEX] = xformed_verts

					var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
					if normals != null and normals is PackedVector3Array and not normals.is_empty():
						var normal_basis := full_xform.basis.inverse().transposed()
						var xformed_normals := PackedVector3Array()
						xformed_normals.resize(normals.size())
						for ni in range(normals.size()):
							xformed_normals[ni] = (normal_basis * normals[ni]).normalized()
						arrays[Mesh.ARRAY_NORMAL] = xformed_normals

				# Ensure index buffer
				var indices: Variant = arrays[Mesh.ARRAY_INDEX]
				if indices == null or (indices is PackedInt32Array and indices.is_empty()):
					var vert_count: int = verts.size()
					var identity_indices := PackedInt32Array()
					identity_indices.resize(vert_count)
					for vi in range(vert_count):
						identity_indices[vi] = vi
					arrays[Mesh.ARRAY_INDEX] = identity_indices

				# Resolve material
				var mat: Material = mi.material_override
				if not mat:
					mat = mi.get_surface_override_material(si)
				if not mat:
					mat = mi.mesh.surface_get_material(si)

				# Group by material for merging (reduces surface count)
				var mat_hash := mat.get_instance_id() if mat else 0
				if mat_hash not in material_groups:
					material_groups[mat_hash] = {"material": mat, "arrays_list": []}
				material_groups[mat_hash]["arrays_list"].append(arrays)

		prototype.free()  # Immediate free — prototype fully consumed, no deferred refs
		ref_count += 1

	# Build merged ArrayMesh from material groups
	for mat_hash: int in material_groups:
		var group: Dictionary = material_groups[mat_hash]
		var arrays_list: Array = group["arrays_list"]
		var mat: Material = group["material"]

		if arrays_list.size() == 1:
			# Single surface — add directly
			merged_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays_list[0])
		else:
			# Multiple surfaces with same material — concatenate vertex/index buffers
			var combined := _concatenate_surface_arrays(arrays_list)
			if not combined.is_empty():
				merged_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, combined)

		if mat:
			merged_mesh.surface_set_material(merged_mesh.get_surface_count() - 1, mat)
		surface_count += 1

	if merged_mesh.get_surface_count() == 0:
		hlod_cell_baked.emit(grid, false, 0)
		return {"success": false, "error": "No geometry to merge"}

	# Generate LOD chain on merged mesh (aggressive simplification for distance viewing)
	var lod_mesh := _generate_hlod_lods(merged_mesh)
	if lod_mesh:
		merged_mesh = lod_mesh

	merged_mesh.set_meta("has_lod_chain", true)
	merged_mesh.set_meta("hlod_cell", "%d,%d" % [grid.x, grid.y])
	merged_mesh.set_meta("hlod_ref_count", ref_count)

	# Save to HLOD cache
	var file_path := hlod_dir.path_join("cell_%d_%d.res" % [grid.x, grid.y])
	var err := ResourceSaver.save(merged_mesh, file_path)
	if err != OK:
		Log.warn("prebaking", "HLOD: failed to save cell_%d_%d: %s" % [grid.x, grid.y, error_string(err)])
		hlod_cell_baked.emit(grid, false, 0)
		return {"success": false, "error": error_string(err)}

	hlod_cell_baked.emit(grid, true, surface_count)
	return {"success": true, "surfaces": surface_count, "refs": ref_count}


## Generate LOD chain on the merged HLOD mesh via ImporterMesh.
## Uses aggressive settings since this mesh is only visible at 300m+.
func _generate_hlod_lods(mesh: ArrayMesh) -> ArrayMesh:
	if mesh.get_surface_count() == 0:
		return null

	var importer := ImporterMesh.new()
	for si in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(si)
		if arrays.is_empty():
			continue
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if verts == null or (verts is PackedVector3Array and verts.is_empty()):
			continue
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices == null or (indices is PackedInt32Array and indices.is_empty()):
			var vert_count: int = verts.size()
			var identity_indices := PackedInt32Array()
			identity_indices.resize(vert_count)
			for vi in range(vert_count):
				identity_indices[vi] = vi
			arrays[Mesh.ARRAY_INDEX] = identity_indices

		var mat: Material = mesh.surface_get_material(si)
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, mat, "", 0)

	# LOD for distance viewing: normal_merge_angle=60 deg (preserves silhouettes),
	# screen_coverage=25px (aggressive reduction OK at 300m+)
	importer.generate_lods(60.0, 25.0, [])
	var result: ArrayMesh = importer.get_mesh()
	if result and result.get_surface_count() > 0:
		result.set_meta("has_lod_chain", true)
		return result
	return null


## Concatenate multiple surface arrays with the same material into one surface.
## Offsets index buffers to account for merged vertex base.
func _concatenate_surface_arrays(arrays_list: Array) -> Array:
	if arrays_list.is_empty():
		return []

	var all_verts := PackedVector3Array()
	var all_normals := PackedVector3Array()
	var all_tangents := PackedFloat32Array()
	var all_colors := PackedColorArray()
	var all_uvs := PackedVector2Array()
	var all_uvs2 := PackedVector2Array()
	var all_indices := PackedInt32Array()
	var has_normals := false
	var has_tangents := false
	var has_colors := false
	var has_uvs := false
	var has_uvs2 := false

	# Probe first surface for attribute presence
	var first: Array = arrays_list[0]
	if first.size() > Mesh.ARRAY_NORMAL and first[Mesh.ARRAY_NORMAL] is PackedVector3Array:
		has_normals = true
	if first.size() > Mesh.ARRAY_TANGENT and first[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
		has_tangents = true
	if first.size() > Mesh.ARRAY_COLOR and first[Mesh.ARRAY_COLOR] is PackedColorArray:
		has_colors = true
	if first.size() > Mesh.ARRAY_TEX_UV and first[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
		has_uvs = true
	if first.size() > Mesh.ARRAY_TEX_UV2 and first[Mesh.ARRAY_TEX_UV2] is PackedVector2Array:
		has_uvs2 = true

	for arrays: Array in arrays_list:
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var base_vertex := all_verts.size()
		all_verts.append_array(verts)

		if has_normals and arrays.size() > Mesh.ARRAY_NORMAL:
			var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
			if normals is PackedVector3Array:
				all_normals.append_array(normals)

		if has_tangents and arrays.size() > Mesh.ARRAY_TANGENT:
			var tangents: Variant = arrays[Mesh.ARRAY_TANGENT]
			if tangents is PackedFloat32Array:
				all_tangents.append_array(tangents)

		if has_colors and arrays.size() > Mesh.ARRAY_COLOR:
			var colors: Variant = arrays[Mesh.ARRAY_COLOR]
			if colors is PackedColorArray:
				all_colors.append_array(colors)

		if has_uvs and arrays.size() > Mesh.ARRAY_TEX_UV:
			var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
			if uvs is PackedVector2Array:
				all_uvs.append_array(uvs)

		if has_uvs2 and arrays.size() > Mesh.ARRAY_TEX_UV2:
			var uvs2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
			if uvs2 is PackedVector2Array:
				all_uvs2.append_array(uvs2)

		# Offset indices by base vertex
		var indices: Variant = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null
		if indices is PackedInt32Array and not indices.is_empty():
			for idx: int in indices:
				all_indices.append(idx + base_vertex)
		else:
			# No index buffer — generate sequential
			for vi in range(verts.size()):
				all_indices.append(vi + base_vertex)

	# Build output array
	var result := []
	result.resize(Mesh.ARRAY_MAX)
	result[Mesh.ARRAY_VERTEX] = all_verts
	if has_normals and not all_normals.is_empty():
		result[Mesh.ARRAY_NORMAL] = all_normals
	if has_tangents and not all_tangents.is_empty():
		result[Mesh.ARRAY_TANGENT] = all_tangents
	if has_colors and not all_colors.is_empty():
		result[Mesh.ARRAY_COLOR] = all_colors
	if has_uvs and not all_uvs.is_empty():
		result[Mesh.ARRAY_TEX_UV] = all_uvs
	if has_uvs2 and not all_uvs2.is_empty():
		result[Mesh.ARRAY_TEX_UV2] = all_uvs2
	result[Mesh.ARRAY_INDEX] = all_indices
	return result


## Load a prebaked prototype from the individual model cache.
## Returns the instantiated Node3D, or null if not in cache.
func _load_cached_prototype(model_path: String, models_dir: String) -> Node3D:
	var cache_key := model_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var scene_path := models_dir.path_join(safe_name + ".res")

	if not FileAccess.file_exists(scene_path):
		return null

	var packed_scene := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	if not packed_scene:
		return null

	return packed_scene.instantiate() as Node3D


## Check if an HLOD cell mesh is already cached
func _hlod_cached(grid: Vector2i, hlod_dir: String) -> bool:
	var file_path := hlod_dir.path_join("cell_%d_%d.res" % [grid.x, grid.y])
	return FileAccess.file_exists(file_path)


## Static helper: load a cached HLOD cell mesh (for runtime use)
static func load_hlod_mesh(grid: Vector2i) -> ArrayMesh:
	var cache_dir: String = SettingsManager.get_cache_base_path().path_join("hlod")
	var file_path: String = cache_dir.path_join("cell_%d_%d.res" % [grid.x, grid.y])
	if not FileAccess.file_exists(file_path):
		return null
	return ResourceLoader.load(file_path, "ArrayMesh") as ArrayMesh
