## SubsystemToggles — Unified feature flag system for A/B benchmarking
##
## Single dict of bools controlling major rendering subsystems. Console commands
## `toggle <name>`, `toggle list`, `toggle only <name>`, `toggle all`, `toggle none`.
##
## Each flag routes through the owning subsystem's API — no internal reach-around.
## Benchmark harness uses set_flag() / get_flag() / set_all() programmatically.
##
## Usage:
##   var toggles := SubsystemToggles.new()
##   toggles.setup(callbacks)  # Wire to world_explorer subsystems
##   toggles.register_commands(console)
##   toggles.set_flag("terrain", false)  # Disable terrain
class_name SubsystemToggles
extends RefCounted

signal flag_changed(name: String, enabled: bool)

## Flag registry: name -> bool (current state)
var _flags: Dictionary = {}

## Apply callbacks: name -> Callable(bool)
## Each callable toggles the actual subsystem on/off
var _apply: Dictionary = {}

## Default states (for reset)
var _defaults: Dictionary = {}


## Initialize with subsystem callbacks.
## callbacks dict maps flag name -> Callable(bool) that applies the toggle.
## defaults dict maps flag name -> bool for initial state.
func setup(callbacks: Dictionary, defaults: Dictionary) -> void:
	for name: String in callbacks:
		_apply[name] = callbacks[name]
		var default_val: bool = defaults.get(name, true)
		_defaults[name] = default_val
		_flags[name] = default_val
		_apply[name].call(default_val)


## Get current state of a flag
func get_flag(name: String) -> bool:
	return _flags.get(name, false)


## Set a flag and apply it
func set_flag(name: String, enabled: bool) -> void:
	if name not in _flags:
		Log.warn("toggles", "Unknown subsystem: %s" % name)
		return
	if _flags[name] == enabled:
		return
	_flags[name] = enabled
	if name in _apply:
		_apply[name].call(enabled)
	flag_changed.emit(name, enabled)


## Toggle a flag (flip current state)
func toggle_flag(name: String) -> void:
	if name not in _flags:
		Log.warn("toggles", "Unknown subsystem: %s" % name)
		return
	set_flag(name, not _flags[name])


## Enable all flags
func enable_all() -> void:
	for name: String in _flags:
		set_flag(name, true)


## Disable all flags
func disable_all() -> void:
	for name: String in _flags:
		set_flag(name, false)


## Enable ONLY the named flag, disable everything else
func isolate(name: String) -> void:
	if name not in _flags:
		Log.warn("toggles", "Unknown subsystem: %s" % name)
		return
	for flag_name: String in _flags:
		set_flag(flag_name, flag_name == name)


## Reset all flags to defaults
func reset() -> void:
	for name: String in _defaults:
		set_flag(name, _defaults[name])


## Get all flag names
func get_flag_names() -> Array[String]:
	var names: Array[String] = []
	for name: String in _flags:
		names.append(name)
	names.sort()
	return names


## Get summary dict (for JSON export / benchmark metadata)
func get_state() -> Dictionary:
	return _flags.duplicate()


## Register console commands
func register_commands(console: Node) -> void:
	var params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("action", TYPE_STRING, "name|list|all|none|only|reset", false, "list"),
	]
	console.register_command(
		"toggle",
		_cmd_toggle,
		"Toggle subsystem on/off. Usage: toggle <name|list|all|none|only <name>|reset>",
		"benchmark",
		PackedStringArray(["t"]),
		params,
		PackedStringArray(["toggle terrain", "toggle list", "toggle only ocean", "toggle none"]),
	)


func _cmd_toggle(args: Dictionary) -> String:
	var action_raw: String = args.get("action", "list")
	# "only terrain" comes as one string because the console concatenates overflow args
	var parts: PackedStringArray = action_raw.strip_edges().to_lower().split(" ", false)
	if parts.is_empty():
		return _get_list_string()

	var subcmd: String = parts[0]

	match subcmd:
		"list":
			return _get_list_string()
		"all":
			enable_all()
			return "All subsystems ON"
		"none":
			disable_all()
			return "All subsystems OFF"
		"reset":
			reset()
			return "All subsystems reset to defaults"
		"only":
			if parts.size() < 2:
				return "Usage: toggle only <name>"
			var name: String = parts[1]
			if name not in _flags:
				return "Unknown: '%s'. Use 'toggle list'." % name
			isolate(name)
			return "Isolated: only %s ON" % name
		_:
			# Treat as toggle name
			var name: String = subcmd
			if name not in _flags:
				return "Unknown: '%s'. Use 'toggle list'." % name
			toggle_flag(name)
			return "%s: %s" % [name, "ON" if _flags[name] else "OFF"]
	return ""


func _get_list_string() -> String:
	var names := get_flag_names()
	var lines: PackedStringArray = PackedStringArray()
	lines.append("=== Subsystem Toggles ===")
	for name: String in names:
		var marker: String = "[color=green]ON [/color]" if _flags[name] else "[color=red]OFF[/color]"
		lines.append("  %s %s" % [marker, name])
	return "\n".join(lines)
