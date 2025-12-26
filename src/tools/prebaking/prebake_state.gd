## PrebakeState - Persistence for prebaking progress
##
## Saves and loads prebaking state so work can be resumed after interruption.
## State is stored per-component (impostors, meshes, navmeshes, etc.)
##
## Usage:
##   var state := PrebakeState.new()
##   state.load_state()
##   if state.impostors.pending.size() > 0:
##       print("Resuming impostor baking...")
class_name PrebakeState
extends RefCounted

const STATE_FILE := "user://prebake_state.cfg"

## Component state structure
class ComponentState:
	var enabled: bool = true
	var completed: Array = []      # Items successfully baked
	var pending: Array = []        # Items still to bake
	var failed: Array = []         # Items that failed
	var last_baked: String = ""    # Last successfully baked item
	var start_time: int = 0        # Unix timestamp when started
	var end_time: int = 0          # Unix timestamp when finished
	var total_time_ms: int = 0     # Total time spent baking

	func get_progress() -> float:
		var total := completed.size() + pending.size() + failed.size()
		if total == 0:
			return 0.0
		return float(completed.size()) / float(total)

	func is_complete() -> bool:
		return pending.is_empty() and (completed.size() > 0 or failed.size() > 0)

	func reset() -> void:
		completed.clear()
		pending.clear()
		failed.clear()
		last_baked = ""
		start_time = 0
		end_time = 0
		total_time_ms = 0

	func to_dict() -> Dictionary:
		return {
			"enabled": enabled,
			"completed": completed.duplicate(),
			"pending": pending.duplicate(),
			"failed": failed.duplicate(),
			"last_baked": last_baked,
			"start_time": start_time,
			"end_time": end_time,
			"total_time_ms": total_time_ms,
		}

	func from_dict(data: Dictionary) -> void:
		enabled = data.get("enabled", true)
		var completed_arr: Array = data.get("completed", [])
		completed = completed_arr.duplicate()
		var pending_arr: Array = data.get("pending", [])
		pending = pending_arr.duplicate()
		var failed_arr: Array = data.get("failed", [])
		failed = failed_arr.duplicate()
		last_baked = data.get("last_baked", "")
		start_time = data.get("start_time", 0)
		end_time = data.get("end_time", 0)
		total_time_ms = data.get("total_time_ms", 0)


## Component states
var terrain := ComponentState.new()
var models := ComponentState.new()
var impostors := ComponentState.new()
var merged_meshes := ComponentState.new()
var navmeshes := ComponentState.new()
var shore_mask := ComponentState.new()
var texture_atlases := ComponentState.new()

## Global state
var version: int = 1
var last_save_time: int = 0
var is_running: bool = false


## Load state from disk
func load_state() -> bool:
	var config := ConfigFile.new()
	var err := config.load(STATE_FILE)
	if err != OK:
		print("PrebakeState: No saved state found (this is normal for first run)")
		return false

	version = config.get_value("global", "version", 1)
	last_save_time = config.get_value("global", "last_save_time", 0)
	is_running = config.get_value("global", "is_running", false)

	_load_component(config, "terrain", terrain)
	_load_component(config, "models", models)
	_load_component(config, "impostors", impostors)
	_load_component(config, "merged_meshes", merged_meshes)
	_load_component(config, "navmeshes", navmeshes)
	_load_component(config, "shore_mask", shore_mask)
	_load_component(config, "texture_atlases", texture_atlases)

	print("PrebakeState: Loaded state from %s" % STATE_FILE)
	_print_summary()
	return true


## Save state to disk
func save_state() -> bool:
	var config := ConfigFile.new()

	config.set_value("global", "version", version)
	config.set_value("global", "last_save_time", Time.get_unix_time_from_system())
	config.set_value("global", "is_running", is_running)

	_save_component(config, "terrain", terrain)
	_save_component(config, "models", models)
	_save_component(config, "impostors", impostors)
	_save_component(config, "merged_meshes", merged_meshes)
	_save_component(config, "navmeshes", navmeshes)
	_save_component(config, "shore_mask", shore_mask)
	_save_component(config, "texture_atlases", texture_atlases)

	var err := config.save(STATE_FILE)
	if err != OK:
		push_error("PrebakeState: Failed to save state: %d" % err)
		return false

	last_save_time = Time.get_unix_time_from_system()
	return true


## Clear all state (start fresh)
func clear_state() -> void:
	terrain.reset()
	models.reset()
	impostors.reset()
	merged_meshes.reset()
	navmeshes.reset()
	shore_mask.reset()
	texture_atlases.reset()
	is_running = false

	# Delete state file
	if FileAccess.file_exists(STATE_FILE):
		DirAccess.remove_absolute(STATE_FILE)

	print("PrebakeState: Cleared all state")


## Check if any component has pending work
func has_pending_work() -> bool:
	return (
		not terrain.pending.is_empty() or
		not models.pending.is_empty() or
		not impostors.pending.is_empty() or
		not merged_meshes.pending.is_empty() or
		not navmeshes.pending.is_empty() or
		not shore_mask.pending.is_empty() or
		not texture_atlases.pending.is_empty()
	)


## Get overall progress (0.0 - 1.0)
func get_overall_progress() -> float:
	var components := [terrain, models, impostors, merged_meshes, navmeshes, shore_mask, texture_atlases]
	var enabled_components := components.filter(func(c: ComponentState) -> bool: return c.enabled)

	if enabled_components.is_empty():
		return 0.0

	var total_progress := 0.0
	for c: ComponentState in enabled_components:
		total_progress += c.get_progress()

	return total_progress / float(enabled_components.size())


## Get summary dictionary
func get_summary() -> Dictionary:
	return {
		"terrain": terrain.to_dict(),
		"models": models.to_dict(),
		"impostors": impostors.to_dict(),
		"merged_meshes": merged_meshes.to_dict(),
		"navmeshes": navmeshes.to_dict(),
		"shore_mask": shore_mask.to_dict(),
		"texture_atlases": texture_atlases.to_dict(),
		"overall_progress": get_overall_progress(),
		"has_pending": has_pending_work(),
		"is_running": is_running,
	}


func _load_component(config: ConfigFile, section: String, state: ComponentState) -> void:
	if not config.has_section(section):
		return

	state.enabled = config.get_value(section, "enabled", true)
	state.completed = config.get_value(section, "completed", [])
	state.pending = config.get_value(section, "pending", [])
	state.failed = config.get_value(section, "failed", [])
	state.last_baked = config.get_value(section, "last_baked", "")
	state.start_time = config.get_value(section, "start_time", 0)
	state.end_time = config.get_value(section, "end_time", 0)
	state.total_time_ms = config.get_value(section, "total_time_ms", 0)


func _save_component(config: ConfigFile, section: String, state: ComponentState) -> void:
	config.set_value(section, "enabled", state.enabled)
	config.set_value(section, "completed", state.completed)
	config.set_value(section, "pending", state.pending)
	config.set_value(section, "failed", state.failed)
	config.set_value(section, "last_baked", state.last_baked)
	config.set_value(section, "start_time", state.start_time)
	config.set_value(section, "end_time", state.end_time)
	config.set_value(section, "total_time_ms", state.total_time_ms)


func _print_summary() -> void:
	print("  Terrain: %d completed, %d pending, %d failed" % [
		terrain.completed.size(), terrain.pending.size(), terrain.failed.size()])
	print("  Models: %d completed, %d pending, %d failed" % [
		models.completed.size(), models.pending.size(), models.failed.size()])
	print("  Impostors: %d completed, %d pending, %d failed" % [
		impostors.completed.size(), impostors.pending.size(), impostors.failed.size()])
	print("  Merged Meshes: %d completed, %d pending, %d failed" % [
		merged_meshes.completed.size(), merged_meshes.pending.size(), merged_meshes.failed.size()])
	print("  Navmeshes: %d completed, %d pending, %d failed" % [
		navmeshes.completed.size(), navmeshes.pending.size(), navmeshes.failed.size()])
	print("  Shore Mask: %s" % ("complete" if shore_mask.is_complete() else "pending"))
