## ReferenceInstantiator - Converts ESM cell references into Node3D objects
##
## Handles instantiation of different reference types:
## - Static objects (furniture, architecture, clutter)
## - Lights (model + OmniLight3D)
## - Actors (NPCs and creatures)
## - Flora/rocks via StaticObjectRenderer for performance
##
## Part of Phase 2 refactoring: Separating instantiation logic from cell management
## Extracted from CellManager to enforce Single Responsibility Principle
class_name ReferenceInstantiator
extends RefCounted

# Dependencies
const CS := preload("res://src/core/coordinate_system.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const CharacterFactoryV2 := preload("res://src/core/animation/character_factory_v2.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")

# Preload crossfade shader for fade-in effect
const LOD_CROSSFADE_SHADER := preload("res://src/core/world/shaders/lod_crossfade.gdshader")

# Injected dependencies (set by CellManager)
var model_loader: RefCounted = null  # ModelLoader
var object_pool: RefCounted = null  # ObjectPool (optional)
var static_renderer: Node = null  # StaticObjectRenderer (optional)
var gpu_scene_db: RefCounted = null  # GPUSceneDatabase (optional)
var character_factory: CharacterFactoryV2 = null  # CharacterFactoryV2 for NPCs/creatures with new animation system

# Impostor candidates for determining significant objects
var _impostor_candidates: RefCounted = null

# Output data for non-Node3D instances (Phase 2)
var last_static_data: Dictionary = {}

# Configuration
var create_lights: bool = true
var load_npcs: bool = true
var load_creatures: bool = true
var use_object_pool: bool = true
var use_static_renderer: bool = true
var debug_lod: bool = false
var enable_fade_in: bool = true  # Smooth fade-in for newly instantiated objects
var fade_in_duration: float = 0.3  # Duration of fade-in animation in seconds (matches StreamingConfig.FADE_DURATION)

# NEAR-tier actor filtering — skip NPC/creature creation beyond this distance from camera
# 150m matches the NEAR tier boundary in distance_utils.gd
var max_actor_distance: float = 150.0
var camera_position: Vector3 = Vector3.ZERO  # Updated by streaming manager each frame

# Scene tree reference for tweens (must be set by parent, e.g., CellManager)
var scene_tree: SceneTree = null

# Fade material pool - pre-allocated ShaderMaterials to avoid per-object allocation
const FADE_POOL_SIZE := 200  # Matches StreamingConfig.MAX_CONCURRENT_FADES
var _fade_pool: Array[ShaderMaterial] = []  # Available materials
var _fade_pool_initialized: bool = false

# Statistics
var stats: Dictionary = {
	"objects_instantiated": 0,
	"objects_failed": 0,
	"objects_from_pool": 0,
	"lights_created": 0,
	"npcs_loaded": 0,
	"creatures_loaded": 0,
	"static_renderer_instances": 0,
	"significant_objects_registered": 0,  # Objects registered with per-object LOD
}

# Morrowind light radius to Godot light range conversion factor
const MW_LIGHT_SCALE: float = CS.SCALE_FACTOR  # 1/70 — converts MW radius to meters


## Instantiate a cell reference into a Node3D
## Returns null if the reference cannot be instantiated or uses StaticObjectRenderer
var _inst_call_count: int = 0
func instantiate_reference(ref: CellReference, cell_grid: Vector2i = Vector2i.ZERO) -> Node3D:
	_inst_call_count += 1

	# Use generic lookup to find the base record and its type
	var record_type: Array = [""]
	var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)

	if debug_lod and _inst_call_count <= 20:
		Log.debug("streaming", "[LOD-INST] #%d ref=%s, type=%s, found=%s, cell=%s" % [
			_inst_call_count, ref.ref_id, record_type[0] if record_type.size() > 0 else "?",
			base_record != null, cell_grid
		])

	if not base_record:
		# Not an error - some refs are for types we don't handle yet
		return null

	var type_name: String = record_type[0] if record_type.size() > 0 else ""

	# Handle different record types
	match type_name:
		"light":
			return _instantiate_light(ref, base_record as LightRecord)
		"npc":
			if not load_npcs:
				return null
			return _instantiate_actor(ref, base_record as NPCRecord, "npc")
		"creature":
			if not load_creatures:
				return null
			return _instantiate_actor(ref, base_record as CreatureRecord, "creature")
		"leveled_creature":
			if not load_creatures:
				return null
			# Resolve leveled creature to an actual creature
			var resolved := _resolve_leveled_creature(base_record as LeveledCreatureRecord)
			if resolved:
				return _instantiate_actor(ref, resolved, "creature")
			return null
		"leveled_item":
			# Leveled items need to be resolved at runtime
			# Could spawn random items here if needed
			return null
		_:
			# Standard model-based object
			return _instantiate_model_object(ref, base_record, cell_grid, type_name)


## Check if a model is considered "significant" for per-object LOD
## Significant objects include buildings, towers, large rocks, landmarks
## Uses ImpostorCandidates patterns (same ones used for impostor generation)
func is_significant_object(model_path: String) -> bool:
	# Lazy initialization of impostor candidates
	if not _impostor_candidates:
		_impostor_candidates = ImpostorCandidatesScript.new()

	return _impostor_candidates.should_have_impostor(model_path)


# REMOVED: _register_with_distance_manager()
# The native streaming system uses visibility_range for distance-based visibility,
# not a separate ObjectStreamer/DistanceTierManager.
# LOD configuration is handled by NativeStreamingManager._configure_cell_visibility()


## Instantiate a standard object with a NIF model
## For flora/rocks, uses StaticObjectRenderer for ~10x faster instantiation
var _model_obj_count: int = 0
func _instantiate_model_object(ref: CellReference, base_record: Variant, cell_grid: Vector2i = Vector2i.ZERO, type_name: String = "") -> Node3D:
	_model_obj_count += 1

	# Get model path and record ID
	var model_path: String = _get_model_path(base_record)
	if model_path.is_empty():
		return null

	# Get record_id for collision shape library lookup
	var record_id: String = ""
	if "record_id" in base_record:
		record_id = base_record.record_id

	# Debug: Log what path each object is taking
	if debug_lod and _model_obj_count <= 20:
		var is_static := use_static_renderer and static_renderer and _is_static_render_model(model_path)
		var is_sig := is_significant_object(model_path)
		Log.debug("streaming", "[LOD-PATH] #%d %s: static_render=%s, significant=%s" % [
			_model_obj_count, model_path.get_file(), is_static, is_sig
		])

	# Check if this model should use static rendering (flora, small rocks)
	# Static rendering is ~10x faster but has no physics/interaction
	if use_static_renderer and static_renderer and _is_static_render_model(model_path):
		return _instantiate_static_object(ref, model_path, cell_grid)

	# Try to get from object pool first (if enabled)
	if use_object_pool and object_pool:
		var pooled: Node3D = object_pool.call("acquire", model_path)
		if pooled:
			pooled.name = str(ref.ref_id) + "_" + str(ref.ref_num)
			# Note: visibility_range is already configured on pooled objects
			_apply_transform(pooled, ref, true)
			stats["objects_from_pool"] += 1
			return pooled

	# Load or get cached model (with item_id for collision shape lookup)
	var model_prototype: Node3D = model_loader.call("get_model", model_path, record_id)
	if not model_prototype:
		# Create a placeholder for missing models
		return _create_placeholder(ref)

	# Note: Object pool registration is handled by CellManager during cell loading
	# to avoid tight coupling with ObjectPool implementation details

	# Create instance
	var instance: Node3D = model_prototype.duplicate()
	instance.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Hide materialless meshes (collision geometry, placeholders)
	# LOD nodes (_LOD1, _LOD2, _LOD3) are now kept visible and configured with visibility_range
	_hide_lod_nodes(instance)

	# Apply transform
	_apply_transform(instance, ref, true)

	# Add metadata for console object picker
	_apply_metadata(instance, ref, base_record, model_path, type_name)

	stats["objects_instantiated"] += 1

	# Auto-play NIF keyframe animations (flags, banners, rotating objects) in NEAR tier only
	_auto_play_nif_animation(instance, ref)

	# NOTE: Fade-in is NOT applied here because the node isn't in the scene tree yet.
	# Fade-in must be applied AFTER add_child() - see CellManager._instantiate_cell()

	# NOTE: visibility_range configuration happens in NativeStreamingManager._configure_cell_visibility()
	# after the cell is added to the scene tree. No need to register with a separate distance manager.

	return instance


## Instantiate a flora/rock using StaticObjectRenderer (RenderingServer direct)
## Returns null (no Node3D created) - the instance exists only in RenderingServer
## This is ~10x faster than Node3D.duplicate()
func _instantiate_static_object(ref: CellReference, model_path: String, cell_grid: Vector2i) -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")

	# Ensure model is loaded and registered with static renderer
	if not static_renderer.call("has_type", normalized):
		# Load prototype to get mesh
		var prototype: Node3D = model_loader.call("get_model", model_path)
		if prototype:
			static_renderer.call("register_from_prototype", normalized, prototype)
		else:
			return null

	# Calculate transform using CoordinateSystem's ESM rotation conversion
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	basis = basis.scaled(scale)
	var transform := Transform3D(basis, pos)

	# Get mesh AABB for GPU Scene Database
	var mesh_type_stats: Dictionary = static_renderer.call("get_mesh_type_stats", normalized)
	var aabb: AABB = mesh_type_stats.get("aabb", AABB())

	# Add instance to static renderer
	var instance_id: int = static_renderer.call("add_instance", normalized, transform, cell_grid)
	if instance_id >= 0:
		stats["static_renderer_instances"] += 1

		# Store data for GPU Scene Database collection by CellManager
		last_static_data = {
			"transform": transform,
			"aabb": aabb,
			"mesh_id": float(normalized.hash()), # Float-compatible float for SSBO
			"lod_mask": 0 # Default for now
		}

	# Return null - no Node3D created, exists only in RenderingServer
	# The cell_grid parameter lets us clean up when the cell unloads
	return null


## Instantiate a light object (model + OmniLight3D)
func _instantiate_light(ref: CellReference, light_record: LightRecord) -> Node3D:
	# Create container node
	var light_node := Node3D.new()
	light_node.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Load the model if it has one
	if not light_record.model.is_empty():
		var model_prototype: Node3D = model_loader.call("get_model", light_record.model)
		if model_prototype:
			var model_instance: Node3D = model_prototype.duplicate()
			model_instance.name = "Model"
			_hide_lod_nodes(model_instance)  # Hide materialless meshes only
			# Auto-play NIF animations on light models (rotating lights, animated lanterns)
			_auto_play_nif_animation(model_instance, ref)
			light_node.add_child(model_instance)

	# Create the actual light source
	if create_lights and light_record.radius > 0 and not light_record.is_off_by_default():
		var omni := OmniLight3D.new()
		omni.name = "Light"

		# Convert MW radius to Godot range
		# MW radius is in game units, Godot uses meters
		# Enforce minimum 0.125m (16 game units) per OpenMW convention
		var godot_range: float = maxf(light_record.radius * MW_LIGHT_SCALE, 0.125)
		omni.omni_range = godot_range

		# Set light color
		omni.light_color = light_record.color

		# Negative lights subtract light (Morrowind feature)
		if light_record.is_negative():
			omni.light_negative = true

		# Set energy based on whether it's a fire/torch light
		omni.light_energy = 1.2 if light_record.is_fire() else 0.8

		# Shadows disabled by default — managed by LightShadowBudget if present
		omni.shadow_enabled = false

		# Attenuation: softer falloff for enclosed spaces
		omni.omni_attenuation = 1.0

		# Distance fade: remove lights from cluster budget beyond visibility
		# Begin fading at 120m, fully gone by 150m (matches NEAR tier boundary)
		omni.distance_fade_enabled = true
		omni.distance_fade_begin = 120.0
		omni.distance_fade_length = 30.0

		# Store light flags for animator and shadow budget manager
		omni.set_meta("mw_flags", light_record.flags)
		omni.set_meta("mw_radius", light_record.radius)
		omni.set_meta("base_energy", omni.light_energy)

		light_node.add_child(omni)
		stats["lights_created"] += 1

	# Apply transform to the container
	_apply_transform(light_node, ref, false)

	# Add metadata for console object picker
	light_node.set_meta("form_id", light_record.record_id if "record_id" in light_record else str(ref.ref_id))
	light_node.set_meta("record_type", "LIGH")
	light_node.set_meta("model_path", light_record.model if not light_record.model.is_empty() else "")
	light_node.set_meta("ref_id", str(ref.ref_id))
	light_node.set_meta("ref_num", ref.ref_num)
	light_node.set_meta("instance_id", ref.ref_num)

	return light_node


## Instantiate an NPC or Creature
## Uses CharacterFactory to create fully animated and functional characters
func _instantiate_actor(ref: CellReference, actor_record: Variant, actor_type: String) -> Node3D:
	# Skip actors beyond NEAR tier — full CharacterBody3D is too expensive at distance
	if max_actor_distance > 0.0:
		var ref_pos := CS.vector_to_godot(ref.position)
		if ref_pos.distance_squared_to(camera_position) > max_actor_distance * max_actor_distance:
			return null

	# Use CharacterFactory if available (new system)
	if character_factory:
		var character: CharacterBody3D = null

		if actor_record is CreatureRecord:
			var creature_rec: CreatureRecord = actor_record as CreatureRecord
			character = character_factory.create_creature(creature_rec, ref.ref_num)
			stats["creatures_loaded"] += 1
		elif actor_record is NPCRecord:
			var npc_rec: NPCRecord = actor_record as NPCRecord
			character = character_factory.create_npc(npc_rec, ref.ref_num)
			stats["npcs_loaded"] += 1

		if character:
			# Apply transform to the CharacterBody3D
			_apply_transform(character, ref, true)

			# Add additional metadata for console object picker
			character.set_meta("form_id", actor_record.record_id if "record_id" in actor_record else str(ref.ref_id))
			character.set_meta("ref_id", str(ref.ref_id))
			character.set_meta("instance_id", ref.ref_num)
			character.set_meta("actor_type", actor_type)

			return character

	# Fallback to old system if CharacterFactory not available
	return _instantiate_actor_legacy(ref, actor_record, actor_type)


## Legacy actor instantiation (old system - basic model loading)
func _instantiate_actor_legacy(ref: CellReference, actor_record: Variant, actor_type: String) -> Node3D:
	var model_path: String = ""

	if actor_record is CreatureRecord:
		model_path = actor_record.model
		stats["creatures_loaded"] += 1
	elif actor_record is NPCRecord:
		# NPCs are complex - they use body parts assembled together
		# For now, use the base model if available, otherwise skip
		model_path = actor_record.model
		stats["npcs_loaded"] += 1

	if model_path.is_empty():
		# NPC without direct model - would need body part assembly
		# Create a simple placeholder for now
		return _create_actor_placeholder(ref, actor_record, actor_type)

	var model_prototype: Node3D = model_loader.call("get_model", model_path)
	if not model_prototype:
		return _create_actor_placeholder(ref, actor_record, actor_type)

	var instance: Node3D = model_prototype.duplicate()
	instance.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Hide materialless meshes only
	_hide_lod_nodes(instance)

	# Check if model has actor collision metadata (from NIF "Bounding Box" node)
	# If so, ensure it has a capsule collision shape for proper physics
	if instance.has_meta("actor_collision_extents"):
		_ensure_actor_collision(instance, actor_type)

	# Apply transform
	_apply_transform(instance, ref, true)

	# Add metadata for console object picker
	var record_type := "NPC_" if actor_type == "npc" else "CREA"
	instance.set_meta("form_id", actor_record.record_id if "record_id" in actor_record else str(ref.ref_id))
	instance.set_meta("record_type", record_type)
	instance.set_meta("model_path", model_path)
	instance.set_meta("ref_id", str(ref.ref_id))
	instance.set_meta("ref_num", ref.ref_num)
	instance.set_meta("instance_id", ref.ref_num)
	instance.set_meta("actor_type", actor_type)

	return instance


## Ensure actor has proper capsule collision for CharacterBody3D compatibility
func _ensure_actor_collision(instance: Node3D, actor_type: String) -> void:
	# Get collision data from metadata (set by NIFConverter)
	var extents: Vector3 = instance.get_meta("actor_collision_extents", Vector3(0.3, 0.9, 0.3))
	var center: Vector3 = instance.get_meta("actor_collision_center", Vector3.ZERO)

	# Convert extents to Godot coordinates (Y-up) and meters
	extents = CS.vector_to_godot(extents).abs()
	center = CS.vector_to_godot(center)

	# Calculate dimensions
	var width := maxf(extents.x, extents.z) * 2.0
	var height := extents.y * 2.0

	# Create collision shape - capsule for humanoids, box for squat creatures
	var coll_shape := CollisionShape3D.new()
	coll_shape.name = "ActorCollision"

	if height > width * 1.2:
		# Capsule for humanoid shapes
		var capsule := CapsuleShape3D.new()
		capsule.radius = width / 2.0
		capsule.height = height
		coll_shape.shape = capsule
	else:
		# Box for squat creatures (rats, mudcrabs, etc.)
		var box := BoxShape3D.new()
		box.size = Vector3(width, height, width)
		coll_shape.shape = box

	# Position collision shape at center
	coll_shape.position = center

	# Add to actor model
	# Find or create physics body
	var body: StaticBody3D = null
	for child in instance.get_children():
		if child is StaticBody3D:
			body = child
			break

	if not body:
		body = StaticBody3D.new()
		body.name = "ActorBody"
		body.collision_layer = 2  # Actor layer
		body.collision_mask = 1   # World collision
		instance.add_child(body)

	body.add_child(coll_shape)


## Create a placeholder for actors without models
func _create_actor_placeholder(ref: CellReference, _actor_record: Variant, actor_type: String) -> Node3D:
	var container := Node3D.new()
	container.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Visual placeholder mesh
	var placeholder := MeshInstance3D.new()
	placeholder.name = "Visual"

	# Capsule mesh for humanoid shape (in meters)
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35  # ~35cm radius
	capsule.height = 1.8   # ~1.8m tall
	placeholder.mesh = capsule

	# Color based on type
	var mat := StandardMaterial3D.new()
	if actor_type == "npc":
		mat.albedo_color = Color(0.2, 0.6, 1.0, 0.7)  # Blue for NPCs
	else:
		mat.albedo_color = Color(1.0, 0.4, 0.2, 0.7)  # Orange for creatures
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	placeholder.material_override = mat

	# Offset visual so bottom is at origin (feet at ground level)
	placeholder.position.y = capsule.height / 2.0

	container.add_child(placeholder)

	# Add collision body with capsule shape
	var body := StaticBody3D.new()
	body.name = "ActorBody"
	body.collision_layer = 2  # Actor layer
	body.collision_mask = 1   # World collision

	var coll_shape := CollisionShape3D.new()
	coll_shape.name = "ActorCollision"
	var coll_capsule := CapsuleShape3D.new()
	coll_capsule.radius = 0.35
	coll_capsule.height = 1.8
	coll_shape.shape = coll_capsule
	coll_shape.position.y = capsule.height / 2.0  # Match visual

	body.add_child(coll_shape)
	container.add_child(body)

	# Store metadata
	container.set_meta("actor_type", actor_type)
	container.set_meta("is_placeholder", true)

	# Apply transform (no model rotation needed for placeholder)
	_apply_transform(container, ref, false)

	return container


## Resolve a leveled creature list to an actual creature record
## Uses a simplified algorithm: pick a random creature from valid level range
## player_level defaults to 10 for now (could be passed in later)
func _resolve_leveled_creature(leveled: LeveledCreatureRecord, player_level: int = 10) -> CreatureRecord:
	if leveled.creatures.is_empty():
		return null

	# Check chance_none - random chance to spawn nothing
	if leveled.chance_none > 0 and randi() % 100 < leveled.chance_none:
		return null

	# Filter creatures by level (creatures spawn if player_level >= creature_level)
	var valid_creatures: Array[Dictionary] = []
	for entry in leveled.creatures:
		if entry.level <= player_level:
			valid_creatures.append(entry)

	if valid_creatures.is_empty():
		# No valid creatures for this level, pick lowest level one
		var lowest_entry: Dictionary = leveled.creatures[0]
		for entry in leveled.creatures:
			if entry.level < lowest_entry.level:
				lowest_entry = entry
		valid_creatures.append(lowest_entry)

	# Pick random creature from valid list
	var chosen: Dictionary = valid_creatures[randi() % valid_creatures.size()]
	var creature_id: String = chosen.creature_id

	# Look up the actual creature record
	var creature: CreatureRecord = ESMManager.get_creature(creature_id)
	if creature:
		return creature

	# Might be a nested leveled list - try to resolve recursively
	var nested_leveled: LeveledCreatureRecord = ESMManager.get_leveled_creature(creature_id)
	if nested_leveled:
		return _resolve_leveled_creature(nested_leveled, player_level)

	push_warning("ReferenceInstantiator: Could not resolve creature '%s' from leveled list '%s'" % [
		creature_id, leveled.record_id
	])
	return null


## Auto-play NIF keyframe animations on objects within NEAR tier (0-150m)
## Handles animated world objects like flags, banners, rotating lights, etc.
## Only plays if the object has a prebaked AnimationPlayer from NIF conversion.
func _auto_play_nif_animation(instance: Node3D, ref: CellReference) -> void:
	# Skip if beyond NEAR tier — animations are only visible up close
	if max_actor_distance > 0.0:
		var ref_pos := CS.vector_to_godot(ref.position)
		if ref_pos.distance_squared_to(camera_position) > max_actor_distance * max_actor_distance:
			return

	# Find AnimationPlayer in the duplicated instance
	var anim_player: AnimationPlayer = null
	for child in instance.get_children():
		if child is AnimationPlayer:
			anim_player = child as AnimationPlayer
			break

	if not anim_player:
		return

	# Get the animation list from the default library
	var library := anim_player.get_animation_library("")
	if not library:
		return

	var anim_list := library.get_animation_list()
	if anim_list.is_empty():
		return

	# Play the first animation (most NIF objects have a single looping animation)
	# Set looping on the animation resource
	var first_anim_name: StringName = anim_list[0]
	var anim: Animation = library.get_animation(first_anim_name)
	if anim:
		anim.loop_mode = Animation.LOOP_LINEAR

	# Autoplay — AnimationPlayer needs to be in the tree to play, so defer
	anim_player.autoplay = first_anim_name

	# Randomize playback position to avoid synchronized animations across instances
	instance.set_meta("_anim_randomize", true)


## Apply position, rotation, and scale to a node
## Uses unified CoordinateSystem for all conversions
func _apply_transform(node: Node3D, ref: CellReference, _apply_model_rotation: bool) -> void:
	# Position conversion via CoordinateSystem (outputs in meters)
	node.position = CS.vector_to_godot(ref.position)
	node.scale = CS.scale_to_godot(ref.scale)

	# Rotation conversion via CoordinateSystem
	# Uses esm_rotation_to_godot_basis() which matches OpenMW's makeOsgQuat
	node.basis = CS.esm_rotation_to_godot_basis(ref.rotation)


## Apply metadata to an object for console object picker identification
func _apply_metadata(node: Node3D, ref: CellReference, base_record: Variant, model_path: String, type_name: String = "") -> void:
	# Form ID / record ID
	if "record_id" in base_record:
		node.set_meta("form_id", base_record.record_id)

	# Model path
	if not model_path.is_empty():
		node.set_meta("model_path", model_path)

	# Reference info
	node.set_meta("ref_id", str(ref.ref_id))
	node.set_meta("ref_num", ref.ref_num)

	# Record type - use type_name string from get_any_record() (Phase 4)
	var record_type := _type_name_to_meta(type_name)
	node.set_meta("record_type", record_type)

	# Instance ID (unique per cell)
	node.set_meta("instance_id", ref.ref_num)


## Convert internal type_name string to ESM record type code for metadata (Phase 4)
static func _type_name_to_meta(type_name: String) -> String:
	match type_name:
		"static": return "STAT"
		"activator": return "ACTI"
		"container": return "CONT"
		"door": return "DOOR"
		"light": return "LIGH"
		"npc": return "NPC_"
		"creature": return "CREA"
		"misc": return "MISC"
		"weapon": return "WEAP"
		"armor": return "ARMO"
		"clothing": return "CLOT"
		"book": return "BOOK"
		"ingredient": return "INGR"
		"apparatus": return "APPA"
		"potion": return "ALCH"
		_: return "UNKNOWN"


## Get the model path from a base record
func _get_model_path(record: Variant) -> String:
	if "model" in record and record.model:
		return record.model
	return ""


## Create a placeholder for missing models
func _create_placeholder(ref: CellReference) -> Node3D:
	var placeholder := MeshInstance3D.new()
	placeholder.name = str(ref.ref_id) + "_placeholder"

	# Simple box mesh (human-sized in Godot meters)
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 1.8, 0.5)  # Roughly human-sized
	placeholder.mesh = box

	# Magenta material to stand out
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.0, 1.0)  # Magenta
	placeholder.material_override = mat

	# Apply transform
	_apply_transform(placeholder, ref, false)

	stats["objects_failed"] += 1
	return placeholder


## Check if a model should use StaticObjectRenderer (fast flora/rock rendering)
func _is_static_render_model(model_path: String) -> bool:
	var lower := model_path.to_lower()

	# Flora - grass, kelp, flowers, ferns (visual only, no interaction)
	if "flora_" in lower:
		# Exclude trees (need collision) and harvestable plants
		if "tree" in lower:
			return false
		if "comberry" in lower or "marshmerrow" in lower or "wickwheat" in lower:
			return false  # Harvestable
		return true

	# Small rocks (purely decorative)
	if "rock_" in lower and "_small" in lower:
		return true

	return false


## Initialize the fade material pool (call once after scene_tree is set)
func _ensure_fade_pool() -> void:
	if _fade_pool_initialized:
		return
	_fade_pool_initialized = true
	_fade_pool.resize(FADE_POOL_SIZE)
	for i in FADE_POOL_SIZE:
		var mat := ShaderMaterial.new()
		mat.shader = LOD_CROSSFADE_SHADER
		_fade_pool[i] = mat


## Acquire a fade material from the pool, or null if exhausted
func _acquire_fade_material() -> ShaderMaterial:
	if _fade_pool.is_empty():
		return null
	return _fade_pool.pop_back()


## Return a fade material to the pool after use
func _release_fade_material(mat: ShaderMaterial) -> void:
	# Reset params to avoid holding references to textures
	mat.set_shader_parameter("albedo_texture", null)
	mat.set_shader_parameter("albedo_color", Color.WHITE)
	mat.set_shader_parameter("roughness", 1.0)
	mat.set_shader_parameter("metallic", 0.0)
	mat.set_shader_parameter("fade_amount", 0.0)
	mat.set_shader_parameter("use_alpha_cutout", false)
	mat.set_shader_parameter("alpha_cutout", 0.5)
	_fade_pool.append(mat)


## Apply fade-in effect to newly instantiated object
## Uses pooled dither crossfade shader for smooth appearance (prevents visual pop)
func _apply_fade_in(instance: Node3D) -> void:
	if not scene_tree:
		if debug_lod:
			Log.debug("streaming", "[ReferenceInstantiator] _apply_fade_in SKIPPED - no scene_tree")
		return  # Need scene tree for tweens

	# Guard: create_tween() requires the node to be in the scene tree.
	# Calling it on a detached node returns null or creates an immediately-killed tween,
	# leaving material_override stuck as the fade ShaderMaterial (invisible object).
	if not instance.is_inside_tree():
		if debug_lod:
			Log.debug("streaming", "[ReferenceInstantiator] _apply_fade_in SKIPPED - node not in tree: %s" % instance.name)
		return

	_ensure_fade_pool()

	# Find all MeshInstance3D nodes in the hierarchy
	var mesh_instances: Array[MeshInstance3D] = []
	_find_mesh_instances(instance, mesh_instances)

	if mesh_instances.is_empty():
		if debug_lod:
			Log.debug("streaming", "[ReferenceInstantiator] _apply_fade_in SKIPPED - no mesh instances in %s" % instance.name)
		return

	if debug_lod:
		Log.debug("streaming", "[ReferenceInstantiator] _apply_fade_in: %s with %d meshes" % [instance.name, mesh_instances.size()])

	# Store original materials and apply pooled fade materials
	var fade_data: Array[Dictionary] = []

	for mesh_inst: MeshInstance3D in mesh_instances:
		# Acquire from pool — if exhausted, skip fade (object pops in instantly)
		var fade_mat := _acquire_fade_material()
		if not fade_mat:
			break

		# Get the original material using the 3-source fallback chain
		# (matches StaticObjectRenderer's material extraction order)
		var original_mat: Material = mesh_inst.material_override

		# Detect stuck fade ShaderMaterial from interrupted tween or pool recycling:
		# If current override has "fade_amount" parameter, it's a leftover fade material.
		# Discard it and fall through to the surface material chain.
		if original_mat is ShaderMaterial:
			var sm := original_mat as ShaderMaterial
			if sm.get_shader_parameter("fade_amount") != null:
				mesh_inst.material_override = null
				original_mat = null

		if original_mat == null and mesh_inst.mesh and mesh_inst.mesh.get_surface_count() > 0:
			original_mat = mesh_inst.get_surface_override_material(0)
			if original_mat == null:
				original_mat = mesh_inst.mesh.surface_get_material(0)

		# Store true original as metadata for robust recovery
		mesh_inst.set_meta("_pre_fade_material", original_mat)

		# Copy texture from original material if it's a StandardMaterial3D
		if original_mat is StandardMaterial3D:
			var std_mat: StandardMaterial3D = original_mat as StandardMaterial3D
			if std_mat.albedo_texture:
				fade_mat.set_shader_parameter("albedo_texture", std_mat.albedo_texture)
			fade_mat.set_shader_parameter("albedo_color", std_mat.albedo_color)
			fade_mat.set_shader_parameter("roughness", std_mat.roughness)
			fade_mat.set_shader_parameter("metallic", std_mat.metallic)
			# Handle alpha cutout for vegetation
			if std_mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
				fade_mat.set_shader_parameter("use_alpha_cutout", true)
				fade_mat.set_shader_parameter("alpha_cutout", std_mat.alpha_scissor_threshold)

		# Start fully invisible
		fade_mat.set_shader_parameter("fade_amount", 0.0)
		mesh_inst.material_override = fade_mat

		fade_data.append({
			"mesh_instance": mesh_inst,
			"fade_material": fade_mat,
			"original_material": original_mat
		})

	if fade_data.is_empty():
		return

	# Create tween to animate fade_amount from 0 to 1
	# IMPORTANT: Bind to the instance node so tween is killed when node is freed
	# This prevents "Lambda capture was freed" errors when cells unload during fade
	var tween: Tween = instance.create_tween()
	tween.set_parallel(true)  # Animate all meshes simultaneously

	for entry: Dictionary in fade_data:
		var fade_mat: ShaderMaterial = entry.fade_material
		var mesh_inst: MeshInstance3D = entry.mesh_instance
		tween.tween_method(
			func(value: float) -> void:
				# Check if mesh still exists before setting shader parameter
				if is_instance_valid(mesh_inst) and is_instance_valid(fade_mat):
					fade_mat.set_shader_parameter("fade_amount", value),
			0.0, 1.0, fade_in_duration
		)

	# When complete, restore original materials and return fade mats to pool
	tween.chain()  # Wait for parallel tweens
	tween.tween_callback(func() -> void:
		for entry: Dictionary in fade_data:
			var fade_mat_ref: Variant = entry.get("fade_material")
			var mesh_inst_ref: Variant = entry.get("mesh_instance")

			# Return the fade material to the pool regardless of mesh validity
			if is_instance_valid(fade_mat_ref):
				_release_fade_material(fade_mat_ref as ShaderMaterial)

			# Restore original material if mesh still exists
			if not is_instance_valid(mesh_inst_ref):
				continue
			var mesh_inst: MeshInstance3D = mesh_inst_ref as MeshInstance3D
			# Prefer metadata (survives edge cases better than closure capture)
			var original_mat: Material = mesh_inst.get_meta("_pre_fade_material", entry.original_material)
			mesh_inst.material_override = original_mat
			mesh_inst.remove_meta("_pre_fade_material")
	)


## Find all MeshInstance3D nodes in a hierarchy
func _find_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)

	for child in node.get_children():
		_find_mesh_instances(child, result)


## Hide materialless meshes in a scene tree (LOD nodes are kept visible)
## Uses centralized MeshVisibilityUtils for consistent behavior across the codebase
func _hide_lod_nodes(node: Node) -> void:
	MeshVisibilityUtils.hide_lod_and_materialless(node, debug_lod)


## Reset statistics
func reset_stats() -> void:
	stats = {
		"objects_instantiated": 0,
		"objects_failed": 0,
		"objects_from_pool": 0,
		"lights_created": 0,
		"npcs_loaded": 0,
		"creatures_loaded": 0,
		"static_renderer_instances": 0,
		"significant_objects_registered": 0,
	}


## Get current statistics
func get_stats() -> Dictionary:
	return stats.duplicate()
