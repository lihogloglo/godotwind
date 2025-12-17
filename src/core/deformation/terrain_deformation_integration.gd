# TerrainDeformationIntegration.gd
# Bridges deformation system with Terrain3D
# Injects deformation textures into terrain material shaders
extends Node

# Reference to Terrain3D node
var _terrain: Node = null
var _terrain_material: ShaderMaterial = null

# Deformation texture array for shader
var _deformation_texture_array: Texture2DArray = null

# Region tracking for texture array mapping
var _region_to_array_index: Dictionary = {}  # Vector2i -> int
var _array_index_to_region: Dictionary = {}  # int -> Vector2i

# Maximum texture array size (matches Terrain3D's typical usage)
# Note: The actual limit is determined by GPU capabilities (usually 256-2048 layers)
# We use a conservative value that balances memory and flexibility
const MAX_TEXTURE_ARRAY_SIZE: int = 64

func _ready():
	# Check if terrain integration is enabled
	if not DeformationConfig.enable_terrain_integration:
		print("[TerrainDeformationIntegration] Terrain integration disabled in config")
		return

	print("[TerrainDeformationIntegration] Initializing Terrain3D integration...")

	# Wait for scene tree to be ready
	await get_tree().process_frame

	_find_terrain()

	if _terrain != null:
		_setup_terrain_integration()
	else:
		print("[TerrainDeformationIntegration] No Terrain3D found - deformations will not be visible on terrain")

# Find Terrain3D node in scene
func _find_terrain():
	# Try common terrain paths
	var possible_paths = [
		"/root/WorldExplorer/Terrain3D",
		"/root/World/Terrain3D",
		"/root/Terrain3D"
	]

	for path in possible_paths:
		_terrain = get_node_or_null(path)
		if _terrain != null:
			print("[TerrainDeformationIntegration] Found Terrain3D at: ", path)
			return

	# Search for any Terrain3D node
	_terrain = _find_node_by_class(get_tree().root, "Terrain3D")

	if _terrain == null:
		print("[TerrainDeformationIntegration] Warning: Terrain3D not found, deformation won't be visible")
	else:
		print("[TerrainDeformationIntegration] Found Terrain3D node")

# Recursive node search by class name
func _find_node_by_class(node: Node, class_name: String) -> Node:
	if node.get_class() == class_name:
		return node

	for child in node.get_children():
		var result = _find_node_by_class(child, class_name)
		if result != null:
			return result

	return null

# Setup integration with Terrain3D material
func _setup_terrain_integration():
	if _terrain == null:
		return

	# Get terrain material
	if _terrain.has_method("get_material"):
		_terrain_material = _terrain.get_material()
	elif "material" in _terrain:
		_terrain_material = _terrain.material
	else:
		print("[TerrainDeformationIntegration] Warning: Could not get terrain material")
		return

	if _terrain_material == null or not _terrain_material is ShaderMaterial:
		print("[TerrainDeformationIntegration] Warning: Terrain material is not a ShaderMaterial")
		return

	# Initialize texture array
	_create_deformation_texture_array()

	# Set shader parameters
	_inject_deformation_parameters()

	print("[TerrainDeformationIntegration] Terrain integration setup complete")

# Create texture array for deformation regions
func _create_deformation_texture_array():
	var images: Array[Image] = []

	# Create blank images for all array layers
	for i in range(MAX_TEXTURE_ARRAY_SIZE):
		var img = Image.create(
			DeformationManager.DEFORMATION_TEXTURE_SIZE,
			DeformationManager.DEFORMATION_TEXTURE_SIZE,
			false,
			Image.FORMAT_RGF
		)
		img.fill(Color(0.0, 0.0, 0.0, 0.0))
		images.append(img)

	# Create texture array
	_deformation_texture_array = Texture2DArray.new()
	_deformation_texture_array.create_from_images(images)

	print("[TerrainDeformationIntegration] Created deformation texture array")

# Inject deformation parameters into terrain shader
func _inject_deformation_parameters():
	if _terrain_material == null or _deformation_texture_array == null:
		return

	# Set shader parameters
	_terrain_material.set_shader_parameter("deformation_texture_array", _deformation_texture_array)
	_terrain_material.set_shader_parameter("deformation_enabled", true)
	_terrain_material.set_shader_parameter("deformation_depth_scale", DeformationManager.deformation_depth_scale)

	print("[TerrainDeformationIntegration] Injected deformation parameters into terrain shader")

# Update deformation texture for a specific region
func update_region_texture(region_coord: Vector2i, texture: ImageTexture):
	# Safety checks
	if not DeformationConfig.enable_terrain_integration:
		return
	if _terrain == null or _terrain_material == null:
		return
	if texture == null:
		return
	if _deformation_texture_array == null:
		return

	# Try to get Terrain3D's layer index for this region
	var terrain_layer_index = _get_terrain_layer_index(region_coord)

	# Use terrain's layer index if available, otherwise use our own mapping
	var array_index = terrain_layer_index if terrain_layer_index >= 0 else _get_or_create_array_index(region_coord)

	if array_index == -1 or array_index >= MAX_TEXTURE_ARRAY_SIZE:
		if DeformationConfig.debug_mode:
			push_warning("[TerrainDeformationIntegration] Cannot update region %s: invalid array index %d" % [region_coord, array_index])
		return

	# Update texture array layer
	var image = texture.get_image()
	if image != null:
		_deformation_texture_array.update_layer(image, array_index)

		if DeformationConfig.debug_mode:
			print("[TerrainDeformationIntegration] Updated deformation layer %d for region %s" % [array_index, region_coord])

# Try to get Terrain3D's layer index for a region coordinate
func _get_terrain_layer_index(region_coord: Vector2i) -> int:
	if _terrain == null:
		return -1

	# Try to access Terrain3D's storage and get region index
	# Terrain3D uses a storage object that tracks regions
	if _terrain.has_method("get_storage"):
		var storage = _terrain.get_storage()
		if storage != null and storage.has_method("get_region_index"):
			var layer_index = storage.get_region_index(region_coord)
			if layer_index >= 0:
				return layer_index

	# Alternative: Try to get region data directly
	if _terrain.has_method("get_region_location"):
		var region_id = _terrain.get_region_location(region_coord)
		if region_id >= 0:
			return region_id

	# Fallback: return -1 to indicate we should use our own mapping
	return -1

# Get or create array index for region
func _get_or_create_array_index(region_coord: Vector2i) -> int:
	# Check if region already has an index
	if _region_to_array_index.has(region_coord):
		return _region_to_array_index[region_coord]

	# Assign new index with LRU eviction if array is full
	if _next_array_index >= MAX_TEXTURE_ARRAY_SIZE:
		# Find least recently used region (simple: use first available slot)
		# TODO: Implement proper LRU eviction
		if DeformationConfig.debug_mode:
			push_warning("[TerrainDeformationIntegration] Texture array full, eviction needed")

		# For now, try to recycle indices of unloaded regions
		for i in range(MAX_TEXTURE_ARRAY_SIZE):
			if not _array_index_to_region.has(i):
				# Found an empty slot
				_region_to_array_index[region_coord] = i
				_array_index_to_region[i] = region_coord
				return i

		return -1  # Array full, no slots available

	var index = _next_array_index
	_next_array_index += 1

	_region_to_array_index[region_coord] = index
	_array_index_to_region[index] = region_coord

	return index

# Remove region from texture array
func remove_region_texture(region_coord: Vector2i):
	if not _region_to_array_index.has(region_coord):
		return

	var array_index = _region_to_array_index[region_coord]

	# Clear the layer with blank image (reset to no deformation)
	var blank_image = Image.create(
		DeformationManager.DEFORMATION_TEXTURE_SIZE,
		DeformationManager.DEFORMATION_TEXTURE_SIZE,
		false,
		Image.FORMAT_RGF
	)
	blank_image.fill(Color(0.0, 0.0, 0.0, 0.0))

	if _deformation_texture_array != null:
		_deformation_texture_array.update_layer(blank_image, array_index)

	# Remove mappings (keeps array index available for reuse)
	_region_to_array_index.erase(region_coord)
	_array_index_to_region.erase(array_index)

	if DeformationConfig.debug_mode:
		print("[TerrainDeformationIntegration] Cleared deformation layer %d for region %s" % [array_index, region_coord])

# Get array index for region (for shader parameter binding)
func get_region_array_index(region_coord: Vector2i) -> int:
	return _region_to_array_index.get(region_coord, -1)

# Enable/disable deformation rendering
func set_deformation_enabled(enabled: bool):
	if _terrain_material != null:
		_terrain_material.set_shader_parameter("deformation_enabled", enabled)
