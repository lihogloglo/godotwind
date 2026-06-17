class_name TransitionProvider
extends RefCounted

## Source-neutral provider contract for transition topology. Concrete game
## adapters translate parser/source records into TransitionPortalDescriptor data.


func get_exterior_transition_portals(_cell_payload: Variant, _cell_grid: Vector2i) -> Array[TransitionPortalDescriptor]:
	return []


func get_interior_transition_portals(
	_space_handle: WorldSpaceHandle,
	_cell_payload: Variant,
	_pocket_offset: Vector3,
) -> Array[TransitionPortalDescriptor]:
	return []


func get_transition_space_payload(_space_handle: WorldSpaceHandle) -> Variant:
	return null


func build_transition_environment(
	_space_handle: WorldSpaceHandle,
	_cell_payload: Variant,
	_exterior_environment: Environment,
) -> Environment:
	return null

