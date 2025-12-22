# TerrainDeformationBridge.gd
# Bridges deformation rest heights to Terrain3D without modifying its source
# Populates _texture_deform_rest_array from a configuration resource

class_name TerrainDeformationBridge
extends Node

## Configuration resource that maps texture IDs to rest heights
@export var texture_config: TerrainDeformationTextureConfig

## Terrain3D node (auto-detected if not set)
@export var terrain_node: Terrain3D

## Auto-update when config changes
@export var auto_update: bool = true

## Debug logging
@export var debug: bool = false

func _ready():
	# Auto-find Terrain3D if not set
	if terrain_node == null:
		terrain_node = _find_terrain3d()

	if terrain_node == null:
		push_warning("[TerrainDeformationBridge] No Terrain3D node found!")
		return

	# Apply configuration
	apply_deformation_heights()

	# Watch for material changes
	if auto_update:
		terrain_node.material_changed.connect(_on_material_changed)

	if debug:
		print("[TerrainDeformationBridge] Initialized for: ", terrain_node.name)

## Apply deformation heights to Terrain3D material
func apply_deformation_heights() -> void:
	if terrain_node == null:
		push_error("[TerrainDeformationBridge] No Terrain3D node set!")
		return

	if texture_config == null:
		push_warning("[TerrainDeformationBridge] No texture config set!")
		return

	# Get Terrain3D's material
	var material = terrain_node.get_material()
	if material == null:
		push_error("[TerrainDeformationBridge] Terrain3D has no material!")
		return

	# Build the deformation rest array
	var rest_heights = PackedFloat32Array()
	rest_heights.resize(32)
	rest_heights.fill(0.0)  # Default: no deformation

	# Populate from config
	for entry in texture_config.texture_heights:
		var texture_id = entry.texture_id
		var rest_height = entry.rest_height

		if texture_id >= 0 and texture_id < 32:
			rest_heights[texture_id] = rest_height
			if debug:
				print("  Texture %d: %.3fm (%s)" % [texture_id, rest_height, entry.texture_name])

	# Set the shader parameter
	# NOTE: Even though this is a "private" uniform (_prefix), GDScript can still set it!
	material.set_shader_parameter("_texture_deform_rest_array", rest_heights)

	if debug:
		print("[TerrainDeformationBridge] Applied %d texture heights to Terrain3D" % texture_config.texture_heights.size())

## Auto-find Terrain3D node in scene tree
func _find_terrain3d() -> Terrain3D:
	# Check parent first
	var parent = get_parent()
	if parent is Terrain3D:
		return parent

	# Check siblings
	if parent != null:
		for child in parent.get_children():
			if child is Terrain3D:
				return child

	# Search entire tree (slower)
	var root = get_tree().root
	return _search_for_terrain3d(root)

func _search_for_terrain3d(node: Node) -> Terrain3D:
	if node is Terrain3D:
		return node

	for child in node.get_children():
		var result = _search_for_terrain3d(child)
		if result != null:
			return result

	return null

## Called when Terrain3D material changes (reload, shader swap, etc.)
func _on_material_changed() -> void:
	if debug:
		print("[TerrainDeformationBridge] Terrain3D material changed, reapplying heights...")

	# Reapply configuration
	call_deferred("apply_deformation_heights")

## Manually trigger update (useful for editor scripts)
func update_heights() -> void:
	apply_deformation_heights()

## Get current rest height for a texture ID
func get_rest_height(texture_id: int) -> float:
	if texture_config == null:
		return 0.0

	for entry in texture_config.texture_heights:
		if entry.texture_id == texture_id:
			return entry.rest_height

	return 0.0

## Set rest height for a texture ID at runtime
func set_rest_height(texture_id: int, height: float) -> void:
	if texture_config == null:
		push_error("[TerrainDeformationBridge] No texture config set!")
		return

	# Find existing entry
	for entry in texture_config.texture_heights:
		if entry.texture_id == texture_id:
			entry.rest_height = height
			apply_deformation_heights()
			return

	# Create new entry
	var new_entry = TerrainDeformationTextureEntry.new()
	new_entry.texture_id = texture_id
	new_entry.rest_height = height
	new_entry.texture_name = "Texture %d" % texture_id
	texture_config.texture_heights.append(new_entry)
	apply_deformation_heights()

## Debug: Print current configuration
func print_configuration() -> void:
	if texture_config == null:
		print("[TerrainDeformationBridge] No configuration loaded")
		return

	print("=== Terrain Deformation Heights Configuration ===")
	print("Terrain3D: ", terrain_node.name if terrain_node else "NOT SET")
	print("Textures configured: ", texture_config.texture_heights.size())
	print()

	for entry in texture_config.texture_heights:
		print("  [%2d] %-20s: %6.3fm" % [entry.texture_id, entry.texture_name, entry.rest_height])

	print("=================================================")
