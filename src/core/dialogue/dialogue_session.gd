## DialogueSession — shared references for in-world interactables
##
## Holds the persistent framework singletons that NPCInteractable /
## BookInteractable (and future ItemInteractable / DoorInteractable /
## ContainerInteractable) need to open their respective panels:
##
##   - provider:     the active DialogueProvider (e.g. MWDialogueProvider)
##   - context:      the active DialogueContext (populated with player state)
##   - dialogue_ui:  the persistent DialogueUI panel
##   - book_viewer:  the persistent BookViewer panel
##
## ## Why a session holder instead of per-instance fields
##
## Cell streaming spawns hundreds of NPCInteractables per cell. Stamping the
## provider + context + ui refs into every one of them is wasted work and
## wasted memory — and makes the `reference_instantiator` decorator more
## coupled than it needs to be. Interactables are small Node3Ds with a
## speaker_id (or book_id) and nothing else; they reach back to the shared
## session at interact time.
##
## ## Ownership + lifetime
##
## The main scene constructs one DialogueSession at boot, populates its four
## fields with the persistent singletons, then calls `set_current(session)`
## once. All interactables read via `DialogueSession.current()`.
##
## This is a plain RefCounted — not an autoload — so it follows the existing
## Godotwind pattern where autoloads are reserved for long-lived *services*
## (ESMManager, BSAManager, OceanManager...) and per-session state holders
## are owned by the scene root.
##
## ## Framework-agnostic
##
## Zero MW imports. An Oblivion or Witcher provider plugs into the same
## session holder with its own `DialogueProvider` subclass and its own
## context subclass (via the base DialogueContext reference).
class_name DialogueSession
extends RefCounted


## Active dialogue provider. Typically one MWDialogueProvider per game session.
var provider: DialogueProvider

## Active dialogue context. Holds the player state that filters conversations.
var context: DialogueContext

## Persistent DialogueUI panel — spawned once, opened/closed per conversation.
var dialogue_ui: DialogueUI

## Persistent BookViewer panel — spawned once, opened/closed per read.
var book_viewer: BookViewer


## Global current-session holder. Set once at boot by the main scene.
static var _current: DialogueSession = null


## Register the active session. Called by the main scene during setup.
## Passing null clears the holder (e.g. on main menu return).
static func set_current(session: DialogueSession) -> void:
	_current = session


## Retrieve the active session. Returns null if `set_current()` hasn't been
## called yet — callers in `interact()` should null-check and warn-log
## rather than crash, so that a misconfigured scene surfaces a clear error
## instead of a silent no-op.
static func current() -> DialogueSession:
	return _current


## Is any conversation / book / journal panel currently holding player input?
##
## Called by `InteractionRaycaster` (and future first-person input owners)
## to early-out of their input handlers while a panel is active — without
## this, pressing the interact action while a panel is open would immediately
## retrigger the ancestor Interactable, re-open the same panel, and destroy
## any in-flight click the player had aimed at a button inside it.
##
## This is a stopgap for Phase C.2. Phase C+ replaces the polling model
## with a proper input-owner state machine (@roaster's recommendation).
func is_any_panel_open() -> bool:
	if dialogue_ui != null and dialogue_ui.is_open():
		return true
	if book_viewer != null and book_viewer.is_open():
		return true
	return false
