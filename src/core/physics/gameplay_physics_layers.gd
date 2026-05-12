## GameplayPhysicsLayers -- shared framework physics layer roles.
##
## This is intentionally a helper, not an autoload. Systems that need gameplay
## layer roles preload it directly so player, carry, interaction, and interior
## transitions do not each encode their own partial layer assumptions.
class_name GameplayPhysicsLayers
extends RefCounted

## Mirrors `project.godot [layer_names.3d_physics]`.
const ENVIRONMENT: int = 1 << 0
const PLAYER: int = 1 << 1
const INTERACTABLE: int = 1 << 2

## Interior transitions currently reserve exterior physics layers 1-4.
const EXTERIOR_TRANSITION_MASK: int = 0xF

## Standard carryable body spawn contract.
const CARRYABLE_LAYER: int = ENVIRONMENT | INTERACTABLE
const CARRYABLE_MASK: int = ENVIRONMENT | PLAYER


static func get_body_collision_layers(body: CollisionObject3D, fallback_mask: int = 0) -> int:
	if body == null or not is_instance_valid(body):
		return fallback_mask
	return body.collision_layer


static func exclude_layers(mask: int, layer_bits: int) -> int:
	return mask & ~layer_bits


static func get_held_body_mask(saved_mask: int, player_body: CollisionObject3D) -> int:
	var player_layers := get_body_collision_layers(player_body, PLAYER)
	return exclude_layers(saved_mask, player_layers)
