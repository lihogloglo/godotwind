class_name TransitionPortalDescriptor
extends RefCounted

var portal_key: StringName = &""
var source_space: WorldSpaceHandle = null
var target_space: WorldSpaceHandle = null

var display_name: String = ""
var prompt_text: String = ""

var source_position: Vector3 = Vector3.ZERO
var source_basis: Basis = Basis.IDENTITY
var target_position: Vector3 = Vector3.ZERO
var target_basis: Basis = Basis.IDENTITY
var target_yaw_basis: Basis = Basis.IDENTITY

## Opaque locator used only by source adapters and diagnostics to find the
## published interactable for this placed portal.
var affordance_key: StringName = &""
var affordance_ordinal: int = -1

## Optional source-adapter metadata for seamless portal policy. Core treats
## these as generic identifiers, not as parser records.
var shell_key: StringName = &""
var shell_model_path: String = ""
var supports_seamless: bool = true


func has_interior_target() -> bool:
	return target_space != null and target_space.is_interior()


func has_exterior_target() -> bool:
	return target_space != null and target_space.is_exterior()


func target_key() -> String:
	return target_space.key if target_space != null else ""
