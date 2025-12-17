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
var _next_array_index: int = 0

# Maximum texture array size
const MAX_TEXTURE_ARRAY_SIZE: int = 16

func _ready():
	print("[TerrainDeformationIntegration] Initializing Terrain3D integration...")

	# Wait for scene tree to be ready
	await get_tree().process_frame

	_find_terrain()

	if _terrain != null:
		_setup_terrain_integration()

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
	if texture == null:
		return

	# Get or assign array index for this region
	var array_index = _get_or_create_array_index(region_coord)

	if array_index == -1:
		print("[TerrainDeformationIntegration] Warning: Texture array full, cannot add region: ", region_coord)
		return

	# Update texture array layer
	var image = texture.get_image()
	if image != null and _deformation_texture_array != null:
		_deformation_texture_array.update_layer(image, array_index)

# Get or create array index for region
func _get_or_create_array_index(region_coord: Vector2i) -> int:
	# Check if region already has an index
	if _region_to_array_index.has(region_coord):
		return _region_to_array_index[region_coord]

	# Assign new index
	if _next_array_index >= MAX_TEXTURE_ARRAY_SIZE:
		# Array full - need to evict old region (LRU would be better)
		return -1

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

	# Clear the layer with blank image
	var blank_image = Image.create(
		DeformationManager.DEFORMATION_TEXTURE_SIZE,
		DeformationManager.DEFORMATION_TEXTURE_SIZE,
		false,
		Image.FORMAT_RGF
	)
	blank_image.fill(Color(0.0, 0.0, 0.0, 0.0))

	if _deformation_texture_array != null:
		_deformation_texture_array.update_layer(blank_image, array_index)

	# Remove mappings
	_region_to_array_index.erase(region_coord)
	_array_index_to_region.erase(array_index)

# Get array index for region (for shader parameter binding)
func get_region_array_index(region_coord: Vector2i) -> int:
	return _region_to_array_index.get(region_coord, -1)

# Enable/disable deformation rendering
func set_deformation_enabled(enabled: bool):
	if _terrain_material != null:
		_terrain_material.set_shader_parameter("deformation_enabled", enabled)
