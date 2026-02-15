# Character Type System
# Defines character types and spawn data structures for dual character pipeline
# Routes character creation to appropriate factory (MW vs Mixamo)

class_name CharacterTypes
extends RefCounted

## Character type enum - determines which factory to use
enum Type {
	MORROWIND,  ## MW skeleton + KF animations (xbase_anim.nif based)
	MIXAMO,     ## Mixamo skeleton + FBX animations (native format)
}

## Spawn data for character creation - type-specific data routing
class SpawnData extends RefCounted:
	var type: Type
	var position: Vector3
	var rotation: float  # Y-axis rotation in radians
	var data: Dictionary  # Type-specific data

	func _init(p_type: Type, p_pos: Vector3, p_rot: float = 0.0, p_data: Dictionary = {}) -> void:
		type = p_type
		position = p_pos
		rotation = p_rot
		data = p_data

## MW-specific spawn data helper
static func create_morrowind_spawn(pos: Vector3, rot: float, race: String, parts: Dictionary) -> SpawnData:
	var data := {
		"race": race,
		"body_parts": parts,  # ESM body part IDs per slot
		"equipment": {},      # Equipment items (optional)
	}
	return SpawnData.new(Type.MORROWIND, pos, rot, data)

## Mixamo-specific spawn data helper
static func create_mixamo_spawn(pos: Vector3, rot: float, fbx_path: String, equipment: Dictionary = {}) -> SpawnData:
	var data := {
		"fbx_path": fbx_path,      # Path to character FBX
		"equipment": equipment,     # Equipment attachment data
		"customization": {},        # Color/material overrides (optional)
	}
	return SpawnData.new(Type.MIXAMO, pos, rot, data)
