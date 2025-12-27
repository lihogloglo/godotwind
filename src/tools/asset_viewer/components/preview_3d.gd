## Preview3D - Reusable 3D preview component with SubViewport
##
## Features:
## - SubViewport with configurable size
## - Orbit camera with full controls
## - Directional + ambient lighting
## - Optional ground plane
## - Object container for previewed items
@warning_ignore("untyped_declaration")
class_name Preview3D
extends SubViewportContainer

signal object_loaded(node: Node3D)
signal object_cleared

# Scene nodes (created in _ready)
var viewport: SubViewport = null
var camera: OrbitCamera = null
var main_light: DirectionalLight3D = null
var fill_light: DirectionalLight3D = null
var ground_plane: MeshInstance3D = null
var object_container: Node3D = null
var world_environment: WorldEnvironment = null

# Configuration
@export var viewport_size: Vector2i = Vector2i(800, 600)
@export var show_ground: bool = true
@export var ground_size: float = 10.0
@export var ground_color: Color = Color(0.3, 0.3, 0.3)
@export var background_color: Color = Color(0.2, 0.2, 0.25)
@export var main_light_energy: float = 1.2
@export var fill_light_energy: float = 0.3

# Current displayed object
var _current_object: Node3D = null


func _ready() -> void:
	_setup_viewport()
	_setup_environment()
	_setup_lighting()
	_setup_camera()
	_setup_ground()
	_setup_object_container()


func _setup_viewport() -> void:
	viewport = SubViewport.new()
	viewport.name = "Viewport"
	viewport.size = viewport_size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.handle_input_locally = false
	add_child(viewport)

	# Configure container
	stretch = true
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = background_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.45)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_ACES

	world_environment = WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = env
	viewport.add_child(world_environment)


func _setup_lighting() -> void:
	# Main directional light
	main_light = DirectionalLight3D.new()
	main_light.name = "MainLight"
	main_light.position = Vector3(5, 10, 5)
	main_light.look_at_from_position(main_light.position, Vector3.ZERO)
	main_light.light_energy = main_light_energy
	main_light.shadow_enabled = true
	viewport.add_child(main_light)

	# Fill light (softer, from opposite side)
	fill_light = DirectionalLight3D.new()
	fill_light.name = "FillLight"
	fill_light.position = Vector3(-5, 5, -5)
	fill_light.look_at_from_position(fill_light.position, Vector3.ZERO)
	fill_light.light_energy = fill_light_energy
	fill_light.shadow_enabled = false
	viewport.add_child(fill_light)


func _setup_camera() -> void:
	camera = OrbitCamera.new()
	camera.name = "OrbitCamera"
	camera.current = true
	camera.fov = 60.0
	viewport.add_child(camera)


func _setup_ground() -> void:
	ground_plane = MeshInstance3D.new()
	ground_plane.name = "Ground"

	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(ground_size, ground_size)
	ground_plane.mesh = plane_mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = ground_color
	ground_plane.material_override = mat

	ground_plane.visible = show_ground
	viewport.add_child(ground_plane)


func _setup_object_container() -> void:
	object_container = Node3D.new()
	object_container.name = "ObjectContainer"
	viewport.add_child(object_container)


## Display a 3D object in the preview
func display_object(node: Node3D, auto_frame: bool = true) -> void:
	clear_object()

	_current_object = node
	object_container.add_child(node)

	if auto_frame:
		var aabb := get_combined_aabb(node)
		if aabb.size.length() > 0:
			# Position object so its bottom sits on the ground plane (y=0)
			# aabb.position.y is the bottom of the bounding box in local space
			# We offset so that the object's bottom aligns with y=0
			var center := aabb.get_center()
			var bottom_y := aabb.position.y
			node.position = Vector3(-center.x, -bottom_y, -center.z)
			# Frame camera on the object centered at its new position
			var visual_center_y := aabb.size.y * 0.5
			camera.frame_aabb(AABB(Vector3(0, visual_center_y, 0) - aabb.size * 0.5, aabb.size))

	object_loaded.emit(node)


## Clear the currently displayed object
func clear_object() -> void:
	if _current_object and is_instance_valid(_current_object):
		_current_object.queue_free()
		_current_object = null
		object_cleared.emit()

	# Also clear any orphaned children
	for child in object_container.get_children():
		child.queue_free()


## Get the currently displayed object
func get_current_object() -> Node3D:
	return _current_object


## Calculate combined AABB of a node and all its mesh children
func get_combined_aabb(node: Node3D) -> AABB:
	var meshes: Array[AABB] = []
	_collect_mesh_aabbs(node, node.global_transform, meshes)

	if meshes.is_empty():
		return AABB()

	var combined: AABB = meshes[0]
	for i in range(1, meshes.size()):
		combined = combined.merge(meshes[i])

	return combined


func _collect_mesh_aabbs(node: Node, base_transform: Transform3D, out_aabbs: Array[AABB]) -> void:
	if node is MeshInstance3D:
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh:
			var mesh_aabb: AABB = mesh_node.mesh.get_aabb()
			var local_transform: Transform3D = base_transform.inverse() * mesh_node.global_transform
			mesh_aabb = local_transform * mesh_aabb
			out_aabbs.append(mesh_aabb)

	for child in node.get_children():
		_collect_mesh_aabbs(child, base_transform, out_aabbs)


## Toggle ground plane visibility
func set_ground_visible(visible: bool) -> void:
	show_ground = visible
	if ground_plane:
		ground_plane.visible = visible


## Set background color
func set_background(color: Color) -> void:
	background_color = color
	if world_environment and world_environment.environment:
		world_environment.environment.background_color = color


## Reset camera to default view
func reset_camera() -> void:
	if camera:
		camera.reset()


## Get camera for external control
func get_camera() -> OrbitCamera:
	return camera


## Get the SubViewport used for 3D rendering
func get_sub_viewport() -> SubViewport:
	return viewport
