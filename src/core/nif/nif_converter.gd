## NIF Converter - Converts NIF models to Godot scenes/meshes
## Creates Node3D hierarchy with MeshInstance3D nodes
## Supports skinned meshes with Skeleton3D, animations, and collision shapes
##
## Performance: When C# native code is available (NIFReader, NIFConverter),
## mesh building is 2-5x faster. Use NativeBridge.has_native_nif() to check.
class_name NIFConverter
extends RefCounted

# Preload dependencies
const Defs := preload("res://src/core/nif/nif_defs.gd")
const Reader := preload("res://src/core/nif/nif_reader.gd")
const TexLoader := preload("res://src/core/texture/texture_loader.gd")
const MatLib := preload("res://src/core/texture/material_library.gd")
const SkeletonBuilder := preload("res://src/core/nif/nif_skeleton_builder.gd")
const AnimationConverter := preload("res://src/core/nif/nif_animation_converter.gd")
const CollisionBuilder := preload("res://src/core/nif/nif_collision_builder.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const MeshOptimizer := preload("res://addons/meshoptimizer/mesh_optimizer.gd")
const NativeBridgeScript := preload("res://src/core/native_bridge.gd")

## Static flag to track if native C# is available (checked once at startup)
static var _native_available: bool = false
static var _native_checked: bool = false
static var _native_bridge: NativeBridge = null

## Whether to use native C# for parsing (disabled by default until full integration)
## Native parsing is 20-50x faster but requires compatible conversion code.
## Enable this once the full native pipeline is implemented.
static var use_native_parsing: bool = true

## Check if native C# mesh conversion is available
static func is_native_available() -> bool:
	if not _native_checked:
		_native_checked = true
		# Use NativeBridge to check for C# availability
		_native_bridge = NativeBridgeScript.new()
		_native_available = _native_bridge.has_native_nif()
		if _native_available:
			Logger.info("nif", "NIFConverter: C# native classes available via NativeBridge")
		else:
			Logger.info("nif", "NIFConverter: C# native code not available (rebuild C# project to enable)")
	return _native_available


## Parse NIF buffer using native C# reader (20-50x faster than GDScript)
## Returns the C# NIFReader or null on failure
## NOTE: Currently disabled because C# records need conversion adapters
static func _parse_with_native(data: PackedByteArray, path_hint: String) -> RefCounted:
	# Native parsing is disabled until full integration is complete
	if not use_native_parsing:
		return null

	if not is_native_available() or _native_bridge == null:
		return null

	var native_reader: RefCounted = _native_bridge.parse_nif_buffer(data, path_hint)
	if native_reader == null:
		push_warning("NIFConverter: Native parsing failed for %s, falling back to GDScript" % path_hint)
		return null

	return native_reader

# The NIFReader instance (can be GDScript Reader or C# NIFReader)
var _reader: Reader = null

# Native C# reader (used when is_native_reader is true)
var _native_reader: RefCounted = null

# Whether we're using the native C# reader
var _is_native_reader: bool = false

# Skeleton builder for skinned meshes
var _skeleton_builder: SkeletonBuilder = null

# Animation converter for keyframe data
var _animation_converter: AnimationConverter = null

# Collision builder for physics shapes
var _collision_builder: CollisionBuilder = null

# Whether to load textures during conversion
var load_textures: bool = true

# Whether to extract animations during conversion
# DISABLED by default: Most world objects are statics. Enable for NPCs/creatures.
var load_animations: bool = false

# Whether to generate collision shapes during conversion
var load_collision: bool = true

## Whether to use global material library for deduplication
## When true, materials with the same properties share a single instance
## This reduces VRAM usage and improves batching
var use_material_library: bool = true

## Collision mode for geometry-based collision
## See CollisionBuilder.CollisionMode for options:
## - TRIMESH: Full triangle mesh (accurate but slow) - best for architecture
## - CONVEX: Convex hull (fast, good for most objects)
## - AUTO_PRIMITIVE: Auto-detect best primitive shape (sphere, cylinder, box, capsule)
## - PRIMITIVE_ONLY: Only use primitives, skip if can't detect (fastest)
var collision_mode: int = CollisionBuilder.CollisionMode.AUTO_PRIMITIVE

## Whether to auto-select collision mode based on NIF path
## When true, architecture uses TRIMESH, items use AUTO_PRIMITIVE, etc.
var auto_collision_mode: bool = true

## Tolerance for primitive shape detection (0.0 = strict, 1.0 = loose)
var collision_detection_tolerance: float = 0.15

# Debug mode for skeleton/skinning output
var debug_skinning: bool = false

# Debug mode for animation output
var debug_animations: bool = false

# Debug mode for collision output
var debug_collision: bool = false

## LOD Generation Settings
## When enabled, generates simplified LOD meshes during conversion using VisibilityRange
##
## LOD meshes serve TWO purposes:
## 1. NEAR tier (0-150m): VisibilityRange auto-switches between LOD0/LOD1/LOD2
## 2. MID tier (150-500m): ObjectStreamer extracts LOD meshes for MultiMesh batching
##
## Distance thresholds are aligned with streaming tier boundaries:
## - LOD0: 0-50m (full detail, 100%)
## - LOD1: 50-150m (75% triangles) - extracted for MID tier 150-250m
## - LOD2: 150-250m (50% triangles) - extracted for MID tier 250-375m
## - LOD3: 250-500m (25% triangles) - extracted for MID tier 375-500m
var generate_lods: bool = true

## Number of LOD levels to generate (excluding original LOD0)
var lod_levels: int = 3

## Triangle reduction ratios for each LOD level
## LOD1: 50% for MID tier LOD1 (150-250m)
## LOD2: 25% for MID tier LOD2 (250-375m)
## LOD3: 10% for MID tier LOD3 (375-500m)
var lod_reduction_ratios: Array[float] = [0.50, 0.25, 0.10]

## Distance thresholds for LOD switching (in meters)
## These match StreamingConfig MID tier sub-LOD thresholds
## LOD0: 0-50m, LOD1: 50-150m, LOD2: 150-250m, LOD3: 250-500m
var lod_distances: Array[float] = [50.0, 150.0, 250.0, 500.0]

## Fade margin for LOD transitions (prevents popping)
var lod_fade_margin: float = 5.0

## Minimum triangles to generate LODs (skip simple meshes)
var min_triangles_for_lod: int = 100

## Debug mode for LOD generation
var debug_lod: bool = false

## Occlusion Culling Settings
## When enabled, adds OccluderInstance3D to large buildings for better performance
var generate_occluders: bool = true

## Debug mode for occluder generation
var debug_occluders: bool = false

## Material Merging Settings
## When enabled, merges all NiTriShape/NiTriStrips with the same material into one mesh surface.
## This dramatically reduces draw calls for Morrowind models which have many small submeshes.
## Example: A building with 20 wall pieces using the same texture becomes 1 draw call instead of 20.
var merge_by_material: bool = true

## Debug mode for material merging
var debug_merge: bool = false

# Source path for auto collision mode detection
var _source_path: String = ""

## Item ID for collision shape library lookups (e.g., "misc_com_bottle_01")
## Set this before converting to enable YAML-based collision shape overrides
var collision_item_id: String = ""

# Cache for converted resources
var _mesh_cache: Dictionary = {}  # record_index -> ArrayMesh
var _material_cache: Dictionary = {}  # hash -> StandardMaterial3D

# Skeleton cache for this conversion (skin_instance_index -> Skeleton3D)
var _skeleton_cache: Dictionary = {}


# =============================================================================
# READER ABSTRACTION LAYER
# =============================================================================
# These methods provide a unified API for both GDScript and C# readers.
# When native is available, they call C# methods; otherwise GDScript.
# =============================================================================

## Get the roots array from the reader (native or GDScript)
## Returns Array[int] of root indices
func _get_roots() -> Array[int]:
	if _is_native_reader and _native_reader != null:
		var roots_variant: Variant = _native_reader.get("Roots")
		if roots_variant != null and roots_variant is Array:
			var roots_array: Array = roots_variant as Array
			var result: Array[int] = []
			for idx: Variant in roots_array:
				if idx is int:
					result.append(idx as int)
			return result
		return []
	elif _reader != null:
		return _reader.roots
	return []


## Get a record by index from the reader (native or GDScript)
func _get_record(index: int) -> Variant:
	if _is_native_reader and _native_reader != null:
		return _native_reader.call("GetRecord", index)
	elif _reader != null:
		return _reader.get_record(index)
	return null


## Convert a NIF file to a Godot Node3D scene
## Returns the root Node3D or null on failure
func convert_file(path: String) -> Node3D:
	_source_path = path
	_reader = Reader.new()
	var result := _reader.load_file(path)
	if result != OK:
		return null
	return _convert()


## Convert a NIF file with item ID for collision shape library lookup
## item_id: The ESM record ID (e.g., "misc_com_bottle_01") for YAML shape matching
## Returns the root Node3D or null on failure
func convert_file_with_item_id(path: String, item_id: String) -> Node3D:
	collision_item_id = item_id
	return convert_file(path)


## Parse a NIF buffer without converting to scene nodes
## Use this when you need to access NIF data (e.g., build skeleton from hierarchy)
## Returns true on success, false on failure
func parse_buffer(data: PackedByteArray, path_hint: String = "") -> bool:
	_source_path = path_hint
	_reader = Reader.new()
	var result := _reader.load_buffer(data, path_hint)
	if result != OK:
		return false

	# Initialize skeleton builder for hierarchy access
	_skeleton_builder = SkeletonBuilder.new()
	_skeleton_builder.init(_reader)
	_skeleton_builder.debug_mode = debug_skinning

	return true


## Convert a NIF buffer to a Godot Node3D scene
## path_hint is optional but helps auto-detect collision mode and error messages
func convert_buffer(data: PackedByteArray, path_hint: String = "") -> Node3D:
	_source_path = path_hint
	_reader = Reader.new()
	var result := _reader.load_buffer(data, path_hint)
	if result != OK:
		return null
	return _convert()


## Convert a NIF buffer with item ID for collision shape library lookup
## item_id: The ESM record ID (e.g., "misc_com_bottle_01") for YAML shape matching
## Returns the root Node3D or null on failure
func convert_buffer_with_item_id(data: PackedByteArray, item_id: String, path_hint: String = "") -> Node3D:
	collision_item_id = item_id
	return convert_buffer(data, path_hint)


# =============================================================================
# ASYNC CONVERSION API
# =============================================================================
# These methods separate parsing from instantiation for background thread use.
# parse_buffer_only() is THREAD-SAFE and can run on WorkerThreadPool.
# convert_from_parsed() MUST run on main thread (creates scene tree nodes).
# =============================================================================

const NIFParseResult := preload("res://src/core/nif/nif_parse_result.gd")

## Parse a NIF buffer without creating scene nodes (THREAD-SAFE)
## This can be called from a worker thread via BackgroundProcessor.
## Returns NIFParseResult containing the parsed reader, or error info.
##
## Example usage with BackgroundProcessor:
##   var task_id = background_processor.submit_task(func():
##       var converter = NIFConverter.new()
##       return converter.parse_buffer_only(data, path, item_id)
##   )
static func parse_buffer_only(data: PackedByteArray, path_hint: String = "", item_id: String = "") -> NIFParseResult:
	if data.is_empty():
		return NIFParseResult.create_failure(path_hint, "Empty buffer")

	# Try native C# parsing first (20-50x faster)
	var native_reader: RefCounted = _parse_with_native(data, path_hint)
	if native_reader != null:
		# Check if native reader has roots
		var roots_variant: Variant = native_reader.get("Roots")
		var has_roots: bool = roots_variant != null and roots_variant is Array and not (roots_variant as Array).is_empty()
		if not has_roots:
			return NIFParseResult.create_failure(path_hint, "No root nodes in NIF (native)")

		var result := NIFParseResult.create_success(native_reader, path_hint, true)
		result.item_id = item_id
		result.buffer_hash = data.size()
		return result

	# Fall back to GDScript parsing
	var reader := Reader.new()
	var parse_result := reader.load_buffer(data, path_hint)

	if parse_result != OK:
		return NIFParseResult.create_failure(path_hint, "Parse failed with error %d" % parse_result)

	if reader.roots.is_empty():
		return NIFParseResult.create_failure(path_hint, "No root nodes in NIF")

	var result := NIFParseResult.create_success(reader, path_hint, false)
	result.item_id = item_id
	result.buffer_hash = data.size()  # Simple hash for now
	return result


## Convert a pre-parsed NIF to a Godot Node3D scene (MAIN THREAD ONLY)
## parse_result: The result from parse_buffer_only()
## Returns the root Node3D or null on failure
func convert_from_parsed(parse_result: NIFParseResult) -> Node3D:
	if not parse_result.is_valid():
		push_error("NIFConverter: Invalid parse result for %s: %s" % [parse_result.path, parse_result.error])
		return null

	# Transfer parsed data to this converter instance
	_is_native_reader = parse_result.is_native
	if _is_native_reader:
		_native_reader = parse_result.reader
		_reader = null
	else:
		_reader = parse_result.reader as Reader
		_native_reader = null

	_source_path = parse_result.path
	collision_item_id = parse_result.item_id

	# Apply configuration from parse result if set
	if parse_result.load_textures != load_textures:
		load_textures = parse_result.load_textures
	if parse_result.load_animations != load_animations:
		load_animations = parse_result.load_animations
	if parse_result.load_collision != load_collision:
		load_collision = parse_result.load_collision

	return _convert()


# =============================================================================
# FULL NATIVE PIPELINE (Maximum Performance - 20-50x faster)
# =============================================================================
# These methods use the C# full NIF pipeline: parse + mesh building in one call.
# Textures are loaded and applied by GDScript for now.
# =============================================================================

## Convert a NIF buffer using the FULL native pipeline (fastest option).
## This is 20-50x faster than GDScript parsing + 2-5x faster mesh building.
##
## Skeletons and animations are NOT yet supported in native pipeline.
## For skinned meshes (characters), use the standard convert_buffer() method.
##
## Returns the root Node3D or null on failure.
func convert_buffer_native(data: PackedByteArray, path_hint: String = "") -> Node3D:
	if not is_native_available() or _native_bridge == null:
		# Fall back to GDScript
		return convert_buffer(data, path_hint)

	_source_path = path_hint

	# Use full native pipeline
	var result: Dictionary = _native_bridge.convert_nif_to_scene(data, path_hint)
	if not result.get("success", false):
		push_warning("NIFConverter: Native pipeline failed: %s, falling back" % result.get("error", "unknown"))
		return convert_buffer(data, path_hint)

	var root: Node3D = result.get("root") as Node3D
	if root == null:
		push_warning("NIFConverter: Native pipeline returned null root, falling back")
		return convert_buffer(data, path_hint)

	# Apply materials/textures to all MeshInstance3D nodes
	if load_textures:
		_apply_materials_to_native_scene(root)

	# Add LODs if enabled
	if generate_lods and _should_generate_lods():
		_add_lods_to_scene(root)

	# Add occluders if enabled
	if generate_occluders and _should_generate_occluders():
		_add_occluders_to_scene(root)

	return root


## Apply materials to a scene created by native C# conversion.
## The C# converter stores material info as metadata on MeshInstance3D nodes.
func _apply_materials_to_native_scene(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.has_meta("nif_material"):
			var mat_info: Dictionary = mesh_instance.get_meta("nif_material")
			var material := _create_material_from_native_info(mat_info)
			if material:
				mesh_instance.material_override = material

	# Recurse
	for child in node.get_children():
		_apply_materials_to_native_scene(child)


## Create a StandardMaterial3D from the material info dictionary stored by C#.
func _create_material_from_native_info(info: Dictionary) -> StandardMaterial3D:
	if info.is_empty():
		return null

	var texture_path: String = info.get("texture_path", "")

	# Use MaterialLibrary for deduplication
	if use_material_library and load_textures:
		var props := MatLib.MaterialProperties.new()

		# Texture
		props.texture_path = texture_path

		# Material properties
		if info.has("diffuse"):
			props.albedo_color = info["diffuse"] as Color
		if info.has("glossiness"):
			var glossiness: float = info.get("glossiness", 0.0)
			props.specular = glossiness / 128.0
			props.roughness = 1.0 - props.specular

		# Emission
		if info.has("emissive"):
			var emissive: Color = info["emissive"] as Color
			if emissive.r > 0.01 or emissive.g > 0.01 or emissive.b > 0.01:
				props.has_emission = true
				props.emission_color = emissive
				props.emission_energy = 1.0

		# Alpha properties
		if info.get("test_enabled", false):
			props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			var threshold: int = info.get("alpha_threshold", 128)
			props.alpha_scissor_threshold = threshold / 255.0
		elif info.get("blend_enabled", false):
			props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA

		# Vertex colors
		if info.get("use_vertex_colors", false):
			props.use_vertex_colors = true

		return MatLib.get_or_create_material(props)

	# Fallback: Create new material directly
	var material := StandardMaterial3D.new()
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	# Apply material properties
	if info.has("diffuse"):
		material.albedo_color = info["diffuse"] as Color

	if info.has("emissive"):
		var emissive: Color = info["emissive"] as Color
		material.emission = emissive
		material.emission_enabled = emissive.r > 0 or emissive.g > 0 or emissive.b > 0

	if info.has("glossiness"):
		var glossiness: float = info.get("glossiness", 0.0)
		material.metallic_specular = glossiness / 128.0

	# Alpha
	if info.get("blend_enabled", false):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if info.get("test_enabled", false):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		var threshold: int = info.get("alpha_threshold", 128)
		material.alpha_scissor_threshold = threshold / 255.0

	# Vertex colors
	if info.get("use_vertex_colors", false):
		material.vertex_color_use_as_albedo = true

	# Texture
	if not texture_path.is_empty() and load_textures:
		var texture := TexLoader.load_texture(texture_path)
		if texture:
			material.albedo_texture = texture

	return material


## Internal conversion after parsing
func _convert() -> Node3D:
	_mesh_cache.clear()
	_material_cache.clear()
	_skeleton_cache.clear()

	# Get roots using abstraction layer
	var roots := _get_roots()
	if roots.is_empty():
		push_error("NIFConverter: No root nodes")
		return null

	# Skeleton and collision builders currently require GDScript reader.
	# When using native C# reader, these features are limited.
	if not _is_native_reader and _reader != null:
		# Initialize skeleton builder
		_skeleton_builder = SkeletonBuilder.new()
		_skeleton_builder.init(_reader)
		_skeleton_builder.debug_mode = debug_skinning

		# Initialize collision builder
		_collision_builder = CollisionBuilder.new()
		_collision_builder.init(_reader)
		_collision_builder.debug_mode = debug_collision
		_collision_builder.detection_tolerance = collision_detection_tolerance
		_collision_builder.item_id = collision_item_id  # For YAML-based shape lookups

		# Set collision mode - auto-detect from path or use configured mode
		if auto_collision_mode and not _source_path.is_empty():
			_collision_builder.collision_mode = CollisionBuilder.get_recommended_mode(_source_path)
			if debug_collision:
				Logger.debug("nif", "NIFConverter: Auto-selected collision mode %d for %s" % [
					_collision_builder.collision_mode, _source_path.get_file()
				])
		else:
			_collision_builder.collision_mode = collision_mode
	else:
		# Native reader: skeleton/collision not yet supported
		_skeleton_builder = null
		_collision_builder = null

	# Use merged conversion path if enabled and no skinning
	# This dramatically reduces draw calls for static geometry
	if _should_merge_by_material():
		return _convert_merged()

	# Check if this NIF has skinning - if so, we need to create skeleton first
	var has_skinning := _has_skinning_data()

	# Create root node
	# All transforms, vertices, and normals are converted from NIF coordinates
	# (Z-up, Y-forward) to Godot coordinates (Y-up, Z-back) during conversion.
	var root := Node3D.new()
	root.name = "NIFRoot"

	# If we have skinning, create the skeleton and add it to root first
	var skeleton: Skeleton3D = null
	if has_skinning:
		skeleton = _create_skeleton_for_nif()
		if skeleton:
			root.add_child(skeleton)
			if debug_skinning:
				Logger.debug("nif", "NIFConverter: Created skeleton with %d bones" % skeleton.get_bone_count())

	# Convert each root
	for root_idx: int in roots:
		var record_variant: Variant = _get_record(root_idx)
		if record_variant == null:
			continue

		# Cast to NIFRecord (only GDScript reader supported for conversion currently)
		var record: Defs.NIFRecord = record_variant as Defs.NIFRecord
		if record == null:
			push_warning("NIFConverter: Skipping non-NIFRecord at index %d (native conversion not yet supported)" % root_idx)
			continue

		var node := _convert_record(record, skeleton)
		if node:
			# If we have a skeleton, skinned meshes should be children of it
			if skeleton and _is_skinned_subtree(record):
				skeleton.add_child(node)
			else:
				root.add_child(node)

	# Post-process: Link skinned meshes to skeleton
	if skeleton:
		_link_skinned_meshes_to_skeleton(root, skeleton)

	# Extract and add animations if enabled
	if load_animations and _has_animation_data():
		var anim_player := _create_animation_player(skeleton)
		if anim_player:
			root.add_child(anim_player)
			if debug_animations:
				Logger.debug("nif", "NIFConverter: Created AnimationPlayer with %d animations" % anim_player.get_animation_library("").get_animation_list().size())

	# Build and add collision shapes if enabled
	if load_collision:
		var collision_result := _collision_builder.build_collision()
		if collision_result.has_collision:
			var static_body := _collision_builder.create_static_body(collision_result)
			if static_body:
				root.add_child(static_body)
				if debug_collision:
					Logger.debug("nif", "NIFConverter: Created StaticBody3D with %d collision shapes" % collision_result.collision_shapes.size())

			# Store actor collision info as metadata for later use
			if collision_result.has_actor_collision_box:
				root.set_meta("actor_collision_center", collision_result.bounding_box_center)
				root.set_meta("actor_collision_extents", collision_result.bounding_box_extents)

	# Post-process: Add LOD systems to appropriate meshes
	if generate_lods and _should_generate_lods():
		_add_lods_to_scene(root)

	# Post-process: Add occluders to large buildings for occlusion culling
	if generate_occluders and _should_generate_occluders():
		_add_occluders_to_scene(root)

	return root


## Recursively traverse scene and add LOD systems to appropriate meshes
func _add_lods_to_scene(node: Node) -> void:
	# Process MeshInstance3D nodes
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		# Skip if already has LOD metadata (from old system) or is a skeleton
		if not mesh_instance.has_meta("_has_skeleton") and mesh_instance.mesh != null:
			var mesh := mesh_instance.mesh as ArrayMesh
			if mesh:
				_add_visibility_range_lods(mesh_instance, mesh)

	# Recurse into children
	for child in node.get_children():
		_add_lods_to_scene(child)


## Check if this NIF should generate occluders based on model path
## Generates occluders for: large buildings, towers, cantons, walls, rocks
func _should_generate_occluders() -> bool:
	if _source_path.is_empty():
		return false

	var lower := _source_path.to_lower()

	# Skip small objects that shouldn't occlude
	if "furn_" in lower or "contain_" in lower or "light_" in lower:
		return false
	if "flora_" in lower or "grass_" in lower or "kelp" in lower:
		return false
	if "clutter" in lower or "misc_" in lower or "food_" in lower:
		return false

	# Exterior buildings (ex_ prefix)
	if "ex_" in lower:
		return true  # All exterior building pieces are potential occluders

	# Interior pieces (in_ prefix) - walls, halls
	if "in_" in lower:
		# Large hall/chamber pieces
		if "hall" in lower or "chamber" in lower or "cavern" in lower:
			return true
		if "wall" in lower or "pillar" in lower or "column" in lower:
			return true

	# Dwemer ruins
	if "dwrv_" in lower or "dwemer" in lower:
		return true

	# Daedric ruins
	if "dae_" in lower or "daedric" in lower:
		return true

	# Velothi towers and tombs
	if "velothi" in lower:
		return true

	# Large terrain features
	if "terrain_rock" in lower or "rock_" in lower:
		# Only large rocks (check size in _add_occluder_to_mesh)
		return true

	# Ships and boats (large wooden structures)
	if "ship" in lower or "boat" in lower:
		return true

	# Bridges
	if "bridge" in lower:
		return true

	# Walls and gates
	if "wall" in lower or "gate" in lower or "fence" in lower:
		return true

	return false


## Recursively traverse scene and add occluders to large meshes
func _add_occluders_to_scene(node: Node) -> void:
	# Process MeshInstance3D nodes
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh:
			var mesh := mesh_instance.mesh as ArrayMesh
			if mesh and mesh.get_surface_count() > 0:
				_add_occluder_to_mesh(mesh_instance)

	# Recurse into children
	for child in node.get_children():
		_add_occluders_to_scene(child)


## Add an OccluderInstance3D to a MeshInstance3D based on its bounding box
func _add_occluder_to_mesh(mesh_instance: MeshInstance3D) -> void:
	var mesh := mesh_instance.mesh
	if not mesh or mesh.get_surface_count() == 0:
		return

	# Calculate AABB (axis-aligned bounding box) for the mesh
	var aabb: AABB = mesh.get_aabb()
	var size := aabb.size

	# Minimum size thresholds - objects smaller than this won't occlude much
	# Buildings need at least 3m, rocks need 4m to be worthwhile occluders
	var min_size: float = 3.0
	if "rock" in _source_path.to_lower():
		min_size = 4.0  # Rocks need to be larger to be effective occluders

	# Check if mesh is large enough in at least one dimension
	var max_dim: float = maxf(size.x, maxf(size.y, size.z))
	if max_dim < min_size:
		return

	# Skip very thin meshes (walls thinner than 0.3m aren't good occluders)
	var min_dim: float = minf(size.x, minf(size.y, size.z))
	if min_dim < 0.3:
		return

	# Create box occluder
	var occluder := OccluderInstance3D.new()
	occluder.name = "Occluder"

	var box_occluder := BoxOccluder3D.new()
	# Make occluder slightly smaller than mesh (85%) to avoid edge artifacts
	# and prevent popping when camera is near edges
	box_occluder.size = size * 0.85

	occluder.occluder = box_occluder
	occluder.position = aabb.get_center()

	# Add as sibling to mesh instance
	var parent := mesh_instance.get_parent()
	if parent:
		parent.add_child(occluder)

		if debug_occluders:
			Logger.debug("nif", "NIFConverter: Added occluder to '%s' (size: %v)" % [
				_source_path.get_file(), size
			])


## Recursively find skinned meshes and link them to the skeleton
func _link_skinned_meshes_to_skeleton(node: Node, skeleton: Skeleton3D) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.has_meta("_has_skeleton"):
			# Set the skeleton path - need to compute relative path from mesh to skeleton
			mesh_instance.skeleton = mesh_instance.get_path_to(skeleton)
			mesh_instance.remove_meta("_has_skeleton")

			if debug_skinning:
				Logger.debug("nif", "NIFConverter: Linked '%s' to skeleton (path=%s)" % [
					mesh_instance.name, mesh_instance.skeleton
				])

	# Recurse into children
	for child in node.get_children():
		_link_skinned_meshes_to_skeleton(child, skeleton)


## Check if this NIF has any skinning data
func _has_skinning_data() -> bool:
	for record: Defs.NIFRecord in _reader.records:
		if record is Defs.NiSkinInstance:
			return true
	return false


## Check if a record or its children contain skinned geometry
func _is_skinned_subtree(record: Defs.NIFRecord) -> bool:
	if record is Defs.NiGeometry:
		var geom := record as Defs.NiGeometry
		return geom.skin_index >= 0

	if record is Defs.NiNode:
		var node := record as Defs.NiNode
		for child_idx in node.children_indices:
			if child_idx < 0:
				continue
			var child := _reader.get_record(child_idx)
			if child and _is_skinned_subtree(child):
				return true

	return false


## Create the skeleton for this NIF (finds first skin instance)
func _create_skeleton_for_nif() -> Skeleton3D:
	# Find the first NiSkinInstance
	for record: Defs.NIFRecord in _reader.records:
		if record is Defs.NiSkinInstance:
			var skin_instance := record as Defs.NiSkinInstance
			var skeleton := _skeleton_builder.build_skeleton(skin_instance)
			if skeleton:
				_skeleton_cache[record.record_index] = skeleton
				return skeleton

	return null


## Create a skeleton from NIF node hierarchy (for skeleton-only files like base_anim.nif)
## This builds a skeleton from ALL bone nodes, not just those with vertex weights.
func create_skeleton_from_hierarchy() -> Skeleton3D:
	if _skeleton_builder == null:
		push_error("NIFConverter: Skeleton builder not initialized")
		return null

	# Find the root NiNode
	var root_node: Defs.NiNode = null
	for record: Defs.NIFRecord in _reader.records:
		if record is Defs.NiNode:
			# Check if this is a root by name (Bip01 is the typical root)
			var node := record as Defs.NiNode
			var name_lower := node.name.to_lower() if node.name else ""
			if name_lower == "bip01" or name_lower == "root bone":
				root_node = node
				break

	# If no Bip01 root found, try finding the first root NiNode
	if root_node == null:
		# Find all NiNode indices that are referenced as children
		var child_indices := {}
		for record: Defs.NIFRecord in _reader.records:
			if record is Defs.NiNode:
				for child_idx in (record as Defs.NiNode).children_indices:
					if child_idx >= 0:
						child_indices[child_idx] = true

		# Find an NiNode that isn't a child of anything (root)
		for record: Defs.NIFRecord in _reader.records:
			if record is Defs.NiNode:
				if not child_indices.has(record.record_index):
					root_node = record as Defs.NiNode
					break

	if root_node == null:
		push_error("NIFConverter: No root NiNode found for skeleton hierarchy")
		return null

	if debug_skinning:
		Logger.debug("nif", "NIFConverter: Building skeleton from hierarchy, root='%s'" % root_node.name)

	return _skeleton_builder.build_skeleton_from_hierarchy(root_node)


## Convert a record to a Godot node
func _convert_record(record: Defs.NIFRecord, skeleton: Skeleton3D = null) -> Node3D:
	if record == null:
		return null

	# Node types (order matters - check derived types before base types)
	if record is Defs.NiLODNode:
		return _convert_ni_lod_node(record as Defs.NiLODNode, skeleton)
	elif record is Defs.NiSwitchNode:
		return _convert_ni_switch_node(record as Defs.NiSwitchNode, skeleton)
	elif record is Defs.NiNode:
		return _convert_ni_node(record as Defs.NiNode, skeleton)
	# Geometry types
	elif record is Defs.NiTriShape:
		return _convert_ni_tri_shape(record as Defs.NiTriShape, skeleton)
	elif record is Defs.NiTriStrips:
		return _convert_ni_tri_strips(record as Defs.NiTriStrips, skeleton)
	# Particle types
	elif record is Defs.NiParticles:
		return _convert_ni_particles(record as Defs.NiParticles)
	# Light types (order matters - check derived types before base types)
	elif record is Defs.NiSpotLight:
		return _convert_ni_spot_light(record as Defs.NiSpotLight)
	elif record is Defs.NiPointLight:
		return _convert_ni_point_light(record as Defs.NiPointLight)
	elif record is Defs.NiLight:
		return _convert_ni_light(record as Defs.NiLight)
	else:
		return null

## Convert a Transform3D from NIF coordinates to Godot coordinates
## Delegates to unified CoordinateSystem - outputs in meters
static func _convert_nif_transform(transform: Transform3D) -> Transform3D:
	return CS.transform_to_godot(transform)  # Converts to meters


## Convert NiNode to Node3D
func _convert_ni_node(ni_node: Defs.NiNode, skeleton: Skeleton3D = null) -> Node3D:
	var node := Node3D.new()
	node.name = ni_node.name if ni_node.name else "Node_%d" % ni_node.record_index

	# Apply transform - convert from NIF to Godot coordinates
	node.transform = _convert_nif_transform(ni_node.transform.to_transform3d())

	# Hide if flagged
	if ni_node.is_hidden():
		node.visible = false

	# Handle NiBillboardNode - mark with billboard metadata
	if ni_node.record_type == Defs.RT_NI_BILLBOARD_NODE:
		node.set_meta("nif_billboard", true)
		node.set_meta("nif_record_type", ni_node.record_type)

	# Convert children
	for child_idx in ni_node.children_indices:
		if child_idx < 0:
			continue
		var child_record := _reader.get_record(child_idx)
		var child_node := _convert_record(child_record, skeleton)
		if child_node:
			node.add_child(child_node)

	return node

## Convert NiTriShape to MeshInstance3D
func _convert_ni_tri_shape(shape: Defs.NiTriShape, skeleton: Skeleton3D = null) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = shape.name if shape.name else "Mesh_%d" % shape.record_index

	# Apply transform - convert from NIF to Godot coordinates
	# (for skinned meshes, this is typically identity)
	mesh_instance.transform = _convert_nif_transform(shape.transform.to_transform3d())

	# Hide if flagged
	if shape.is_hidden():
		mesh_instance.visible = false

	# Get geometry data
	if shape.data_index < 0:
		return mesh_instance

	var data_record := _reader.get_record(shape.data_index)
	if data_record == null or not (data_record is Defs.NiTriShapeData):
		return mesh_instance

	var data := data_record as Defs.NiTriShapeData

	# Check if this mesh has skin data (regardless of whether we have a skeleton)
	# We need to extract skin data for body parts even when no skeleton is passed
	var has_skin_data := shape.skin_index >= 0
	var skin_instance: Defs.NiSkinInstance = null
	var skin_data: Defs.NiSkinData = null

	if has_skin_data:
		skin_instance = _reader.get_record(shape.skin_index) as Defs.NiSkinInstance
		if skin_instance and skin_instance.data_index >= 0:
			skin_data = _reader.get_record(skin_instance.data_index) as Defs.NiSkinData

		if debug_skinning:
			Logger.debug("nif", "NIFConverter: Converting skinned mesh '%s'" % mesh_instance.name)

	# Create mesh (with skinning data if available)
	var mesh: ArrayMesh
	if has_skin_data and skin_instance and skin_data:
		mesh = _create_skinned_tri_shape_mesh(data, skin_instance, skin_data)
	else:
		mesh = _create_tri_shape_mesh(data)

	if mesh:
		mesh_instance.mesh = mesh

		# Apply material from properties
		var material := _get_material_for_shape(shape)
		if material:
			mesh_instance.material_override = material

		# Link to skeleton for skinned meshes (when skeleton is provided)
		if has_skin_data and skeleton:
			# The skeleton path is relative from the mesh to the skeleton
			# Since both are children of NIFRoot (or skeleton contains mesh),
			# we need to set this after the scene tree is built
			mesh_instance.set_meta("_has_skeleton", true)

		# Store bone names and INVERSE bind poses for later Skin resource creation
		# This is critical for body parts that need to be attached to base_anim skeleton
		# Godot's Skin.add_bind() expects the INVERSE bind pose (not bind pose)
		if has_skin_data and skin_instance and skin_data:
			var bone_names: Array[String] = []
			var inv_bind_poses: Array[Transform3D] = []

			for i in range(skin_instance.bone_indices.size()):
				var bone_idx: int = skin_instance.bone_indices[i]
				var bone_node := _reader.get_record(bone_idx) as Defs.NiNode
				if bone_node and bone_node.name:
					bone_names.append(bone_node.name)
				else:
					bone_names.append("Bone_%d" % bone_idx)

				# Get inverse bind matrix from NIF and convert to Godot space
				# NIF stores inverse bind matrices directly in NiSkinData.bones[].transform
				if i < skin_data.bones.size():
					var bone_info: Dictionary = skin_data.bones[i]
					var bone_transform: Defs.NIFTransform = bone_info["transform"]
					var inv_bind_nif := bone_transform.to_transform3d()
					var inv_bind_godot := CS.transform_to_godot(inv_bind_nif)
					inv_bind_poses.append(inv_bind_godot)
				else:
					inv_bind_poses.append(Transform3D.IDENTITY)

			# Store metadata on BOTH the MeshInstance3D and the ArrayMesh
			# The ArrayMesh needs it for skin building when body parts are extracted
			mesh_instance.set_meta("bone_names", bone_names)
			mesh_instance.set_meta("inv_bind_poses", inv_bind_poses)
			if mesh:
				mesh.set_meta("bone_names", bone_names)
				mesh.set_meta("inv_bind_poses", inv_bind_poses)

	return mesh_instance

## Convert NiTriStrips to MeshInstance3D
func _convert_ni_tri_strips(strips: Defs.NiTriStrips, skeleton: Skeleton3D = null) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = strips.name if strips.name else "Mesh_%d" % strips.record_index

	# Apply transform - convert from NIF to Godot coordinates
	mesh_instance.transform = _convert_nif_transform(strips.transform.to_transform3d())

	# Hide if flagged
	if strips.is_hidden():
		mesh_instance.visible = false

	# Get geometry data
	if strips.data_index < 0:
		return mesh_instance

	var data_record := _reader.get_record(strips.data_index)
	if data_record == null or not (data_record is Defs.NiTriStripsData):
		return mesh_instance

	var data := data_record as Defs.NiTriStripsData

	# Check if this mesh has skin data (regardless of whether we have a skeleton)
	# We need to extract skin data for body parts even when no skeleton is passed
	var has_skin_data := strips.skin_index >= 0
	var skin_instance: Defs.NiSkinInstance = null
	var skin_data: Defs.NiSkinData = null

	if has_skin_data:
		skin_instance = _reader.get_record(strips.skin_index) as Defs.NiSkinInstance
		if skin_instance and skin_instance.data_index >= 0:
			skin_data = _reader.get_record(skin_instance.data_index) as Defs.NiSkinData

		if debug_skinning:
			Logger.debug("nif", "NIFConverter: Converting skinned strip mesh '%s'" % mesh_instance.name)

	# Create mesh (with skinning data if available)
	var mesh: ArrayMesh
	if has_skin_data and skin_instance and skin_data:
		mesh = _create_skinned_tri_strips_mesh(data, skin_instance, skin_data)
	else:
		mesh = _create_tri_strips_mesh(data)

	if mesh:
		mesh_instance.mesh = mesh

		# Apply material from properties
		var material := _get_material_for_shape(strips)
		if material:
			mesh_instance.material_override = material

		# Link to skeleton for skinned meshes (when skeleton is provided)
		if has_skin_data and skeleton:
			mesh_instance.set_meta("_has_skeleton", true)

		# Store bone names and INVERSE bind poses for later Skin resource creation
		# This is critical for body parts that need to be attached to base_anim skeleton
		# Godot's Skin.add_bind() expects the INVERSE bind pose (not bind pose)
		if has_skin_data and skin_instance and skin_data:
			var bone_names: Array[String] = []
			var inv_bind_poses: Array[Transform3D] = []

			for i in range(skin_instance.bone_indices.size()):
				var bone_idx: int = skin_instance.bone_indices[i]
				var bone_node := _reader.get_record(bone_idx) as Defs.NiNode
				if bone_node and bone_node.name:
					bone_names.append(bone_node.name)
				else:
					bone_names.append("Bone_%d" % bone_idx)

				# Get inverse bind matrix from NIF and convert to Godot space
				# NIF stores inverse bind matrices directly in NiSkinData.bones[].transform
				if i < skin_data.bones.size():
					var bone_info: Dictionary = skin_data.bones[i]
					var bone_transform: Defs.NIFTransform = bone_info["transform"]
					var inv_bind_nif := bone_transform.to_transform3d()
					var inv_bind_godot := CS.transform_to_godot(inv_bind_nif)
					inv_bind_poses.append(inv_bind_godot)
				else:
					inv_bind_poses.append(Transform3D.IDENTITY)

			# Store metadata on BOTH the MeshInstance3D and the ArrayMesh
			# The ArrayMesh needs it for skin building when body parts are extracted
			mesh_instance.set_meta("bone_names", bone_names)
			mesh_instance.set_meta("inv_bind_poses", inv_bind_poses)
			if mesh:
				mesh.set_meta("bone_names", bone_names)
				mesh.set_meta("inv_bind_poses", inv_bind_poses)

	return mesh_instance

## Convert a Vector3 from NIF coordinates (Z-up) to Godot coordinates (Y-up)
## Delegates to unified CoordinateSystem - outputs in meters
static func _convert_nif_vector3(v: Vector3) -> Vector3:
	return CS.vector_to_godot(v)  # Converts to meters


## Convert a PackedVector3Array from NIF to Godot coordinates
## Delegates to unified CoordinateSystem - outputs in meters
static func _convert_nif_vertices(vertices: PackedVector3Array) -> PackedVector3Array:
	return CS.vectors_to_godot(vertices)  # Converts to meters


## Check if this NIF should generate LODs based on model path
## Generates LODs for: buildings, trees, large rocks, and other complex static objects
func _should_generate_lods() -> bool:
	if _source_path.is_empty():
		return false

	var lower := _source_path.to_lower()

	# Architecture (buildings, structures)
	if "ex_" in lower or "in_" in lower:
		return true

	# Trees and large flora
	if "flora_tree" in lower or "flora_plant" in lower:
		return true

	# Large rocks and terrain features
	if "terrain_rock" in lower:
		# Skip small rocks
		if "small" in lower or "_rm_" in lower:
			return false
		return true

	# Furniture and clutter (larger pieces)
	if "furn_" in lower:
		# Skip small items like plates, cups
		if "de_p" in lower or "misc_" in lower:
			return false
		return true

	# Containers (chests, crates, urns)
	if "contain_" in lower:
		return true

	# Dwemer ruins and Daedric architecture
	if "dwrv_" in lower or "dae_" in lower:
		return true

	return false


## Add VisibilityRange-based LOD system to a MeshInstance3D
## Creates LOD hierarchy by generating simplified meshes and wrapping them in visibility range nodes
func _add_visibility_range_lods(mesh_instance: MeshInstance3D, original_mesh: ArrayMesh) -> void:
	if original_mesh.get_surface_count() == 0:
		return

	var arrays := original_mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return

	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if indices == null or indices.is_empty():
		return

	var num_triangles: int = indices.size() / 3
	if num_triangles < min_triangles_for_lod:
		if debug_lod:
			Logger.debug("nif", "NIFConverter: Skipping LOD for '%s' with %d triangles (min: %d)" % [
				_source_path.get_file(), num_triangles, min_triangles_for_lod
			])
		return

	# visibility_range IS set here at prebake time (see lines below).
	# This ensures LOD nodes have correct ranges when loaded from cache.
	# NativeStreamingManager may also reconfigure at runtime if needed.
	#
	# LOD0 (original mesh): NEAR tier (0-150m)
	# LOD1/2/3: MID tier sub-levels (150-250m, 250-375m, 375-500m)

	if debug_lod:
		Logger.debug("nif", "NIFConverter: Generating %d LOD levels for '%s' (%d triangles)" % [
			lod_levels, _source_path.get_file(), num_triangles
		])

	# Get material to apply to all LOD levels
	# First try material_override, then fall back to surface material
	var material: Material = mesh_instance.material_override
	if material == null and mesh_instance.mesh and mesh_instance.mesh.get_surface_count() > 0:
		material = mesh_instance.mesh.surface_get_material(0)

	# If no material found, try to inherit from parent nodes
	if material == null:
		var parent_node: Node = mesh_instance.get_parent()
		while parent_node and material == null:
			if parent_node is MeshInstance3D:
				var parent_mi := parent_node as MeshInstance3D
				material = parent_mi.material_override
				if material == null and parent_mi.mesh and parent_mi.mesh.get_surface_count() > 0:
					material = parent_mi.mesh.surface_get_material(0)
			parent_node = parent_node.get_parent() if parent_node else null

	# Also try sibling MeshInstance3D nodes (common in NIF files where material is on a sibling)
	if material == null and mesh_instance.get_parent():
		for sibling in mesh_instance.get_parent().get_children():
			if sibling is MeshInstance3D and sibling != mesh_instance:
				var sibling_mi := sibling as MeshInstance3D
				material = sibling_mi.material_override
				if material == null and sibling_mi.mesh and sibling_mi.mesh.get_surface_count() > 0:
					material = sibling_mi.mesh.surface_get_material(0)
				if material:
					break

	if material == null:
		push_warning("NIFConverter: No material found for LOD generation of '%s' - LODs may render white" % _source_path.get_file())

	var simplifier := MeshOptimizer.new()
	var parent := mesh_instance.get_parent()

	# Generate each LOD level
	for lod_idx in range(lod_levels):
		if lod_idx >= lod_reduction_ratios.size():
			break

		var reduction := lod_reduction_ratios[lod_idx]
		var lod_arrays := simplifier.simplify_arrays(arrays, reduction)

		if lod_arrays.is_empty() or lod_arrays[Mesh.ARRAY_VERTEX] == null:
			if debug_lod:
				Logger.debug("nif", "  LOD%d: Failed to generate" % (lod_idx + 1))
			continue

		# Create LOD mesh
		var lod_mesh := ArrayMesh.new()
		lod_mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
		lod_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lod_arrays)

		# Embed material directly in mesh surface (ensures material travels with mesh)
		if material:
			lod_mesh.surface_set_material(0, material)

		# Create LOD mesh instance
		var lod_instance := MeshInstance3D.new()
		lod_instance.name = "%s_LOD%d" % [mesh_instance.name, lod_idx + 1]
		lod_instance.mesh = lod_mesh
		lod_instance.material_override = material

		# Copy transform from original
		lod_instance.transform = mesh_instance.transform

		# Configure visibility_range at prebake time to ensure correct LOD behavior
		# This avoids relying on runtime configuration which may fail during async loading
		# Distance constants from distance_utils.gd:
		#   NEAR_END = 150.0, LOD1_END = 250.0, LOD2_END = 375.0, LOD3_END = 500.0
		#   FADE_MARGIN = 50.0
		lod_instance.visible = true

		# Set visibility_range based on LOD level (lod_idx is 0-based, LOD level is 1-based)
		match lod_idx + 1:
			1:  # LOD1: 150-250m (MID tier, first level)
				lod_instance.visibility_range_begin = 150.0
				lod_instance.visibility_range_end = 250.0
			2:  # LOD2: 250-375m (MID tier, second level)
				lod_instance.visibility_range_begin = 250.0
				lod_instance.visibility_range_end = 375.0
			3:  # LOD3: 375-500m (MID tier, third level)
				lod_instance.visibility_range_begin = 375.0
				lod_instance.visibility_range_end = 500.0
			_:  # Fallback for any additional levels
				lod_instance.visibility_range_begin = 375.0
				lod_instance.visibility_range_end = 500.0

		# Margins for hysteresis (prevents flickering at boundaries)
		lod_instance.visibility_range_begin_margin = 50.0
		lod_instance.visibility_range_end_margin = 50.0
		# FADE_DEPENDENCIES enables smooth crossfade between sibling LOD nodes
		lod_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES

		# Add as sibling to original mesh
		if parent:
			parent.add_child(lod_instance)

		if debug_lod:
			var lod_indices: PackedInt32Array = lod_arrays[Mesh.ARRAY_INDEX]
			var lod_tris: int = lod_indices.size() / 3 if lod_indices else 0
			Logger.debug("nif", "  LOD%d: %d -> %d triangles (%.1f%%), range: %.0f-%.0fm" % [
				lod_idx + 1, num_triangles, lod_tris, 100.0 * lod_tris / num_triangles,
				lod_instance.visibility_range_begin, lod_instance.visibility_range_end
			])

	# Configure the original mesh (LOD0) as NEAR tier (0-150m)
	# This ensures LOD0 is only visible at close range, transitioning to LOD1 at 150m
	mesh_instance.visibility_range_begin = 0.0
	mesh_instance.visibility_range_end = 150.0  # NEAR_END
	mesh_instance.visibility_range_begin_margin = 0.0
	mesh_instance.visibility_range_end_margin = 50.0  # FADE_MARGIN
	mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES

	if debug_lod:
		Logger.debug("nif", "  LOD0 (original): configured for NEAR tier (0-150m)")


## Create ArrayMesh from NiTriShapeData
func _create_tri_shape_mesh(data: Defs.NiTriShapeData) -> ArrayMesh:
	if data.vertices.is_empty() or data.triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Vertices - convert from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	# Normals - convert from NIF to Godot coordinates
	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	# UVs (use first UV set)
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	# Vertex colors
	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	# Indices - flip winding order (NIF uses opposite winding to Godot)
	var flipped_triangles := PackedInt32Array()
	flipped_triangles.resize(data.triangles.size())
	for i in range(0, data.triangles.size(), 3):
		flipped_triangles[i] = data.triangles[i]
		flipped_triangles[i + 1] = data.triangles[i + 2]
		flipped_triangles[i + 2] = data.triangles[i + 1]
	arrays[Mesh.ARRAY_INDEX] = flipped_triangles

	# Create mesh with explicit blend shape count of 0 to avoid AABB errors on duplicate
	var mesh := ArrayMesh.new()
	mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh

## Create ArrayMesh from NiTriStripsData
func _create_tri_strips_mesh(data: Defs.NiTriStripsData) -> ArrayMesh:
	if data.vertices.is_empty() or data.strips.is_empty():
		return null

	# Convert triangle strips to triangle list with flipped winding order
	var triangles := PackedInt32Array()
	for strip in data.strips:
		if strip.size() < 3:
			continue
		# Convert strip to triangles (with flipped winding for Godot)
		for i in range(strip.size() - 2):
			if i % 2 == 0:
				# Even triangles: flip winding (swap indices 1 and 2)
				triangles.append(strip[i])
				triangles.append(strip[i + 2])
				triangles.append(strip[i + 1])
			else:
				# Odd triangles: original strip alternation + flip = normal order
				triangles.append(strip[i])
				triangles.append(strip[i + 1])
				triangles.append(strip[i + 2])

	if triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Convert vertices and normals from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	arrays[Mesh.ARRAY_INDEX] = triangles

	# Create mesh with explicit blend shape count of 0 to avoid AABB errors on duplicate
	var mesh := ArrayMesh.new()
	mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Create skinned ArrayMesh from NiTriShapeData with bone weights
func _create_skinned_tri_shape_mesh(data: Defs.NiTriShapeData, skin_instance: Defs.NiSkinInstance, skin_data: Defs.NiSkinData) -> ArrayMesh:
	if data.vertices.is_empty() or data.triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Vertices - convert from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	# Normals - convert from NIF to Godot coordinates
	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	# UVs (use first UV set)
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	# Vertex colors
	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	# Indices - flip winding order (NIF uses opposite winding to Godot)
	var flipped_triangles := PackedInt32Array()
	flipped_triangles.resize(data.triangles.size())
	for i in range(0, data.triangles.size(), 3):
		flipped_triangles[i] = data.triangles[i]
		flipped_triangles[i + 1] = data.triangles[i + 2]
		flipped_triangles[i + 2] = data.triangles[i + 1]
	arrays[Mesh.ARRAY_INDEX] = flipped_triangles

	# Build bone indices and weights
	var skin_arrays := _skeleton_builder.build_skin_arrays(data, skin_instance, skin_data)
	if not skin_arrays.is_empty():
		# Godot requires PackedInt32Array for bones and PackedFloat32Array for weights
		var indices_arr: PackedInt32Array = skin_arrays["indices"] as PackedInt32Array
		var weights_arr: PackedFloat32Array = skin_arrays["weights"] as PackedFloat32Array

		if indices_arr and weights_arr and indices_arr.size() > 0:
			arrays[Mesh.ARRAY_BONES] = indices_arr
			arrays[Mesh.ARRAY_WEIGHTS] = weights_arr

			if debug_skinning:
				Logger.debug("nif", "  Added bone weights: %d vertices, %d indices, %d weights" % [
					data.num_vertices,
					indices_arr.size(),
					weights_arr.size()
				])

	# Create mesh with explicit blend shape count of 0 to avoid AABB errors on duplicate
	var mesh := ArrayMesh.new()
	mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)

	# Try to add surface - if it fails (e.g., invalid bones array), try without skinning
	var surface_count_before := mesh.get_surface_count()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	if mesh.get_surface_count() == surface_count_before:
		# Surface wasn't added - try without skinning data
		push_warning("NIFConverter: Failed to create skinned mesh surface, trying without skin")
		arrays[Mesh.ARRAY_BONES] = null
		arrays[Mesh.ARRAY_WEIGHTS] = null
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Create skinned ArrayMesh from NiTriStripsData with bone weights
func _create_skinned_tri_strips_mesh(data: Defs.NiTriStripsData, skin_instance: Defs.NiSkinInstance, skin_data: Defs.NiSkinData) -> ArrayMesh:
	if data.vertices.is_empty() or data.strips.is_empty():
		return null

	# Convert triangle strips to triangle list with flipped winding order
	var triangles := PackedInt32Array()
	for strip in data.strips:
		if strip.size() < 3:
			continue
		# Convert strip to triangles (with flipped winding for Godot)
		for i in range(strip.size() - 2):
			if i % 2 == 0:
				# Even triangles: flip winding (swap indices 1 and 2)
				triangles.append(strip[i])
				triangles.append(strip[i + 2])
				triangles.append(strip[i + 1])
			else:
				# Odd triangles: original strip alternation + flip = normal order
				triangles.append(strip[i])
				triangles.append(strip[i + 1])
				triangles.append(strip[i + 2])

	if triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Convert vertices and normals from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	arrays[Mesh.ARRAY_INDEX] = triangles

	# Build bone indices and weights
	var skin_arrays := _skeleton_builder.build_skin_arrays(data, skin_instance, skin_data)
	if not skin_arrays.is_empty():
		# Godot requires PackedInt32Array for bones and PackedFloat32Array for weights
		var indices_arr: PackedInt32Array = skin_arrays["indices"] as PackedInt32Array
		var weights_arr: PackedFloat32Array = skin_arrays["weights"] as PackedFloat32Array

		if indices_arr and weights_arr and indices_arr.size() > 0:
			arrays[Mesh.ARRAY_BONES] = indices_arr
			arrays[Mesh.ARRAY_WEIGHTS] = weights_arr

			if debug_skinning:
				Logger.debug("nif", "  Added bone weights: %d vertices, %d indices, %d weights" % [
					data.num_vertices,
					indices_arr.size(),
					weights_arr.size()
				])

	# Create mesh with explicit blend shape count of 0 to avoid AABB errors on duplicate
	var mesh := ArrayMesh.new()
	mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)

	# Try to add surface - if it fails (e.g., invalid bones array), try without skinning
	var surface_count_before := mesh.get_surface_count()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	if mesh.get_surface_count() == surface_count_before:
		# Surface wasn't added - try without skinning data
		push_warning("NIFConverter: Failed to create skinned strips mesh surface, trying without skin")
		arrays[Mesh.ARRAY_BONES] = null
		arrays[Mesh.ARRAY_WEIGHTS] = null
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Get material for a geometry shape
func _get_material_for_shape(geom: Defs.NiGeometry) -> StandardMaterial3D:
	var mat_prop: Defs.NiMaterialProperty = null
	var tex_prop: Defs.NiTexturingProperty = null
	var alpha_prop: Defs.NiAlphaProperty = null
	var vc_prop: Defs.NiVertexColorProperty = null

	# Collect properties
	for prop_idx in geom.property_indices:
		if prop_idx < 0:
			continue
		var prop := _reader.get_record(prop_idx)
		if prop is Defs.NiMaterialProperty:
			mat_prop = prop
		elif prop is Defs.NiTexturingProperty:
			tex_prop = prop
		elif prop is Defs.NiAlphaProperty:
			alpha_prop = prop
		elif prop is Defs.NiVertexColorProperty:
			vc_prop = prop

	# Check if we have any properties
	if mat_prop == null and tex_prop == null:
		return null

	# Get texture path if available
	var texture_path := ""
	if tex_prop and not tex_prop.textures.is_empty():
		var base_tex := tex_prop.textures[0] if tex_prop.textures.size() > 0 else null
		if base_tex and base_tex.has_texture and base_tex.source_index >= 0:
			var tex_source := _reader.get_record(base_tex.source_index)
			if tex_source is Defs.NiSourceTexture:
				var source := tex_source as Defs.NiSourceTexture
				texture_path = source.filename

	# Use MaterialLibrary for deduplication if enabled
	if use_material_library and load_textures:
		var props := MatLib.MaterialProperties.new()

		# Texture
		props.texture_path = texture_path

		# Material properties
		if mat_prop:
			props.albedo_color = mat_prop.diffuse
			props.specular = mat_prop.glossiness / 128.0
			props.roughness = 1.0 - props.specular
			if mat_prop.emissive.r > 0.01 or mat_prop.emissive.g > 0.01 or mat_prop.emissive.b > 0.01:
				props.has_emission = true
				props.emission_color = mat_prop.emissive
				props.emission_energy = 1.0

		# Alpha properties
		if alpha_prop:
			if alpha_prop.test_enabled():
				props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				props.alpha_scissor_threshold = alpha_prop.threshold / 255.0
			elif alpha_prop.blend_enabled():
				props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA

		# Vertex colors
		if vc_prop:
			props.use_vertex_colors = true

		return MatLib.get_or_create_material(props)

	# Fallback: Create new material (legacy behavior)
	var material := StandardMaterial3D.new()

	# Texture filtering - critical for visual quality at distance
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	# Apply material properties
	if mat_prop:
		material.albedo_color = mat_prop.diffuse
		material.emission = mat_prop.emissive
		material.emission_enabled = mat_prop.emissive.r > 0 or mat_prop.emissive.g > 0 or mat_prop.emissive.b > 0
		material.metallic_specular = mat_prop.glossiness / 128.0  # Normalize

	# Apply alpha property
	if alpha_prop:
		if alpha_prop.blend_enabled():
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if alpha_prop.test_enabled():
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			material.alpha_scissor_threshold = alpha_prop.threshold / 255.0

	# Apply vertex colors
	if vc_prop:
		material.vertex_color_use_as_albedo = true

	# Texture loading
	if not texture_path.is_empty():
		if load_textures:
			var texture := TexLoader.load_texture(texture_path)
			if texture:
				material.albedo_texture = texture
		else:
			# Store texture path in metadata for later loading
			material.set_meta("texture_path", texture_path)

	return material

## Get texture paths referenced by this NIF
func get_texture_paths() -> Array[String]:
	var paths: Array[String] = []

	for record: Defs.NIFRecord in _reader.records:
		if record is Defs.NiSourceTexture:
			var tex := record as Defs.NiSourceTexture
			if tex.is_external and not tex.filename.is_empty():
				# Normalize path
				var path := tex.filename.replace("\\", "/").to_lower()
				if path not in paths:
					paths.append(path)

	return paths

## Get basic mesh info without full conversion
func get_mesh_info() -> Dictionary:
	var info := {
		"version": _reader.get_version_string(),
		"num_records": _reader.get_num_records(),
		"num_roots": _reader.roots.size(),
		"nodes": 0,
		"meshes": 0,
		"total_vertices": 0,
		"total_triangles": 0,
		"textures": [],
		"has_animations": _has_animation_data(),
		"has_skinning": _has_skinning_data()
	}

	for record: Defs.NIFRecord in _reader.records:
		if record is Defs.NiNode:
			info["nodes"] += 1
		elif record is Defs.NiTriShape or record is Defs.NiTriStrips:
			info["meshes"] += 1
		elif record is Defs.NiTriShapeData:
			var data := record as Defs.NiTriShapeData
			info["total_vertices"] += data.num_vertices
			info["total_triangles"] += data.num_triangles
		elif record is Defs.NiTriStripsData:
			var data := record as Defs.NiTriStripsData
			info["total_vertices"] += data.num_vertices
			info["total_triangles"] += data.num_triangles
		elif record is Defs.NiSourceTexture:
			var tex := record as Defs.NiSourceTexture
			if tex.is_external and tex.filename:
				var textures_arr: Array = info["textures"]
				textures_arr.append(tex.filename)

	return info


## Check if this NIF has any animation data (keyframe controllers)
func _has_animation_data() -> bool:
	for record: Defs.NIFRecord in _reader.records:
		if record is Defs.NiKeyframeController:
			return true
	return false


## Create AnimationPlayer with animations extracted from NIF
func _create_animation_player(skeleton: Skeleton3D) -> AnimationPlayer:
	# Initialize animation converter
	_animation_converter = AnimationConverter.new()
	_animation_converter.init(_reader, skeleton)
	_animation_converter.debug_mode = debug_animations

	# Try to extract animations by text keys first (named animations)
	var animations := _animation_converter.convert_to_animations_by_text_keys()

	if animations.is_empty():
		# No text keys or animations found
		return null

	# Create AnimationPlayer and AnimationLibrary
	var anim_player := AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"

	var library := AnimationLibrary.new()

	for anim_name: String in animations:
		var anim: Animation = animations[anim_name]
		if anim:
			var err := library.add_animation(StringName(anim_name), anim)
			if err != OK:
				push_warning("NIFConverter: Failed to add animation '%s': %s" % [anim_name, error_string(err)])
			elif debug_animations:
				Logger.debug("nif", "  Added animation '%s' (%.2fs, %d tracks)" % [
					anim_name, anim.length, anim.get_track_count()
				])

	# Add library to player (empty string for default library)
	var lib_err := anim_player.add_animation_library("", library)
	if lib_err != OK:
		push_warning("NIFConverter: Failed to add animation library: %s" % error_string(lib_err))
		return null

	return anim_player


## Get animation info without full conversion
func get_animation_info() -> Dictionary:
	var info := {
		"has_animations": false,
		"controller_count": 0,
		"text_keys": [],
		"animation_names": []
	}

	for record: Defs.NIFRecord in _reader.records:
		if record is Defs.NiKeyframeController:
			info["has_animations"] = true
			info["controller_count"] += 1
		elif record is Defs.NiTextKeyExtraData:
			var text_key := record as Defs.NiTextKeyExtraData
			for key: Dictionary in text_key.keys:
				var text_keys_arr: Array = info["text_keys"]
				text_keys_arr.append({
					"time": key["time"],
					"name": key["value"]
				})

	# Parse animation names from text keys
	var seen_names := {}
	var text_keys_list: Array = info["text_keys"]
	for key: Dictionary in text_keys_list:
		var key_name: String = key["name"]
		var parts: PackedStringArray = key_name.split(":")
		if parts.size() >= 2:
			var anim_name := parts[0].strip_edges()
			if anim_name not in seen_names:
				seen_names[anim_name] = true
				var anim_names_arr: Array = info["animation_names"]
				anim_names_arr.append(anim_name)

	return info


## Get collision info without full conversion
func get_collision_info() -> Dictionary:
	var info := {
		"has_collision": false,
		"has_root_collision_node": false,
		"has_actor_collision_box": false,
		"collision_shape_count": 0,
		"collision_mode": "auto_primitive",
		"detected_shapes": [],
		"shape_types": [],
		"bounding_volumes": [],
		"visual_collision_type": "default"  # "default", "camera", "none"
	}

	if _reader == null:
		return info

	# Initialize collision builder if needed
	if _collision_builder == null:
		_collision_builder = CollisionBuilder.new()
		_collision_builder.init(_reader)
		_collision_builder.detection_tolerance = collision_detection_tolerance
		if auto_collision_mode and not _source_path.is_empty():
			_collision_builder.collision_mode = CollisionBuilder.get_recommended_mode(_source_path)
		else:
			_collision_builder.collision_mode = collision_mode

	var result := _collision_builder.build_collision()

	info["has_collision"] = result.has_collision
	info["has_root_collision_node"] = result.root_collision_node_index >= 0
	info["has_actor_collision_box"] = result.has_actor_collision_box
	info["collision_shape_count"] = result.collision_shapes.size()
	info["detected_shapes"] = result.detected_shapes

	# Report collision mode used
	match _collision_builder.collision_mode:
		CollisionBuilder.CollisionMode.TRIMESH:
			info["collision_mode"] = "trimesh"
		CollisionBuilder.CollisionMode.CONVEX:
			info["collision_mode"] = "convex"
		CollisionBuilder.CollisionMode.AUTO_PRIMITIVE:
			info["collision_mode"] = "auto_primitive"
		CollisionBuilder.CollisionMode.PRIMITIVE_ONLY:
			info["collision_mode"] = "primitive_only"

	# Collect shape types from result
	for shape_data: Dictionary in result.collision_shapes:
		if shape_data.has("type"):
			var shape_types_arr: Array = info["shape_types"]
			shape_types_arr.append(shape_data["type"])

	if result.has_actor_collision_box:
		info["actor_collision"] = {
			"center": result.bounding_box_center,
			"extents": result.bounding_box_extents
		}

	match result.visual_collision_type:
		0:
			info["visual_collision_type"] = "default"
		1:
			info["visual_collision_type"] = "camera"

	# Collect bounding volume types from the NIF
	for record: Defs.NIFRecord in _reader.records:
		if record is Defs.NiAVObject:
			var av_obj := record as Defs.NiAVObject
			if av_obj.has_bounding_volume and av_obj.bounding_volume != null:
				var bv_info := {
					"node_name": av_obj.name,
					"type": _bv_type_to_string(av_obj.bounding_volume.type)
				}
				var bv_arr: Array = info["bounding_volumes"]
				bv_arr.append(bv_info)

	return info


## Convert bounding volume type to string
func _bv_type_to_string(bv_type: int) -> String:
	match bv_type:
		Defs.BV_BASE:
			return "base"
		Defs.BV_SPHERE:
			return "sphere"
		Defs.BV_BOX:
			return "box"
		Defs.BV_CAPSULE:
			return "capsule"
		Defs.BV_LOZENGE:
			return "lozenge"
		Defs.BV_UNION:
			return "union"
		Defs.BV_HALFSPACE:
			return "halfspace"
		_:
			return "unknown"


# =============================================================================
# PARTICLE CONVERSION
# =============================================================================

## Convert NiParticles to a GPUParticles3D node
## This handles NiParticles, NiAutoNormalParticles, and NiRotatingParticles
func _convert_ni_particles(particles: Defs.NiParticles) -> Node3D:
	var node := GPUParticles3D.new()
	node.name = particles.name if particles.name else "Particles_%d" % particles.record_index

	# Apply transform
	var nif_transform := particles.transform.to_transform3d()
	node.transform = _convert_nif_transform(nif_transform)

	# Get particle data
	var particles_data: Defs.NiParticlesData = null
	if particles.data_index >= 0 and particles.data_index < _reader.records.size():
		var data_record: Defs.NIFRecord = _reader.records[particles.data_index]
		if data_record is Defs.NiParticlesData:
			particles_data = data_record as Defs.NiParticlesData

	# Create process material for particle behavior
	var material := ParticleProcessMaterial.new()

	# Look for particle system controller to get emission parameters
	var controller: Defs.NiParticleSystemController = null
	if particles.controller_index >= 0:
		controller = _find_particle_controller(particles.controller_index)

	if controller:
		# Set emission parameters from controller
		material.initial_velocity_min = controller.speed - controller.speed_variation
		material.initial_velocity_max = controller.speed + controller.speed_variation

		# Convert direction (declination is angle from up vector)
		var direction := controller.initial_normal.normalized()
		material.direction = CS.vector_to_godot(direction, false)  # Direction, no scale
		material.spread = rad_to_deg(controller.declination_variation) * 2.0

		# Lifetime
		node.lifetime = controller.lifetime if controller.lifetime > 0 else 1.0

		# Emission timing
		if controller.birth_rate > 0:
			node.amount = int(controller.birth_rate * node.lifetime)
		else:
			node.amount = 8  # Default

		# Emitter shape (box emitter if dimensions are set)
		if controller.emitter_dimensions.length() > 0.001:
			var extents: Vector3 = CS.vector_to_godot(controller.emitter_dimensions) * 0.5
			material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			material.emission_box_extents = extents.abs()
		else:
			material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT

		# Initial color
		material.color = controller.initial_color

		# Look for particle modifiers (gravity, grow/fade, color)
		_apply_particle_modifiers(controller, material, node)
	else:
		# Default particle settings
		node.amount = 8
		node.lifetime = 1.0
		material.direction = Vector3.UP
		material.initial_velocity_min = 1.0
		material.initial_velocity_max = 2.0

	# Set particle size from data
	if particles_data:
		var base_size: float = particles_data.particle_radius * CS.SCALE_FACTOR
		if base_size > 0:
			material.scale_min = base_size
			material.scale_max = base_size

		# If we have vertex colors in the particle data, use the first one
		if particles_data.colors.size() > 0:
			material.color = particles_data.colors[0]

	node.process_material = material

	# Create a simple quad mesh for particles (billboard)
	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(0.1, 0.1)  # Will be scaled by material
	node.draw_pass_1 = quad_mesh

	# Look for texturing property for particle texture
	var tex_material := _get_particle_texture_material(particles)
	if tex_material:
		quad_mesh.material = tex_material

	# Set billboard mode
	var draw_material := quad_mesh.material
	if draw_material == null:
		draw_material = StandardMaterial3D.new()
		quad_mesh.material = draw_material
	if draw_material is StandardMaterial3D:
		var std_mat := draw_material as StandardMaterial3D
		std_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		std_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# Store metadata
	node.set_meta("nif_record_type", particles.record_type)
	node.set_meta("nif_record_index", particles.record_index)

	return node


## Find particle system controller in controller chain
func _find_particle_controller(controller_index: int) -> Defs.NiParticleSystemController:
	var current_index := controller_index
	while current_index >= 0 and current_index < _reader.records.size():
		var record: Defs.NIFRecord = _reader.records[current_index]
		if record is Defs.NiParticleSystemController:
			return record as Defs.NiParticleSystemController
		elif record is Defs.NiTimeController:
			current_index = (record as Defs.NiTimeController).next_controller_index
		else:
			break
	return null


## Apply particle modifiers (gravity, grow/fade, color, rotation, colliders) to the particle material
func _apply_particle_modifiers(controller: Defs.NiParticleSystemController, material: ParticleProcessMaterial, node: GPUParticles3D) -> void:
	# The controller has references to modifiers through extra data chain
	# For now, look through all records for modifiers that might apply
	for record: Defs.NIFRecord in _reader.records:
		if record is Defs.NiGravity:
			_apply_gravity_modifier(record as Defs.NiGravity, material)
		elif record is Defs.NiParticleGrowFade:
			_apply_grow_fade_modifier(record as Defs.NiParticleGrowFade, material, node)
		elif record is Defs.NiParticleColorModifier:
			_apply_color_modifier(record as Defs.NiParticleColorModifier, material, node)
		elif record is Defs.NiParticleRotation:
			_apply_rotation_modifier(record as Defs.NiParticleRotation, material)
		elif record is Defs.NiPlanarCollider:
			_apply_planar_collider(record as Defs.NiPlanarCollider, node)
		elif record is Defs.NiSphericalCollider:
			_apply_spherical_collider(record as Defs.NiSphericalCollider, node)
		elif record is Defs.NiParticleBomb:
			_apply_particle_bomb(record as Defs.NiParticleBomb, material, node)


## Apply NiGravity modifier to particle material
func _apply_gravity_modifier(gravity: Defs.NiGravity, material: ParticleProcessMaterial) -> void:
	var gravity_dir: Vector3 = CS.vector_to_godot(gravity.direction, false)  # Direction, no scale
	material.gravity = gravity_dir * gravity.force * CS.SCALE_FACTOR


## Apply NiParticleGrowFade modifier to particle material
func _apply_grow_fade_modifier(grow_fade: Defs.NiParticleGrowFade, material: ParticleProcessMaterial, node: GPUParticles3D) -> void:
	if grow_fade.grow_time > 0 or grow_fade.fade_time > 0:
		var curve := Curve.new()
		var grow_t := grow_fade.grow_time / node.lifetime if node.lifetime > 0 else 0.0
		var fade_t := 1.0 - (grow_fade.fade_time / node.lifetime if node.lifetime > 0 else 0.0)

		curve.add_point(Vector2(0.0, 0.0))
		if grow_t > 0:
			curve.add_point(Vector2(grow_t, 1.0))
		else:
			curve.set_point_value(0, 1.0)
		if fade_t < 1.0:
			curve.add_point(Vector2(fade_t, 1.0))
		curve.add_point(Vector2(1.0, 0.0))

		var curve_tex := CurveTexture.new()
		curve_tex.curve = curve
		material.scale_curve = curve_tex


## Apply NiParticleColorModifier to particle material (color gradient over lifetime)
func _apply_color_modifier(color_mod: Defs.NiParticleColorModifier, material: ParticleProcessMaterial, node: GPUParticles3D) -> void:
	if color_mod.color_data_index < 0 or color_mod.color_data_index >= _reader.records.size():
		return

	var color_data: Defs.NIFRecord = _reader.records[color_mod.color_data_index]
	if not color_data is Defs.NiColorData:
		return

	var ni_color_data := color_data as Defs.NiColorData
	if ni_color_data.keys.size() == 0:
		return

	# Find the time range of the keys
	var first_key: Dictionary = ni_color_data.keys[0]
	var last_key: Dictionary = ni_color_data.keys[-1]
	var min_time: float = first_key["time"]
	var max_time: float = last_key["time"]
	var time_range := max_time - min_time

	# If time range is zero or keys use absolute times greater than lifetime,
	# normalize based on particle lifetime
	if time_range <= 0.001:
		time_range = node.lifetime if node.lifetime > 0 else 1.0
		min_time = 0.0

	# Build arrays for gradient
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()

	for key: Dictionary in ni_color_data.keys:
		var t: float = (key["time"] - min_time) / time_range if time_range > 0 else 0.0
		t = clampf(t, 0.0, 1.0)
		var color: Color = key["value"]
		offsets.append(t)
		colors.append(color)

	# Create gradient with our data (this replaces the default points)
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors

	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	material.color_ramp = gradient_tex


## Apply NiParticleRotation modifier to particle material (spinning particles)
func _apply_rotation_modifier(rotation: Defs.NiParticleRotation, material: ParticleProcessMaterial) -> void:
	# Convert rotation speed from radians/sec to degrees for Godot
	var rotation_speed_deg := rad_to_deg(rotation.rotation_speed)

	# Set angular velocity (Godot uses degrees)
	material.angular_velocity_min = rotation_speed_deg
	material.angular_velocity_max = rotation_speed_deg

	# If random initial axis, add some randomness to the rotation
	if rotation.random_initial_axis:
		material.angular_velocity_min = -abs(rotation_speed_deg)
		material.angular_velocity_max = abs(rotation_speed_deg)


## Apply NiPlanarCollider to particle system
## Note: Godot's GPUParticles3D doesn't have built-in collision, so we store metadata
## and create a collision attractor that can approximate the behavior
func _apply_planar_collider(collider: Defs.NiPlanarCollider, node: GPUParticles3D) -> void:
	# Store collider info as metadata for potential runtime use
	var plane_normal: Vector3 = CS.vector_to_godot(collider.plane_normal, false)
	var plane_distance: float = collider.plane_distance * CS.SCALE_FACTOR

	node.set_meta("particle_planar_collider", {
		"normal": plane_normal,
		"distance": plane_distance,
		"bounce": collider.bounce
	})

	# Create a GPUParticlesCollisionSDF or GPUParticlesAttractorBox to approximate
	# For now, we'll use an attractor to push particles away from the plane
	# This is an approximation since Godot doesn't have exact plane colliders for GPU particles
	var attractor := GPUParticlesAttractorBox3D.new()
	attractor.name = "PlaneCollider"

	# Position the attractor at the plane
	attractor.position = plane_normal * plane_distance

	# Make it a thin box aligned with the plane
	# The attractor will push particles away when they get close
	attractor.size = Vector3(100.0, 0.1, 100.0)  # Large thin plane

	# Negative strength pushes particles away (bounce effect)
	attractor.strength = -collider.bounce * 10.0

	# Orient the box to align with the plane normal
	if plane_normal != Vector3.UP and plane_normal != Vector3.DOWN:
		attractor.look_at(attractor.position + plane_normal)

	node.add_child(attractor)


## Apply NiSphericalCollider to particle system
func _apply_spherical_collider(collider: Defs.NiSphericalCollider, node: GPUParticles3D) -> void:
	# Store collider info as metadata
	var center: Vector3 = CS.vector_to_godot(collider.center)
	var radius: float = collider.radius * CS.SCALE_FACTOR

	node.set_meta("particle_spherical_collider", {
		"center": center,
		"radius": radius,
		"bounce": collider.bounce
	})

	# Create a spherical attractor to approximate collision behavior
	var attractor := GPUParticlesAttractorSphere3D.new()
	attractor.name = "SphereCollider"
	attractor.position = center
	attractor.radius = radius

	# Negative strength pushes particles away (bounce effect)
	attractor.strength = -collider.bounce * 10.0

	node.add_child(attractor)


## Apply NiParticleBomb modifier (explosion/force effect)
## This creates a radial or directional force that affects particles
func _apply_particle_bomb(bomb: Defs.NiParticleBomb, material: ParticleProcessMaterial, node: GPUParticles3D) -> void:
	# Store bomb info as metadata for potential runtime use
	var position: Vector3 = CS.vector_to_godot(bomb.position)
	var direction: Vector3 = CS.vector_to_godot(bomb.direction, false)

	node.set_meta("particle_bomb", {
		"position": position,
		"direction": direction,
		"decay": bomb.decay,
		"duration": bomb.duration,
		"delta_v": bomb.delta_v * CS.SCALE_FACTOR,
		"start_time": bomb.start_time,
		"decay_type": bomb.decay_type,
		"symmetry_type": bomb.symmetry_type
	})

	# Create an attractor to simulate the bomb effect
	# Symmetry type: 0=spherical, 1=cylindrical, 2=planar
	match bomb.symmetry_type:
		0:  # Spherical - use sphere attractor
			var attractor := GPUParticlesAttractorSphere3D.new()
			attractor.name = "ParticleBomb"
			attractor.position = position
			attractor.radius = bomb.delta_v * CS.SCALE_FACTOR * 10.0  # Estimate radius from force
			attractor.strength = bomb.delta_v * CS.SCALE_FACTOR
			node.add_child(attractor)
		1, 2:  # Cylindrical or Planar - use box attractor aligned with direction
			var attractor := GPUParticlesAttractorBox3D.new()
			attractor.name = "ParticleBomb"
			attractor.position = position
			attractor.size = Vector3(10.0, 10.0, 10.0)  # Large area
			attractor.strength = bomb.delta_v * CS.SCALE_FACTOR
			if direction != Vector3.ZERO:
				attractor.look_at(attractor.position + direction)
			node.add_child(attractor)


## Get texture material for particles from NiTexturingProperty
func _get_particle_texture_material(particles: Defs.NiParticles) -> Material:
	for prop_index: int in particles.property_indices:
		if prop_index < 0 or prop_index >= _reader.records.size():
			continue
		var prop: Defs.NIFRecord = _reader.records[prop_index]
		if prop is Defs.NiTexturingProperty:
			var tex_prop := prop as Defs.NiTexturingProperty
			if tex_prop.textures.size() > 0 and tex_prop.textures[0].has_texture:
				var tex_desc := tex_prop.textures[0]
				if tex_desc.source_index >= 0 and tex_desc.source_index < _reader.records.size():
					var source: Defs.NIFRecord = _reader.records[tex_desc.source_index]
					if source is Defs.NiSourceTexture:
						var source_tex := source as Defs.NiSourceTexture
						if source_tex.is_external and source_tex.filename:
							var mat := StandardMaterial3D.new()
							mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
							mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
							# Store texture path for later loading
							mat.set_meta("nif_texture_path", source_tex.filename)
							return mat
	return null


# =============================================================================
# LIGHT CONVERSION
# =============================================================================

## Convert NiLight (ambient/directional) to Godot light
func _convert_ni_light(light: Defs.NiLight) -> Node3D:
	# Check record type for specific light type
	if light.record_type == Defs.RT_NI_AMBIENT_LIGHT:
		# Godot doesn't have an ambient light node, store as metadata on a Node3D
		var node := Node3D.new()
		node.name = light.name if light.name else "AmbientLight_%d" % light.record_index

		var nif_transform := light.transform.to_transform3d()
		node.transform = _convert_nif_transform(nif_transform)

		node.set_meta("nif_record_type", light.record_type)
		node.set_meta("nif_light_type", "ambient")
		node.set_meta("nif_ambient_color", light.ambient_color)
		node.set_meta("nif_dimmer", light.dimmer)

		return node
	elif light.record_type == Defs.RT_NI_DIRECTIONAL_LIGHT:
		var dir_light := DirectionalLight3D.new()
		dir_light.name = light.name if light.name else "DirectionalLight_%d" % light.record_index

		var nif_transform := light.transform.to_transform3d()
		dir_light.transform = _convert_nif_transform(nif_transform)

		# Use diffuse color as light color
		dir_light.light_color = Color(light.diffuse_color.r, light.diffuse_color.g, light.diffuse_color.b)
		dir_light.light_energy = light.dimmer

		dir_light.set_meta("nif_record_type", light.record_type)
		dir_light.set_meta("nif_record_index", light.record_index)

		return dir_light

	# Fallback for base NiLight
	var node := Node3D.new()
	node.name = light.name if light.name else "Light_%d" % light.record_index
	node.set_meta("nif_record_type", light.record_type)
	return node


## Convert NiPointLight to OmniLight3D
func _convert_ni_point_light(light: Defs.NiPointLight) -> OmniLight3D:
	var omni_light := OmniLight3D.new()
	omni_light.name = light.name if light.name else "PointLight_%d" % light.record_index

	var nif_transform := light.transform.to_transform3d()
	omni_light.transform = _convert_nif_transform(nif_transform)

	# Use diffuse color as light color
	omni_light.light_color = Color(light.diffuse_color.r, light.diffuse_color.g, light.diffuse_color.b)
	omni_light.light_energy = light.dimmer

	# Calculate range from attenuation
	# NIF uses: attenuation = 1 / (constant + linear*d + quadratic*d^2)
	# We need to estimate a reasonable range
	var range := _calculate_light_range(light.constant_atten, light.linear_atten, light.quadratic_atten)
	omni_light.omni_range = range * CS.SCALE_FACTOR

	# Set attenuation curve (Godot uses inverse square by default which is close)
	if light.quadratic_atten > 0:
		omni_light.omni_attenuation = 1.0  # Quadratic falloff
	elif light.linear_atten > 0:
		omni_light.omni_attenuation = 0.5  # Linear-ish falloff
	else:
		omni_light.omni_attenuation = 0.0  # Constant (no falloff)

	omni_light.set_meta("nif_record_type", light.record_type)
	omni_light.set_meta("nif_record_index", light.record_index)
	omni_light.set_meta("nif_constant_atten", light.constant_atten)
	omni_light.set_meta("nif_linear_atten", light.linear_atten)
	omni_light.set_meta("nif_quadratic_atten", light.quadratic_atten)

	return omni_light


## Convert NiSpotLight to SpotLight3D
func _convert_ni_spot_light(light: Defs.NiSpotLight) -> SpotLight3D:
	var spot_light := SpotLight3D.new()
	spot_light.name = light.name if light.name else "SpotLight_%d" % light.record_index

	var nif_transform := light.transform.to_transform3d()
	spot_light.transform = _convert_nif_transform(nif_transform)

	# Use diffuse color as light color
	spot_light.light_color = Color(light.diffuse_color.r, light.diffuse_color.g, light.diffuse_color.b)
	spot_light.light_energy = light.dimmer

	# Calculate range from attenuation
	var range := _calculate_light_range(light.constant_atten, light.linear_atten, light.quadratic_atten)
	spot_light.spot_range = range * CS.SCALE_FACTOR

	# Spot angle (NIF uses outer angle, Godot uses half-angle)
	spot_light.spot_angle = rad_to_deg(light.outer_spot_angle)

	# Spot attenuation based on inner/outer angle difference
	if light.outer_spot_angle > 0 and light.inner_spot_angle > 0:
		var angle_ratio := light.inner_spot_angle / light.outer_spot_angle
		spot_light.spot_angle_attenuation = 1.0 - angle_ratio
	else:
		spot_light.spot_angle_attenuation = 1.0

	# Distance attenuation
	if light.quadratic_atten > 0:
		spot_light.spot_attenuation = 1.0
	elif light.linear_atten > 0:
		spot_light.spot_attenuation = 0.5
	else:
		spot_light.spot_attenuation = 0.0

	spot_light.set_meta("nif_record_type", light.record_type)
	spot_light.set_meta("nif_record_index", light.record_index)
	spot_light.set_meta("nif_outer_spot_angle", light.outer_spot_angle)
	spot_light.set_meta("nif_inner_spot_angle", light.inner_spot_angle)
	spot_light.set_meta("nif_exponent", light.exponent)

	return spot_light


## Calculate effective light range from NIF attenuation parameters
## Returns range in NIF units
func _calculate_light_range(constant: float, linear: float, quadratic: float) -> float:
	# Find distance where light intensity drops to ~1% (0.01)
	# attenuation = 1 / (c + l*d + q*d^2)
	# We want: 1 / (c + l*d + q*d^2) = 0.01
	# So: c + l*d + q*d^2 = 100

	if quadratic > 0.0001:
		# Solve quadratic: q*d^2 + l*d + (c - 100) = 0
		var a := quadratic
		var b := linear
		var c := constant - 100.0
		var discriminant := b * b - 4.0 * a * c
		if discriminant >= 0:
			return (-b + sqrt(discriminant)) / (2.0 * a)
	elif linear > 0.0001:
		# Linear case: l*d = 100 - c
		return (100.0 - constant) / linear

	# Default range if no attenuation (or constant only)
	return 500.0  # 500 NIF units


# =============================================================================
# LOD AND SWITCH NODE CONVERSION
# =============================================================================

## Recursively apply visibility range to all GeometryInstance3D nodes in a subtree
func _apply_visibility_range(node: Node, begin: float, end: float) -> void:
	if node is GeometryInstance3D:
		var geo_node := node as GeometryInstance3D
		geo_node.visibility_range_begin = begin
		geo_node.visibility_range_end = end
		geo_node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	for child: Node in node.get_children():
		_apply_visibility_range(child, begin, end)


## Convert NiLODNode to Node3D with LOD metadata
func _convert_ni_lod_node(lod_node: Defs.NiLODNode, skeleton: Skeleton3D = null) -> Node3D:
	var node := Node3D.new()
	node.name = lod_node.name if lod_node.name else "LODNode_%d" % lod_node.record_index

	# Apply transform
	var nif_transform := lod_node.transform.to_transform3d()
	node.transform = _convert_nif_transform(nif_transform)

	# Store LOD data as metadata
	node.set_meta("nif_record_type", lod_node.record_type)
	node.set_meta("nif_record_index", lod_node.record_index)
	node.set_meta("nif_lod_center", CS.vector_to_godot(lod_node.lod_center))

	# Convert LOD levels (convert distances to meters)
	var converted_levels: Array = []
	for level: Dictionary in lod_node.lod_levels:
		var min_range_val: float = level.get("min_range", 0.0)
		var max_range_val: float = level.get("max_range", 0.0)
		converted_levels.append({
			"min_range": min_range_val * CS.SCALE_FACTOR,
			"max_range": max_range_val * CS.SCALE_FACTOR
		})
	node.set_meta("nif_lod_levels", converted_levels)

	# Convert children
	for child_index: int in lod_node.children_indices:
		if child_index < 0 or child_index >= _reader.records.size():
			continue
		var child_record: Defs.NIFRecord = _reader.records[child_index]
		var child_node := _convert_record(child_record, skeleton)
		if child_node:
			node.add_child(child_node)
			# Store LOD level index on child
			var lod_index := lod_node.children_indices.find(child_index)
			child_node.set_meta("nif_lod_level", lod_index)

	# Apply Godot visibility ranges to each LOD level
	for i: int in node.get_child_count():
		var child: Node = node.get_child(i)
		var lod_index: int = child.get_meta("nif_lod_level", -1)
		if lod_index < 0 or lod_index >= converted_levels.size():
			continue

		# Calculate visibility range for this LOD level
		var begin: float = 0.0
		var level_dict: Dictionary = converted_levels[lod_index]
		var end: float = level_dict["max_range"]

		# LOD levels after 0 start where the previous one ends
		if lod_index > 0:
			var prev_level_dict: Dictionary = converted_levels[lod_index - 1]
			begin = prev_level_dict["max_range"]

		# Last LOD level extends to infinity (0 = no limit in Godot)
		if lod_index == converted_levels.size() - 1:
			end = 0.0

		_apply_visibility_range(child, begin, end)

	return node


## Convert NiSwitchNode to Node3D with switch metadata
func _convert_ni_switch_node(switch_node: Defs.NiSwitchNode, skeleton: Skeleton3D = null) -> Node3D:
	var node := Node3D.new()
	node.name = switch_node.name if switch_node.name else "SwitchNode_%d" % switch_node.record_index

	# Apply transform
	var nif_transform := switch_node.transform.to_transform3d()
	node.transform = _convert_nif_transform(nif_transform)

	# Store switch data as metadata
	node.set_meta("nif_record_type", switch_node.record_type)
	node.set_meta("nif_record_index", switch_node.record_index)
	node.set_meta("nif_switch_flags", switch_node.switch_flags)
	node.set_meta("nif_initial_index", switch_node.initial_index)

	# Convert children
	var child_index_counter := 0
	for child_index: int in switch_node.children_indices:
		if child_index < 0 or child_index >= _reader.records.size():
			child_index_counter += 1
			continue
		var child_record: Defs.NIFRecord = _reader.records[child_index]
		var child_node := _convert_record(child_record, skeleton)
		if child_node:
			node.add_child(child_node)
			# Store switch index on child
			child_node.set_meta("nif_switch_index", child_index_counter)
			# Hide all children except the initial one
			if child_index_counter != switch_node.initial_index:
				child_node.visible = false
		child_index_counter += 1

	return node


# =============================================================================
# MATERIAL MERGING - Reduces draw calls by combining meshes with same material
# =============================================================================

## Collected geometry data for merging
## Stores geometry arrays + world transform + material key for later merging
class CollectedGeometry:
	var arrays: Array = []  # Mesh arrays (ARRAY_VERTEX, ARRAY_NORMAL, etc.)
	var world_transform: Transform3D = Transform3D.IDENTITY
	var material_key: String = ""
	var material: StandardMaterial3D = null
	var is_hidden: bool = false
	var has_skinning: bool = false  # Skip skinned meshes from merging


## Check if merging should be used for this conversion
func _should_merge_by_material() -> bool:
	if not merge_by_material:
		return false
	# Don't merge skinned meshes
	if _has_skinning_data():
		return false
	return true


## Get material key for a geometry shape (used for grouping)
func _get_material_key_for_shape(geom: Defs.NiGeometry) -> String:
	var mat_prop: Defs.NiMaterialProperty = null
	var tex_prop: Defs.NiTexturingProperty = null
	var alpha_prop: Defs.NiAlphaProperty = null
	var vc_prop: Defs.NiVertexColorProperty = null

	for prop_idx in geom.property_indices:
		if prop_idx < 0:
			continue
		var prop := _reader.get_record(prop_idx)
		if prop is Defs.NiMaterialProperty:
			mat_prop = prop
		elif prop is Defs.NiTexturingProperty:
			tex_prop = prop
		elif prop is Defs.NiAlphaProperty:
			alpha_prop = prop
		elif prop is Defs.NiVertexColorProperty:
			vc_prop = prop

	# Build material key using same logic as MaterialLibrary
	var props := MatLib.MaterialProperties.new()

	# Get texture path
	if tex_prop and not tex_prop.textures.is_empty():
		var base_tex := tex_prop.textures[0] if tex_prop.textures.size() > 0 else null
		if base_tex and base_tex.has_texture and base_tex.source_index >= 0:
			var tex_source := _reader.get_record(base_tex.source_index)
			if tex_source is Defs.NiSourceTexture:
				props.texture_path = (tex_source as Defs.NiSourceTexture).filename

	if mat_prop:
		props.albedo_color = mat_prop.diffuse
		props.specular = mat_prop.glossiness / 128.0
		props.roughness = 1.0 - props.specular
		if mat_prop.emissive.r > 0.01 or mat_prop.emissive.g > 0.01 or mat_prop.emissive.b > 0.01:
			props.has_emission = true
			props.emission_color = mat_prop.emissive

	if alpha_prop:
		if alpha_prop.test_enabled():
			props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			props.alpha_scissor_threshold = alpha_prop.threshold / 255.0
		elif alpha_prop.blend_enabled():
			props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA

	if vc_prop:
		props.use_vertex_colors = true

	return props.get_key()


## Collect all geometry from the NIF into groups by material
## Returns Dictionary[material_key -> Array[CollectedGeometry]]
func _collect_geometry_by_material() -> Dictionary:
	var collected: Dictionary = {}  # material_key -> Array[CollectedGeometry]

	for root_idx: int in _reader.roots:
		var record := _reader.get_record(root_idx)
		if record:
			_collect_geometry_recursive(record, Transform3D.IDENTITY, collected)

	return collected


## Recursively collect geometry from a record and its children
func _collect_geometry_recursive(record: Defs.NIFRecord, parent_transform: Transform3D, collected: Dictionary) -> void:
	if record == null:
		return

	# Calculate world transform for this node
	var local_transform := Transform3D.IDENTITY
	if record is Defs.NiAVObject:
		local_transform = _convert_nif_transform((record as Defs.NiAVObject).transform.to_transform3d())
	var world_transform := parent_transform * local_transform

	# Collect geometry
	if record is Defs.NiTriShape:
		_collect_tri_shape(record as Defs.NiTriShape, world_transform, collected)
	elif record is Defs.NiTriStrips:
		_collect_tri_strips(record as Defs.NiTriStrips, world_transform, collected)

	# Recurse into children
	if record is Defs.NiNode:
		var node := record as Defs.NiNode
		for child_idx in node.children_indices:
			if child_idx < 0:
				continue
			var child_record := _reader.get_record(child_idx)
			if child_record:
				_collect_geometry_recursive(child_record, world_transform, collected)


## Collect a NiTriShape into the appropriate material group
func _collect_tri_shape(shape: Defs.NiTriShape, world_transform: Transform3D, collected: Dictionary) -> void:
	# Skip skinned meshes
	if shape.skin_index >= 0:
		return

	if shape.data_index < 0:
		return

	var data_record := _reader.get_record(shape.data_index)
	if not (data_record is Defs.NiTriShapeData):
		return

	var data := data_record as Defs.NiTriShapeData
	if data.vertices.is_empty() or data.triangles.is_empty():
		return

	var geom := CollectedGeometry.new()
	geom.world_transform = world_transform
	geom.material_key = _get_material_key_for_shape(shape)
	geom.material = _get_material_for_shape(shape)
	geom.is_hidden = shape.is_hidden()
	geom.has_skinning = false

	# Build arrays (without creating mesh yet)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)
	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]
	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	# Flip winding order
	var flipped := PackedInt32Array()
	flipped.resize(data.triangles.size())
	for i in range(0, data.triangles.size(), 3):
		flipped[i] = data.triangles[i]
		flipped[i + 1] = data.triangles[i + 2]
		flipped[i + 2] = data.triangles[i + 1]
	arrays[Mesh.ARRAY_INDEX] = flipped

	geom.arrays = arrays

	# Add to collection
	if not collected.has(geom.material_key):
		collected[geom.material_key] = []
	collected[geom.material_key].append(geom)


## Collect a NiTriStrips into the appropriate material group
func _collect_tri_strips(strips: Defs.NiTriStrips, world_transform: Transform3D, collected: Dictionary) -> void:
	# Skip skinned meshes
	if strips.skin_index >= 0:
		return

	if strips.data_index < 0:
		return

	var data_record := _reader.get_record(strips.data_index)
	if not (data_record is Defs.NiTriStripsData):
		return

	var data := data_record as Defs.NiTriStripsData
	if data.vertices.is_empty() or data.strips.is_empty():
		return

	# Convert strips to triangles
	var triangles := PackedInt32Array()
	for strip in data.strips:
		if strip.size() < 3:
			continue
		for i in range(strip.size() - 2):
			if i % 2 == 0:
				triangles.append(strip[i])
				triangles.append(strip[i + 2])
				triangles.append(strip[i + 1])
			else:
				triangles.append(strip[i])
				triangles.append(strip[i + 1])
				triangles.append(strip[i + 2])

	if triangles.is_empty():
		return

	var geom := CollectedGeometry.new()
	geom.world_transform = world_transform
	geom.material_key = _get_material_key_for_shape(strips)
	geom.material = _get_material_for_shape(strips)
	geom.is_hidden = strips.is_hidden()
	geom.has_skinning = false

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)
	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]
	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors
	arrays[Mesh.ARRAY_INDEX] = triangles

	geom.arrays = arrays

	if not collected.has(geom.material_key):
		collected[geom.material_key] = []
	collected[geom.material_key].append(geom)


## Merge multiple geometry pieces with the same material into one mesh
## Returns ArrayMesh with all geometry combined
func _merge_geometry_arrays(geometries: Array) -> ArrayMesh:
	if geometries.is_empty():
		return null

	# Calculate total sizes
	var total_vertices := 0
	var total_indices := 0
	var has_normals := false
	var has_uvs := false
	var has_colors := false

	for geom: CollectedGeometry in geometries:
		var verts: PackedVector3Array = geom.arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = geom.arrays[Mesh.ARRAY_INDEX]
		if verts:
			total_vertices += verts.size()
		if indices:
			total_indices += indices.size()
		if geom.arrays[Mesh.ARRAY_NORMAL] != null:
			has_normals = true
		if geom.arrays[Mesh.ARRAY_TEX_UV] != null:
			has_uvs = true
		if geom.arrays[Mesh.ARRAY_COLOR] != null:
			has_colors = true

	if total_vertices == 0 or total_indices == 0:
		return null

	# Allocate merged arrays
	var merged_verts := PackedVector3Array()
	merged_verts.resize(total_vertices)
	var merged_indices := PackedInt32Array()
	merged_indices.resize(total_indices)

	var merged_normals: PackedVector3Array = PackedVector3Array()
	if has_normals:
		merged_normals.resize(total_vertices)

	var merged_uvs: PackedVector2Array = PackedVector2Array()
	if has_uvs:
		merged_uvs.resize(total_vertices)

	var merged_colors: PackedColorArray = PackedColorArray()
	if has_colors:
		merged_colors.resize(total_vertices)

	# Merge all geometry
	var vert_offset := 0
	var idx_offset := 0

	for geom: CollectedGeometry in geometries:
		var verts: PackedVector3Array = geom.arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = geom.arrays[Mesh.ARRAY_INDEX]

		if verts == null or indices == null:
			continue

		var num_verts := verts.size()
		var num_indices := indices.size()

		# Transform vertices to world space and copy
		var transform := geom.world_transform
		for i in range(num_verts):
			merged_verts[vert_offset + i] = transform * verts[i]

		# Transform normals (rotation only, no translation)
		if has_normals:
			var normals = geom.arrays[Mesh.ARRAY_NORMAL]
			if normals != null and normals.size() == num_verts:
				var basis := transform.basis
				for i in range(num_verts):
					merged_normals[vert_offset + i] = (basis * normals[i]).normalized()
			else:
				# Fill with default normals
				for i in range(num_verts):
					merged_normals[vert_offset + i] = Vector3.UP

		# Copy UVs (no transformation needed)
		if has_uvs:
			var uvs = geom.arrays[Mesh.ARRAY_TEX_UV]
			if uvs != null and uvs.size() == num_verts:
				for i in range(num_verts):
					merged_uvs[vert_offset + i] = uvs[i]
			else:
				for i in range(num_verts):
					merged_uvs[vert_offset + i] = Vector2.ZERO

		# Copy colors
		if has_colors:
			var colors = geom.arrays[Mesh.ARRAY_COLOR]
			if colors != null and colors.size() == num_verts:
				for i in range(num_verts):
					merged_colors[vert_offset + i] = colors[i]
			else:
				for i in range(num_verts):
					merged_colors[vert_offset + i] = Color.WHITE

		# Copy indices (offset by current vertex count)
		for i in range(num_indices):
			merged_indices[idx_offset + i] = indices[i] + vert_offset

		vert_offset += num_verts
		idx_offset += num_indices

	# Build final mesh arrays
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = merged_verts
	arrays[Mesh.ARRAY_INDEX] = merged_indices
	if has_normals:
		arrays[Mesh.ARRAY_NORMAL] = merged_normals
	if has_uvs:
		arrays[Mesh.ARRAY_TEX_UV] = merged_uvs
	if has_colors:
		arrays[Mesh.ARRAY_COLOR] = merged_colors

	var mesh := ArrayMesh.new()
	mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Convert NIF using material merging (reduces draw calls)
## Returns root Node3D with merged meshes
func _convert_merged() -> Node3D:
	var root := Node3D.new()
	root.name = "NIFRoot"

	# Collect all geometry grouped by material
	var collected := _collect_geometry_by_material()

	if debug_merge:
		var total_shapes := 0
		for key: String in collected:
			total_shapes += collected[key].size()
		Logger.debug("nif", "NIFConverter: Merging %d shapes into %d material groups for '%s'" % [
			total_shapes, collected.size(), _source_path.get_file()
		])

	# Create one MeshInstance3D per material group
	var mesh_idx := 0
	for material_key: String in collected:
		var geometries: Array = collected[material_key]
		if geometries.is_empty():
			continue

		# Get material from first geometry (all have same material)
		var first_geom: CollectedGeometry = geometries[0]
		var material: StandardMaterial3D = first_geom.material

		# Merge all geometry with this material
		var merged_mesh := _merge_geometry_arrays(geometries)
		if merged_mesh == null:
			continue

		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "MergedMesh_%d" % mesh_idx
		mesh_instance.mesh = merged_mesh
		if material:
			mesh_instance.material_override = material

		# Check if all pieces are hidden
		var all_hidden := true
		for geom: CollectedGeometry in geometries:
			if not geom.is_hidden:
				all_hidden = false
				break

		# IMPORTANT: Also hide meshes with no material - these are typically:
		# - Collision geometry that shouldn't render
		# - Placeholder nodes from the NIF
		# Without this, they render as white untextured meshes
		var should_hide := all_hidden or (material == null)
		mesh_instance.visible = not should_hide

		if material == null and not all_hidden:
			Logger.debug("nif", "NIFConverter: Hiding materialless mesh in %s (likely collision geometry)" % _source_path.get_file())

		root.add_child(mesh_instance)
		mesh_idx += 1

		if debug_merge:
			var tri_count := merged_mesh.get_faces().size() / 3
			Logger.debug("nif", "  Material group '%s': %d shapes merged, %d triangles" % [
				material_key.substr(0, 40), geometries.size(), tri_count
			])

	# Handle skinned meshes separately (don't merge)
	if _has_skinning_data():
		var skeleton := _create_skeleton_for_nif()
		if skeleton:
			root.add_child(skeleton)
			# Convert skinned meshes the old way
			for root_idx: int in _reader.roots:
				var record := _reader.get_record(root_idx)
				if record:
					_convert_skinned_subtree(record, skeleton, root)

	# Build collision (uses original geometry, not merged)
	if load_collision and _collision_builder:
		var collision_result := _collision_builder.build_collision()
		if collision_result.has_collision:
			var static_body := _collision_builder.create_static_body(collision_result)
			if static_body:
				root.add_child(static_body)

			if collision_result.has_actor_collision_box:
				root.set_meta("actor_collision_center", collision_result.bounding_box_center)
				root.set_meta("actor_collision_extents", collision_result.bounding_box_extents)

	# Post-process: Add LODs
	if generate_lods and _should_generate_lods():
		_add_lods_to_scene(root)

	# Post-process: Add occluders
	if generate_occluders and _should_generate_occluders():
		_add_occluders_to_scene(root)

	return root


## Convert only skinned subtrees (for use with merged conversion)
func _convert_skinned_subtree(record: Defs.NIFRecord, skeleton: Skeleton3D, root: Node3D) -> void:
	if record == null:
		return

	if record is Defs.NiTriShape:
		var shape := record as Defs.NiTriShape
		if shape.skin_index >= 0:
			var mesh_instance := _convert_ni_tri_shape(shape, skeleton)
			if mesh_instance:
				skeleton.add_child(mesh_instance)
	elif record is Defs.NiTriStrips:
		var strips := record as Defs.NiTriStrips
		if strips.skin_index >= 0:
			var mesh_instance := _convert_ni_tri_strips(strips, skeleton)
			if mesh_instance:
				skeleton.add_child(mesh_instance)

	# Recurse
	if record is Defs.NiNode:
		var node := record as Defs.NiNode
		for child_idx in node.children_indices:
			if child_idx < 0:
				continue
			var child := _reader.get_record(child_idx)
			if child:
				_convert_skinned_subtree(child, skeleton, root)
