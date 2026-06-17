class_name TransitionProvider
extends RefCounted

## Source-neutral provider contract for transition topology. Concrete game
## adapters translate parser/source records into TransitionPortalDescriptor data.


func get_exterior_transition_portals(_cell_payload: Variant, _cell_grid: Vector2i) -> Array[TransitionPortalDescriptor]:
	return []


func get_interior_transition_portals(
	_space_handle: WorldSpaceHandle,
	_pocket_offset: Vector3,
) -> Array[TransitionPortalDescriptor]:
	return []


func get_transition_space_info(
	_space_handle: WorldSpaceHandle,
	_exterior_environment: Environment,
) -> RefCounted:
	return null
