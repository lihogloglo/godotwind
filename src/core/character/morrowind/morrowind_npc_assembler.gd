## Morrowind NPC Assembler - High-level NPC assembly with native skeleton
## Assembles Morrowind body parts onto the native Morrowind skeleton.
##
## KEY DESIGN:
## - Uses native Morrowind skeleton (from xbase_anim.nif), NOT Mixamo
## - Body parts attach directly — bone names and skinning data match
## - No skin rebinding needed (bones are native Bip01)
## - Bone renaming to profile names happens later in CharacterFactoryV2
class_name MorrowindNPCAssembler
extends RefCounted

# NIF conversion for loading skeleton from xbase_anim.nif
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const MeshExtractor := preload("res://src/core/character/mixamo/mesh_extractor.gd")

# Game layer components
const BodyPartSlots := preload("res://src/core/character/morrowind/morrowind_body_part_slots.gd")


## Cached skeleton templates: { "type" -> Skeleton3D }
static var _skeleton_cache: Dictionary = {}

## Cached body part mesh data: { "model_path" -> Array[MeshExtractor.MeshData] }
static var _body_part_cache: Dictionary = {}

## Debug mode
static var debug_mode: bool = false


## Body part data container (simplified, holds extracted mesh data)
class BodyPartData:
	var meshes: Array  # Array of MeshExtractor.MeshData
	var model_path: String

	static func from_meshes(p_meshes: Array, path: String) -> BodyPartData:
		var data := BodyPartData.new()
		data.meshes = p_meshes
		data.model_path = path
		return data


## Assemble a complete NPC from records using native Morrowind skeleton
## Returns a Node3D with Skeleton3D and all body parts attached
static func assemble(npc_record, race_record) -> Node3D:
	var root := Node3D.new()
	root.name = npc_record.name if npc_record.name else npc_record.id if "id" in npc_record else "NPC"

	# Determine character type
	var is_female: bool = npc_record.is_female() if npc_record.has_method("is_female") else false
	var is_beast: bool = race_record.is_beast() if race_record.has_method("is_beast") else false

	# Create native Morrowind skeleton (from xbase_anim.nif)
	var skeleton := _get_morrowind_skeleton(is_beast)
	if skeleton == null:
		push_error("MorrowindNPCAssembler: Failed to create Morrowind skeleton")
		return root

	skeleton.name = "Skeleton3D"
	root.add_child(skeleton)

	# Create AnimationPlayer for the skeleton
	var anim_player := AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"
	skeleton.add_child(anim_player)

	# Collect body parts for this NPC
	var body_parts := _collect_body_parts(npc_record, race_record, is_female)

	if debug_mode:
		Log.info("character", "Collected %d body parts for %s" % [body_parts.size(), root.name])

	# Attach each body part directly (no rebinding — bones match)
	for slot in body_parts:
		var part_data: BodyPartData = body_parts[slot]
		_attach_body_part_native(skeleton, slot, part_data)

	if debug_mode:
		Log.info("character", "Assembled NPC with %d meshes on native skeleton (%d bones)" % [
			_count_mesh_instances(skeleton), skeleton.get_bone_count()])

	return root


# =============================================================================
# SKELETON CREATION
# =============================================================================

## Get or create a native Morrowind skeleton
## Humanoid (male & female share same skeleton) or beast (Khajiit/Argonian)
static func _get_morrowind_skeleton(is_beast: bool) -> Skeleton3D:
	var key := "beast" if is_beast else "humanoid"

	if key in _skeleton_cache:
		return _duplicate_skeleton(_skeleton_cache[key])

	# Load from xbase_anim.nif (humanoid) or xbase_animkna.nif (beast)
	var nif_path := "meshes\\xbase_animkna.nif" if is_beast else "meshes\\xbase_anim.nif"
	var skeleton := _load_skeleton_from_nif(nif_path)

	if skeleton:
		_skeleton_cache[key] = skeleton
		if debug_mode:
			Log.info("character", "Cached %s skeleton: %d bones from %s" % [
				key, skeleton.get_bone_count(), nif_path])
		return _duplicate_skeleton(skeleton)

	return null


## Load a Skeleton3D from a NIF file (xbase_anim.nif hierarchy)
static func _load_skeleton_from_nif(nif_path: String) -> Skeleton3D:
	var bsa_mgr := _get_bsa_manager()
	if not bsa_mgr:
		push_error("MorrowindNPCAssembler: BSAManager not available")
		return null

	var data: PackedByteArray = bsa_mgr.extract_file(nif_path)
	if data.is_empty():
		push_error("MorrowindNPCAssembler: Cannot load skeleton NIF: %s" % nif_path)
		return null

	# Use NIFConverter to parse the NIF and build skeleton from bone hierarchy
	var converter := NIFConverter.new()
	converter.load_textures = false
	converter.load_animations = false
	converter.load_collision = false

	# convert_buffer initializes the reader and skeleton builder
	var scene := converter.convert_buffer(data, nif_path)

	# Build skeleton from the NiNode hierarchy (xbase_anim.nif is skeleton-only)
	var skeleton := converter.create_skeleton_from_hierarchy()

	# Clean up the temporary scene
	if scene:
		scene.queue_free()

	if not skeleton:
		push_error("MorrowindNPCAssembler: No skeleton built from: %s" % nif_path)

	return skeleton


## Duplicate a skeleton (for instancing from cache)
static func _duplicate_skeleton(source: Skeleton3D) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = source.name

	for i in source.get_bone_count():
		skeleton.add_bone(source.get_bone_name(i))

	for i in source.get_bone_count():
		var parent_idx := source.get_bone_parent(i)
		if parent_idx >= 0:
			skeleton.set_bone_parent(i, parent_idx)
		skeleton.set_bone_rest(i, source.get_bone_rest(i))

	skeleton.reset_bone_poses()
	return skeleton


# =============================================================================
# BODY PART ATTACHMENT (NATIVE — NO REBINDING)
# =============================================================================

## Attach a body part directly to the native skeleton
static func _attach_body_part_native(skeleton: Skeleton3D, slot: int, part_data: BodyPartData) -> void:
	for mesh_data in part_data.meshes:
		var extracted: MeshExtractor.MeshData = mesh_data

		if extracted.is_skinned:
			_attach_skinned_mesh_native(skeleton, extracted, slot)
		else:
			_attach_static_mesh(skeleton, extracted, slot)


## Attach a skinned mesh directly to the native Morrowind skeleton
##
## No rebinding needed — mesh bone names already match the skeleton.
## We create a Skin resource that maps mesh-local bone indices to skeleton
## bone indices, using the original Morrowind inverse bind matrices.
static func _attach_skinned_mesh_native(skeleton: Skeleton3D, mesh_data: MeshExtractor.MeshData, slot: int) -> void:
	# Create the ArrayMesh with skinning data
	var array_mesh := MeshExtractor.create_array_mesh(mesh_data)

	# Create Skin mapping mesh bone indices → skeleton bone indices
	var skin := _create_native_skin(mesh_data, skeleton)
	if not skin:
		push_warning("MorrowindNPCAssembler: Failed to create skin for slot %s" % BodyPartSlots.slot_name(slot))
		return

	# Create MeshInstance3D
	var instance := MeshInstance3D.new()
	instance.name = "BodyPart_%s" % BodyPartSlots.slot_name(slot)
	instance.mesh = array_mesh
	instance.skin = skin
	instance.skeleton = NodePath("..")  # Parent is skeleton

	# Apply material if texture available
	if not mesh_data.texture_path.is_empty():
		var material := _create_material(mesh_data.texture_path, mesh_data.material_properties)
		if material:
			array_mesh.surface_set_material(0, material)

	skeleton.add_child(instance)


## Create a Skin resource for native skeleton attachment
##
## Maps each mesh bone (by name) to the matching skeleton bone index.
## Uses NIF's own inverse bind matrices composed with skin_transform for accuracy.
## Falls back to skeleton rest poses when NIF data is unavailable.
static func _create_native_skin(mesh_data: MeshExtractor.MeshData, skeleton: Skeleton3D) -> Skin:
	if mesh_data.bone_names.is_empty():
		return null

	var skin := Skin.new()
	var unmapped := PackedStringArray()
	var has_nif_binds: bool = mesh_data.inv_bind_poses.size() == mesh_data.bone_names.size()

	for i in mesh_data.bone_names.size():
		var bone_name: String = mesh_data.bone_names[i]

		var bone_idx := _find_bone_ci(skeleton, bone_name)

		if bone_idx < 0:
			unmapped.append(bone_name)
			bone_idx = 0  # fallback to root bone

		var inv_bind: Transform3D
		if has_nif_binds:
			# Use NIF's per-bone inverse bind composed with skin_transform
			# full_inv_bind = per_bone_inv_bind * skin_transform
			# skin_transform converts mesh space → skeleton root space
			inv_bind = mesh_data.inv_bind_poses[i] * mesh_data.skin_transform
		else:
			# Fallback: compute from skeleton rest poses
			inv_bind = skeleton.get_bone_global_rest(bone_idx).affine_inverse()

		skin.add_bind(bone_idx, inv_bind)

	if debug_mode and not unmapped.is_empty():
		Log.debug("character", "Native skin unmapped bones: %s" % str(unmapped))

	return skin


## Attach a static (non-skinned) mesh
##
## Static body parts are rigid meshes in bone-local space. We attach via
## BoneAttachment3D using the slot-to-bone mapping (authoritative), with
## NIF parent bone name as fallback. Left-side slots are mirrored on X axis.
static func _attach_static_mesh(skeleton: Skeleton3D, mesh_data: MeshExtractor.MeshData, slot: int) -> void:
	var array_mesh := MeshExtractor.create_array_mesh(mesh_data)

	var instance := MeshInstance3D.new()
	instance.name = "Static_%s" % BodyPartSlots.slot_name(slot)
	instance.mesh = array_mesh

	var is_mirrored: bool = BodyPartSlots.is_left_side(slot)

	# Apply material
	if not mesh_data.texture_path.is_empty():
		var material := _create_material(mesh_data.texture_path, mesh_data.material_properties)
		if material:
			if is_mirrored:
				material.cull_mode = BaseMaterial3D.CULL_FRONT
			array_mesh.surface_set_material(0, material)

	# Left-side: create fallback material for cull flip if none was set
	if is_mirrored and array_mesh.surface_get_material(0) == null:
		var fallback_mat := StandardMaterial3D.new()
		fallback_mat.cull_mode = BaseMaterial3D.CULL_FRONT
		array_mesh.surface_set_material(0, fallback_mat)

	# PRIMARY: Use slot-to-bone mapping (authoritative for body parts)
	var bone_name := BodyPartSlots.get_bone(slot)
	var bone_idx := _find_bone_ci(skeleton, bone_name) if not bone_name.is_empty() else -1

	# FALLBACK: Try NIF parent bone name if slot lookup failed
	if bone_idx < 0 and not mesh_data.parent_bone_name.is_empty():
		bone_idx = _find_bone_ci(skeleton, mesh_data.parent_bone_name)

	if bone_idx >= 0:
		# Mesh vertices are in NIF geometry-local space (not bone-local).
		# BoneAttachment3D applies the bone's global pose, so we must undo
		# the bone's rest transform and apply node_transform to bring vertices
		# from geometry space → model space → bone-local space.
		# At rest: bone_global_rest * inv(bone_global_rest) * node_transform * v = node_transform * v
		instance.transform = skeleton.get_bone_global_rest(bone_idx).affine_inverse() * mesh_data.node_transform

		# Left-side mirroring: scale X by -1 (right-side mesh mirrored to left bone)
		if is_mirrored:
			instance.scale.x *= -1.0

		var attachment := BoneAttachment3D.new()
		attachment.name = "Attach_%s" % BodyPartSlots.slot_name(slot)
		attachment.bone_name = skeleton.get_bone_name(bone_idx)
		skeleton.add_child(attachment)
		attachment.add_child(instance)
	else:
		if debug_mode:
			Log.warn("character", "Static mesh slot %s: no bone found, using node_transform fallback" % BodyPartSlots.slot_name(slot))
		instance.transform = mesh_data.node_transform
		skeleton.add_child(instance)


# =============================================================================
# BODY PART COLLECTION
# =============================================================================

## Collect all body parts for an NPC
static func _collect_body_parts(npc_record, race_record, is_female: bool) -> Dictionary:
	var parts: Dictionary = {}

	var esm_mgr: Node = _get_esm_manager()
	if esm_mgr == null:
		push_warning("MorrowindNPCAssembler: ESMManager not available")
		return parts

	# Get race body parts from ESM
	if esm_mgr.has_method("get_body_parts_for_race"):
		var race_parts: Array = esm_mgr.get_body_parts_for_race(race_record.record_id, is_female)
		for part in race_parts:
			var slots := BodyPartSlots.part_type_to_slots(part.part_type)
			for slot in slots:
				var part_data := _load_body_part(part.model)
				if part_data:
					parts[slot] = part_data

	# Override with NPC-specific head/hair if set
	if npc_record.head_id and esm_mgr.has_method("get_body_part"):
		var head_part = esm_mgr.get_body_part(npc_record.head_id)
		if head_part:
			var head_data := _load_body_part(head_part.model)
			if head_data:
				parts[BodyPartSlots.Slot.HEAD] = head_data

	if npc_record.hair_id and esm_mgr.has_method("get_body_part"):
		var hair_part = esm_mgr.get_body_part(npc_record.hair_id)
		if hair_part:
			var hair_data := _load_body_part(hair_part.model)
			if hair_data:
				parts[BodyPartSlots.Slot.HAIR] = hair_data

	# Populate left-side slots by duplicating right-side non-skinned parts.
	# Non-skinned body parts only have right-side geometry in the NIF;
	# left-side is created by X-axis mirroring (handled in _attach_static_mesh).
	# Skinned parts (e.g. "skins" file) already contain both sides via bone weights.
	var right_slots: Array = parts.keys().duplicate()
	for right_slot: int in right_slots:
		var left_slot: int = BodyPartSlots.get_left_equivalent(right_slot)
		if left_slot != right_slot and left_slot not in parts:
			var part_data: BodyPartData = parts[right_slot]
			var has_skinned := false
			for mesh_data in part_data.meshes:
				var extracted: MeshExtractor.MeshData = mesh_data
				if extracted.is_skinned:
					has_skinned = true
					break
			if not has_skinned:
				parts[left_slot] = part_data

	return parts


# =============================================================================
# AUTOLOAD ACCESSORS
# =============================================================================

static func _get_esm_manager() -> Node:
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		return main_loop.root.get_node_or_null("/root/ESMManager")
	return null


static func _get_bsa_manager() -> Node:
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		return main_loop.root.get_node_or_null("/root/BSAManager")
	return null


# =============================================================================
# BODY PART LOADING
# =============================================================================

## Load a body part using MeshExtractor
static func _load_body_part(model_path: String) -> BodyPartData:
	if model_path.is_empty():
		return null

	var path := model_path.to_lower().replace("\\", "/")
	if not path.begins_with("meshes/"):
		path = "meshes/" + path

	# Check cache
	if path in _body_part_cache:
		return _body_part_cache[path]

	# Extract mesh data using MeshExtractor (handles BSA loading internally)
	var meshes := MeshExtractor.extract_from_bsa(path)

	if meshes.is_empty():
		push_warning("MorrowindNPCAssembler: No meshes extracted from: %s" % path)
		return null

	var part_data := BodyPartData.from_meshes(meshes, path)
	_body_part_cache[path] = part_data

	return part_data


# =============================================================================
# MATERIAL CREATION
# =============================================================================

static func _create_material(texture_path: String, properties: Dictionary) -> StandardMaterial3D:
	var path := texture_path.to_lower().replace("\\", "/")
	if not path.begins_with("textures/"):
		path = "textures/" + path

	if path.ends_with(".tga"):
		path = path.replace(".tga", ".dds")

	var texture: Texture2D = null

	var tex_loader_script: GDScript = load("res://src/core/texture/texture_loader.gd") as GDScript
	if tex_loader_script:
		var loader: RefCounted = tex_loader_script.new()
		if loader.has_method("load_texture"):
			texture = loader.call("load_texture", path)

	if not texture:
		return null

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	if not properties.is_empty():
		if "alpha" in properties and properties["alpha"] < 1.0:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	return mat


# =============================================================================
# UTILITIES
# =============================================================================

## Case-insensitive bone lookup
static func _find_bone_ci(skeleton: Skeleton3D, bone_name: String) -> int:
	var idx := skeleton.find_bone(bone_name)
	if idx >= 0:
		return idx
	var lower := bone_name.to_lower()
	for j in skeleton.get_bone_count():
		if skeleton.get_bone_name(j).to_lower() == lower:
			return j
	return -1


static func _count_mesh_instances(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		count += 1
	for child in node.get_children():
		count += _count_mesh_instances(child)
	return count


## Clear all caches (for memory management)
static func clear_caches() -> void:
	_skeleton_cache.clear()
	_body_part_cache.clear()


## Preload skeleton for a race/gender (call during loading screen)
static func preload_skeleton(_is_female: bool, is_beast: bool) -> void:
	_get_morrowind_skeleton(is_beast)


## Get cache statistics
static func get_cache_stats() -> Dictionary:
	return {
		"skeletons": _skeleton_cache.size(),
		"body_parts": _body_part_cache.size()
	}
