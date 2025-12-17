## BuoyantBody - Applies buoyancy forces to a RigidBody3D using Jolt physics
## Attach as a child of a RigidBody3D to make it float on the ocean
## Uses cell-based approach for realistic distributed forces
@tool
class_name BuoyantBody
extends Node

# Fluid properties
const WATER_DENSITY: float = 1025.0  # kg/m³ (seawater)
const GRAVITY: float = 9.81  # m/s²

# Buoyancy configuration
@export var enabled: bool = true
@export var fluid_density: float = WATER_DENSITY
@export var drag_coefficient: float = 0.5
@export var angular_drag_coefficient: float = 0.5

# Buoyancy cells - define sampling points for buoyancy calculation
# Each cell is a BoxShape3D that defines a volume for buoyancy sampling
@export var buoyancy_cells: Array[BuoyancyCell] = []

# Auto-generate cells from collision shapes
@export var auto_generate_cells: bool = false
@export var auto_cell_count: int = 8

# Debug visualization
@export var debug_draw: bool = false

# Internal state
var _parent_body: RigidBody3D = null
var _total_mass: float = 0.0
var _submerged_volume: float = 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# Find parent RigidBody3D
	_parent_body = get_parent() as RigidBody3D
	if not _parent_body:
		push_warning("[BuoyantBody] Must be a child of RigidBody3D")
		return

	# Disable gravity on the parent (we'll apply it per-cell)
	_parent_body.gravity_scale = 0.0

	# Auto-generate cells if enabled and none defined
	if auto_generate_cells and buoyancy_cells.is_empty():
		_auto_generate_buoyancy_cells()

	# Calculate total mass from cells
	_calculate_mass()

	print("[BuoyantBody] Initialized with %d cells, total mass: %.1f kg" % [buoyancy_cells.size(), _total_mass])


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not enabled or not _parent_body:
		return

	_submerged_volume = 0.0

	for cell in buoyancy_cells:
		_apply_buoyancy_force(cell, delta)

	# Apply drag forces when in water
	if _submerged_volume > 0.0:
		_apply_drag_forces(delta)


func _apply_buoyancy_force(cell: BuoyancyCell, _delta: float) -> void:
	# Get cell world position
	var cell_world_pos := _parent_body.global_transform * cell.local_position

	# Get water height at cell position
	var water_height := _get_water_height(cell_world_pos)

	# Calculate cell bounds
	var cell_top := cell_world_pos.y + cell.size.y * 0.5
	var cell_bottom := cell_world_pos.y - cell.size.y * 0.5

	# Calculate submerged fraction
	var submerged_fraction: float
	if cell_top <= water_height:
		# Fully submerged
		submerged_fraction = 1.0
	elif cell_bottom >= water_height:
		# Not submerged
		submerged_fraction = 0.0
	else:
		# Partially submerged
		submerged_fraction = (water_height - cell_bottom) / cell.size.y

	submerged_fraction = clampf(submerged_fraction, 0.0, 1.0)

	if submerged_fraction <= 0.0:
		# Apply gravity only (not in water)
		var gravity_force := Vector3.DOWN * cell.get_mass() * GRAVITY
		_parent_body.apply_force(gravity_force, cell_world_pos - _parent_body.global_position)
		return

	# Calculate submerged volume
	var cell_volume := cell.get_volume()
	var submerged_vol := cell_volume * submerged_fraction
	_submerged_volume += submerged_vol

	# Calculate buoyant force (Archimedes principle)
	var displaced_mass := submerged_vol * fluid_density
	var buoyant_force := Vector3.UP * displaced_mass * GRAVITY

	# Calculate gravity force for this cell
	var gravity_force := Vector3.DOWN * cell.get_mass() * GRAVITY

	# Net force
	var net_force := buoyant_force + gravity_force

	# Apply force at cell position (creates torque)
	var force_offset := cell_world_pos - _parent_body.global_position
	_parent_body.apply_force(net_force, force_offset)

	# Debug visualization
	if debug_draw:
		_debug_draw_cell(cell_world_pos, cell.size, submerged_fraction, net_force)


func _apply_drag_forces(_delta: float) -> void:
	if not _parent_body:
		return

	# Linear drag
	var velocity := _parent_body.linear_velocity
	var speed := velocity.length()
	if speed > 0.01:
		var drag_force := -velocity.normalized() * drag_coefficient * speed * speed * _submerged_volume
		_parent_body.apply_central_force(drag_force)

	# Angular drag
	var angular_velocity := _parent_body.angular_velocity
	var angular_speed := angular_velocity.length()
	if angular_speed > 0.01:
		var angular_drag := -angular_velocity.normalized() * angular_drag_coefficient * angular_speed * _submerged_volume
		_parent_body.apply_torque(angular_drag)


func _get_water_height(world_pos: Vector3) -> float:
	# Use OceanManager if available
	if is_instance_valid(OceanManager):
		return OceanManager.get_wave_height(world_pos)

	# Fallback to sea level
	return 0.0


func _calculate_mass() -> void:
	_total_mass = 0.0
	for cell in buoyancy_cells:
		_total_mass += cell.get_mass()

	# Update parent body mass if needed
	if _parent_body and _total_mass > 0.0:
		_parent_body.mass = _total_mass


func _auto_generate_buoyancy_cells() -> void:
	if not _parent_body:
		return

	# Find collision shapes
	var aabb := AABB()
	var found_shapes := false

	for child in _parent_body.get_children():
		if child is CollisionShape3D and child.shape:
			var shape_aabb := _get_shape_aabb(child.shape)
			shape_aabb.position += child.position
			if found_shapes:
				aabb = aabb.merge(shape_aabb)
			else:
				aabb = shape_aabb
				found_shapes = true

	if not found_shapes:
		push_warning("[BuoyantBody] No collision shapes found for auto-generation")
		return

	# Generate cells in a grid pattern
	var cells_per_axis := int(ceil(pow(float(auto_cell_count), 1.0 / 3.0)))
	var cell_size := aabb.size / Vector3(cells_per_axis, cells_per_axis, cells_per_axis)

	buoyancy_cells.clear()

	for x in range(cells_per_axis):
		for y in range(cells_per_axis):
			for z in range(cells_per_axis):
				var cell := BuoyancyCell.new()
				cell.local_position = aabb.position + Vector3(
					(x + 0.5) * cell_size.x,
					(y + 0.5) * cell_size.y,
					(z + 0.5) * cell_size.z
				)
				cell.size = cell_size
				cell.density = 500.0  # Default wood density
				buoyancy_cells.append(cell)

	print("[BuoyantBody] Auto-generated %d buoyancy cells" % buoyancy_cells.size())


func _get_shape_aabb(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var box := shape as BoxShape3D
		return AABB(-box.size * 0.5, box.size)
	elif shape is SphereShape3D:
		var sphere := shape as SphereShape3D
		var r := sphere.radius
		return AABB(Vector3(-r, -r, -r), Vector3(r * 2, r * 2, r * 2))
	elif shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		var r := capsule.radius
		var h := capsule.height
		return AABB(Vector3(-r, -h * 0.5, -r), Vector3(r * 2, h, r * 2))
	elif shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		var r := cylinder.radius
		var h := cylinder.height
		return AABB(Vector3(-r, -h * 0.5, -r), Vector3(r * 2, h, r * 2))
	else:
		# Default fallback
		return AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))


func _debug_draw_cell(pos: Vector3, size: Vector3, submerged: float, force: Vector3) -> void:
	# Use DebugDraw3D if available, otherwise skip
	# This is a placeholder for debug visualization
	pass


## Add a buoyancy cell manually
func add_cell(local_pos: Vector3, size: Vector3, density: float = 500.0) -> void:
	var cell := BuoyancyCell.new()
	cell.local_position = local_pos
	cell.size = size
	cell.density = density
	buoyancy_cells.append(cell)
	_calculate_mass()


## Clear all buoyancy cells
func clear_cells() -> void:
	buoyancy_cells.clear()
	_total_mass = 0.0


## Get total submerged volume (useful for effects)
func get_submerged_volume() -> float:
	return _submerged_volume


## Get total mass
func get_total_mass() -> float:
	return _total_mass


## Check if any part is submerged
func is_in_water() -> bool:
	return _submerged_volume > 0.0


## Resource class for buoyancy cell data
class BuoyancyCell:
	extends Resource

	@export var local_position: Vector3 = Vector3.ZERO
	@export var size: Vector3 = Vector3.ONE
	@export var density: float = 500.0  # kg/m³ (wood ~500, steel ~8000)

	func get_volume() -> float:
		return size.x * size.y * size.z

	func get_mass() -> float:
		return get_volume() * density
