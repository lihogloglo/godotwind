## TestNPCLoader — Loads prebaked test NPCs for fast test startup
##
## Usage:
##   var npc := TestNPCLoader.load_test_npc("fargoth")
##   if npc:
##       add_child(npc)
##   else:
##       # Fall back to full pipeline
##       ...
class_name TestNPCLoader
extends RefCounted

const PREBAKE_DIR := "res://tests/data/"
const PREBAKE_SUFFIX := ".scn"


## Check if a prebaked NPC exists
static func has_prebaked(npc_id: String) -> bool:
	var path := _get_prebake_path(npc_id)
	return ResourceLoader.exists(path)


## Load a prebaked NPC scene, returns the root node or null
static func load_test_npc(npc_id: String) -> Node:
	var path := _get_prebake_path(npc_id)
	if not ResourceLoader.exists(path):
		return null

	var packed: PackedScene = ResourceLoader.load(path) as PackedScene
	if not packed:
		push_warning("TestNPCLoader: Failed to load prebaked NPC: %s" % path)
		return null

	var instance: Node = packed.instantiate()
	if not instance:
		push_warning("TestNPCLoader: Failed to instantiate prebaked NPC: %s" % path)
		return null

	return instance


## Get the file path for a prebaked NPC
static func _get_prebake_path(npc_id: String) -> String:
	return PREBAKE_DIR + "test_npc_" + npc_id.to_lower() + PREBAKE_SUFFIX
