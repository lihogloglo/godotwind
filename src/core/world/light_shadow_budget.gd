## LightShadowBudget — Dynamic shadow allocation for Morrowind lights
##
## Manages which OmniLight3D nodes get shadows based on distance to camera.
## Godot has no built-in light prioritization — we must manage it manually.
##
## Strategy:
##   0-10m:  CUBE shadows (6 passes, best quality for close lights)
##   10-30m: DUAL_PARABOLOID shadows (2 passes, acceptable at distance)
##   30m+:   No shadows
##
## Hysteresis: 2m buffer prevents shadow flickering at tier boundaries.
## Budget: max MAX_SHADOW_LIGHTS simultaneously shadowed lights.
## Updated every UPDATE_INTERVAL seconds (not every frame).
class_name LightShadowBudget
extends Node

## Maximum simultaneously shadow-casting lights.
## Configurable per-instance — interiors use higher values than exteriors.
var max_shadow_lights: int = 8

## Distance tiers for shadow mode selection (with hysteresis).
## Configurable per-instance — interiors use larger ranges.
var shadow_cube_enable: float = 8.0    # Enable CUBE when closer than this
var shadow_cube_disable: float = 10.0  # Disable CUBE when farther than this
var shadow_dual_enable: float = 28.0   # Enable DUAL when closer than this
var shadow_dual_disable: float = 30.0  # Disable all shadows beyond this

## How often to re-evaluate shadow allocation (seconds)
const UPDATE_INTERVAL: float = 0.5

## How often to purge invalid light references (seconds)
const PURGE_INTERVAL: float = 5.0

## Camera reference — set by parent system
var camera: Camera3D = null

# Internal state
var _tracked_lights: Array[OmniLight3D] = []
var _timer: float = 0.0
var _purge_timer: float = 0.0


func _ready() -> void:
	# Defer initial scan
	_scan_lights.call_deferred()


## Scan all descendant OmniLight3D nodes and track them
func _scan_lights() -> void:
	_tracked_lights.clear()
	_scan_node(get_parent())


func _scan_node(node: Node) -> void:
	if node is OmniLight3D:
		_tracked_lights.append(node as OmniLight3D)
	for child in node.get_children():
		_scan_node(child)


## Register a new light dynamically (e.g., when a new cell loads)
func register_light(light: OmniLight3D) -> void:
	if light not in _tracked_lights:
		_tracked_lights.append(light)


## Unregister a light (e.g., when a cell unloads)
func unregister_light(light: OmniLight3D) -> void:
	_tracked_lights.erase(light)


func _process(delta: float) -> void:
	_timer += delta
	_purge_timer += delta

	# Periodic cleanup of invalid references (freed lights from unloaded cells)
	if _purge_timer >= PURGE_INTERVAL:
		_purge_timer -= PURGE_INTERVAL
		_purge_invalid_lights()

	if _timer < UPDATE_INTERVAL:
		return
	_timer -= UPDATE_INTERVAL

	if not camera or _tracked_lights.is_empty():
		return

	_update_shadow_allocation()


## Remove freed light references from tracked array
func _purge_invalid_lights() -> void:
	var i: int = _tracked_lights.size() - 1
	while i >= 0:
		if not is_instance_valid(_tracked_lights[i]):
			_tracked_lights.remove_at(i)
		i -= 1


func _update_shadow_allocation() -> void:
	var cam_pos: Vector3 = camera.global_position

	# Build distance-sorted list of valid lights within shadow range
	var light_distances: Array[Dictionary] = []
	for light: OmniLight3D in _tracked_lights:
		if not is_instance_valid(light):
			continue
		var dist_sq: float = light.global_position.distance_squared_to(cam_pos)
		# Use disable distance (outer boundary) for initial filtering
		if dist_sq < shadow_dual_disable * shadow_dual_disable:
			light_distances.append({"light": light, "dist_sq": dist_sq})

	# Sort by distance (closest first)
	light_distances.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.dist_sq < b.dist_sq
	)

	# Allocate shadow budget to closest lights with hysteresis
	var shadow_count: int = 0
	var shadowed_set: Dictionary = {}

	for entry: Dictionary in light_distances:
		if shadow_count >= max_shadow_lights:
			break
		var light: OmniLight3D = entry.light
		var dist: float = sqrt(entry.dist_sq)
		var was_shadowed: bool = light.shadow_enabled

		# Hysteresis: use tighter threshold to enable, wider to disable
		var should_shadow: bool
		if was_shadowed:
			should_shadow = dist <= shadow_dual_disable
		else:
			should_shadow = dist <= shadow_dual_enable

		if not should_shadow:
			continue

		light.shadow_enabled = true

		# Shadow mode with hysteresis
		if was_shadowed and light.omni_shadow_mode == OmniLight3D.SHADOW_CUBE:
			# Currently CUBE — keep until disable threshold
			if dist > shadow_cube_disable:
				light.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID
		else:
			# Not currently CUBE — enable at tighter threshold
			if dist <= shadow_cube_enable:
				light.omni_shadow_mode = OmniLight3D.SHADOW_CUBE
			else:
				light.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID

		shadowed_set[light.get_instance_id()] = true
		shadow_count += 1

	# Disable shadows on all other tracked lights
	for light: OmniLight3D in _tracked_lights:
		if not is_instance_valid(light):
			continue
		if light.get_instance_id() not in shadowed_set:
			light.shadow_enabled = false
