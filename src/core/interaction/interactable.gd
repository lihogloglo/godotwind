## Interactable — Framework base class for player-interactable world objects
##
## A generic "the player can press E on this" component. Extend this in a
## game-specific adapter (see src/core/dialogue/morrowind/npc_interactable.gd
## and book_interactable.gd for Morrowind implementations).
##
## ## Architecture
##
## - Interactable is a Node3D that sits alongside (or as a child of) the
##   visual/physics body of a world object. A sibling StaticBody3D or Area3D
##   on collision layer 3 (Interactable) provides the raycast target.
## - The InteractionRaycaster (on the player camera) casts to layer 3, finds
##   the nearest collider, walks up to its Interactable sibling/ancestor, and
##   calls `interact(player)` when the player presses the interact action.
## - Subclasses override `get_prompt_text()` to show context-appropriate UI
##   ("Talk to Fargoth", "Read <book>", "Take <ingredient>") and override
##   `interact()` to perform the action (open dialogue, open book, pick up).
##
## ## Framework/adapter boundary
##
## THIS FILE HAS ZERO GAME-SPECIFIC IMPORTS. No ESMManager, no NPCRecord,
## no BookRecord, no Morrowind references. If you find yourself reaching
## for one of those, you're writing a concrete subclass — put it in the
## game-specific adapter directory, not here.
##
## ## Range semantics
##
## `max_interaction_distance` is the hard cap. Game-specific subclasses may
## expose tighter limits (e.g. NPCInteractable reads `hello_distance` from
## MW AI data and refuses interaction beyond that). The raycaster uses the
## base value for its cast length; per-interactable range checks happen in
## the subclass's `can_interact()` override.
class_name Interactable
extends Node3D


## Emitted after interact() completes successfully. The raycaster listens
## so it can refresh the prompt UI.
signal interacted(player: Node3D)


## Maximum distance (meters) at which this interactable is considered.
## Subclasses may expose tighter limits via can_interact() overrides.
@export var max_interaction_distance: float = 3.0

## Whether this interactable is currently active. Set false to temporarily
## disable without removing the node (e.g. NPC is dead, book is locked).
@export var enabled: bool = true


## Text shown in the player's interaction prompt UI ("Press E to ...").
## Default returns empty; subclasses should override.
func get_prompt_text() -> String:
	return ""


## Can the player interact with this right now?
## Override to add per-object range checks, condition checks, state checks.
## `distance` is the raycast hit distance from the player camera.
func can_interact(player: Node3D, distance: float) -> bool:
	if not enabled:
		return false
	if distance > max_interaction_distance:
		return false
	return true


## Perform the interaction. Override in subclasses.
## The base implementation just emits the `interacted` signal.
func interact(player: Node3D) -> void:
	interacted.emit(player)
