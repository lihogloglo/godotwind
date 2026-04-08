## NPCInteractable — Morrowind NPC adapter for the Interactable framework
##
## Attach to a streamed NPC Node3D (alongside the character body + mesh).
## When the player presses the "interact" action within range, opens
## DialogueUI with the NPC's speaker_id.
##
## ## Framework/adapter boundary
##
## This file lives in the `morrowind/` subdirectory because it reads
## MW-specific data (NPCRecord, ai_data.hello distance in MW units, MW
## disposition) and wires into the MWDialogueProvider. The Interactable
## base class it extends knows nothing about any of that.
##
## ## Shared references
##
## Provider / context / DialogueUI are NOT stored per-instance — the whole
## reason NPCInteractable exists is to be cheap to stamp onto hundreds of
## streamed NPCs. Shared refs live in `DialogueSession.current()`, set once
## at boot by the main scene. `interact()` pulls them at the moment of use.
##
## ## Usage
##
## ```gdscript
## var npc := <spawned NPC Node3D>
## var interactable := NPCInteractable.new()
## interactable.speaker_id = "fargoth"
## npc.add_child(interactable)
## # A StaticBody3D on collision layer 3 (Interactable) on the same NPC
## # relays raycasts to this Interactable via ancestor walk-up.
## ```
class_name NPCInteractable
extends Interactable

## MW units-per-meter conversion factor. 70 MW units = 1 meter.
## See CLAUDE.md: "Morrowind cell size: ~117m (70 MW units = 1 meter, i.e. 64 units/yard)"
const MW_UNITS_PER_METER: float = 70.0


## ESM speaker identifier (record_id, lowercase).
@export var speaker_id: String = ""


var _cached_npc: NPCRecord = null
var _hello_distance_cached: float = -1.0


func _ready() -> void:
	if speaker_id.is_empty():
		Log.warn("dialogue", "NPCInteractable has no speaker_id")


## Override: enforce the NPC's hello_distance on top of the generic range cap.
func can_interact(player: Node3D, distance: float) -> bool:
	if not super.can_interact(player, distance):
		return false
	var hello := _get_hello_distance_meters()
	if hello > 0.0 and distance > hello:
		return false
	return true


## Override: show NPC name in the prompt.
func get_prompt_text() -> String:
	var npc := _get_npc_record()
	if npc == null or npc.name.is_empty():
		return "Talk to %s" % speaker_id
	return "Talk to %s" % npc.name


## Override: open the DialogueUI with this NPC as speaker.
func interact(player: Node3D) -> void:
	var session := DialogueSession.current()
	if session == null:
		Log.warn("dialogue", "NPCInteractable.interact(): DialogueSession.current() is null — main scene must call DialogueSession.set_current() at boot")
		return
	if session.dialogue_ui == null:
		Log.warn("dialogue", "NPCInteractable.interact(): session.dialogue_ui is null")
		return
	if session.provider == null:
		Log.warn("dialogue", "NPCInteractable.interact(): session.provider is null")
		return
	if session.context == null:
		Log.warn("dialogue", "NPCInteractable.interact(): session.context is null")
		return

	# Sync disposition from the NPCRecord to the context before opening.
	# In a real game this would go through the derived disposition formula
	# (see docs/TEXT_DIALOGUE_SYSTEM.md Phase D.3); for now we use the raw value.
	var npc := _get_npc_record()
	if npc != null:
		session.context.disposition = npc.disposition

	session.dialogue_ui.open(session.provider, speaker_id, session.context)
	# Fire the base class signal so any raycaster listeners can react
	super.interact(player)


## Lookup + cache the NPCRecord for this speaker.
func _get_npc_record() -> NPCRecord:
	if _cached_npc != null:
		return _cached_npc
	if speaker_id.is_empty():
		return null
	var key := speaker_id.to_lower()
	if ESMManager.npcs.has(key):
		_cached_npc = ESMManager.npcs[key] as NPCRecord
		return _cached_npc
	if ESMManager.npcs.has(speaker_id):
		_cached_npc = ESMManager.npcs[speaker_id] as NPCRecord
		return _cached_npc
	return null


## Convert MW hello distance (units) → meters. Returns -1 if no AI data.
func _get_hello_distance_meters() -> float:
	if _hello_distance_cached >= 0.0:
		return _hello_distance_cached
	var npc := _get_npc_record()
	if npc == null or npc.ai_data == null:
		return -1.0
	_hello_distance_cached = float(npc.ai_data.hello) / MW_UNITS_PER_METER
	return _hello_distance_cached
