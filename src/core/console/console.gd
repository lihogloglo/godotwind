## Console - Main developer console controller
##
## The central console system that coordinates:
## - Console UI display
## - Command registration and execution
## - Object picking
## - Context management (selection, variables)
##
## Usage:
##   var console = preload("res://src/core/console/console.gd").new()
##   add_child(console)
##   console.register_context("player", player_node)
class_name Console
extends Node


#region Signals

## Emitted when console visibility changes
signal visibility_changed(is_visible: bool)

## Emitted when an object is selected
signal object_selected(selection: ObjectPicker.Selection)

## Emitted when selection is cleared
signal selection_cleared

#endregion


#region Constants

## Hotkey to toggle console (tilde/backtick)
const TOGGLE_KEY := KEY_QUOTELEFT

## Version string
const VERSION := "0.1.0"

#endregion


#region Node References

var ui: ConsoleUI
var picker: ObjectPicker
var registry: CommandRegistry

#endregion


#region Context

## Named context objects that commands can access
var _context: Dictionary = {}  # String -> Variant

## Console session variables
var _variables: Dictionary = {}  # String -> Variant

## Current camera (for picker)
var _camera: Camera3D = null

#endregion


func _ready() -> void:
	name = "Console"

	# Create command registry
	registry = CommandRegistry.new()

	# Create UI
	ui = ConsoleUI.new()
	ui.name = "ConsoleUI"
	add_child(ui)

	# Create object picker
	picker = ObjectPicker.new()
	picker.name = "ObjectPicker"
	add_child(picker)

	# Connect signals
	ui.command_submitted.connect(_on_command_submitted)
	ui.console_visibility_changed.connect(func(v: bool) -> void: visibility_changed.emit(v))
	ui.autocomplete_requested.connect(_on_autocomplete_requested)

	picker.object_selected.connect(_on_object_selected)
	picker.selection_cleared.connect(_on_selection_cleared)
	picker.picker_mode_entered.connect(func() -> void: ui.print_line("[color=yellow]Click on an object to select it...[/color]"))
	picker.picker_mode_exited.connect(func() -> void: pass)

	# Enable hover + tooltip when console is visible, disable when hidden
	ui.console_visibility_changed.connect(_on_console_visibility_for_picker)

	# Register built-in commands
	_register_builtin_commands()

	# Print welcome message when first shown
	ui.console_visibility_changed.connect(func(visible: bool) -> void:
		if visible and ui.output_text.get_total_character_count() == 0:
			_print_welcome()
	, CONNECT_ONE_SHOT)


func _input(event: InputEvent) -> void:
	# Toggle console with tilde key (or ² on AZERTY keyboards)
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed:
			# KEY_QUOTELEFT is tilde on QWERTY, check physical key or unicode for AZERTY ²
			if key.keycode == TOGGLE_KEY or key.physical_keycode == KEY_QUOTELEFT or key.unicode == 178:  # 178 = ²
				toggle()
				get_viewport().set_input_as_handled()


## Toggle console visibility
func toggle() -> void:
	ui.toggle()


## Show the console
func show() -> void:
	ui.show_console()


## Hide the console
func hide() -> void:
	ui.hide_console()


## Check if console is visible
func is_visible() -> bool:
	return ui.is_console_visible()


## Set the camera for object picking
func set_camera(cam: Camera3D) -> void:
	_camera = cam
	picker.set_camera(cam)


## Register a context object that commands can access
func register_context(context_name: String, obj: Variant) -> void:
	_context[context_name] = obj

	# When the streaming manager is registered, wire up the cell provider for picking
	if context_name == "world" and obj is Object:
		var world_obj: Object = obj
		if world_obj.has_method("get_loaded_cell_nodes"):
			picker.set_cell_provider(Callable(world_obj, "get_loaded_cell_nodes"))


## Get a context object
func get_context(name: String) -> Variant:
	return _context.get(name)


## Register a custom command
func register_command(
	name: String,
	callback: Callable,
	description: String = "",
	category: String = "misc",
	aliases: PackedStringArray = PackedStringArray(),
	parameters: Array[CommandRegistry.ParameterInfo] = [],
	examples: PackedStringArray = PackedStringArray()
) -> void:
	registry.register(name, callback, description, category, aliases, parameters, examples)


## Execute a command string
func execute(command_string: String) -> void:
	_on_command_submitted(command_string)


## Print to console
func print_line(text: String) -> void:
	ui.print_line(text)


## Print success
func print_success(text: String) -> void:
	ui.print_success(text)


## Print warning
func print_warning(text: String) -> void:
	ui.print_warning(text)


## Print error
func print_error(text: String) -> void:
	ui.print_error(text)


## Clear console output
func clear() -> void:
	ui.clear_output()


## Get current selection
func get_selection() -> ObjectPicker.Selection:
	return picker.current_selection


## Enter object selection mode
func start_selection() -> void:
	picker.enter_picker_mode()


## Clear selection
func clear_selection() -> void:
	picker.clear_selection()


#region Private Methods

## Print welcome message
func _print_welcome() -> void:
	ui.print_line("[b]Godotwind Console v%s[/b]" % VERSION)
	ui.print_line("Type [color=cyan]help[/color] for available commands.")
	ui.print_line("Press [color=cyan]~[/color] to toggle, [color=cyan]ESC[/color] to close.")
	ui.print_line("")


## Handle autocomplete request from UI
func _on_autocomplete_requested(text: String) -> void:
	# Get the first word (command being typed)
	var parts := text.split(" ", false, 1)
	var prefix := parts[0].to_lower() if parts.size() > 0 else ""

	if prefix.is_empty():
		ui.hide_suggestions()
		return

	# If we already have a complete command followed by space, don't show command suggestions
	# (Future: could show parameter suggestions here)
	if parts.size() > 1 and registry.has_command(prefix):
		ui.hide_suggestions()
		return

	# Find matching commands
	var matches := registry.find_commands_fuzzy(prefix, 8)

	if matches.is_empty():
		ui.hide_suggestions()
		return

	# Convert to suggestion format
	var suggestions: Array[Dictionary] = []
	for cmd in matches:
		suggestions.append({
			"name": cmd.name,
			"description": cmd.description,
			"aliases": cmd.aliases
		})

	ui.set_suggestions(suggestions)


## Handle command submission from UI
func _on_command_submitted(cmd_string: String) -> void:
	# Skip empty or comment lines
	var trimmed := cmd_string.strip_edges()
	if trimmed.is_empty() or trimmed.begins_with("#"):
		return

	# Parse command and arguments
	var parts := trimmed.split(" ", false, 1)
	var cmd_name := parts[0].to_lower()
	var args_string := parts[1] if parts.size() > 1 else ""

	# Look up command
	var cmd := registry.get_command(cmd_name)
	if not cmd:
		ui.print_error("Unknown command: %s" % cmd_name)
		ui.print_line("Type [color=cyan]help[/color] to see available commands.")
		return

	# Parse arguments
	var parsed := registry.parse_arguments(cmd, args_string)
	if not parsed.success:
		var error_msg: String = parsed.error
		ui.print_error(error_msg)
		ui.print_line("[color=gray]Usage: %s[/color]" % cmd.get_usage())
		return

	# Execute command
	var result: Variant = null
	if cmd.callback.is_valid():
		result = cmd.callback.call(parsed.args)
	else:
		result = CommandRegistry.CommandResult.error("Command callback is invalid")

	# Display result - handle both String and CommandResult returns
	if result is String:
		# Legacy: commands returning String directly
		if not result.is_empty():
			ui.print_line(result)
	elif result is CommandRegistry.CommandResult:
		if result.success:
			if not result.message.is_empty():
				ui.print_line(result.message)
		else:
			ui.print_error(result.message)


## Handle object selection
func _on_object_selected(selection: ObjectPicker.Selection) -> void:
	# Update UI
	ui.show_selection(picker.get_selection_info())

	# Store in context
	_context["selected"] = selection

	# Print selection info
	ui.print_line("")
	ui.print_line("[color=#FFB300][b]Selected:[/b][/color] [%s] %s" % [
		selection.get_type_display(),
		selection.get_display_name()
	])
	ui.print_line("  Position: %s" % selection.get_position_string())
	if not selection.cell_name.is_empty():
		ui.print_line("  Cell: %s" % selection.get_cell_string())
	if not selection.model_path.is_empty():
		ui.print_line("  Model: %s" % selection.model_path)

	object_selected.emit(selection)


## Handle selection cleared
func _on_selection_cleared() -> void:
	ui.hide_selection()
	_context.erase("selected")
	selection_cleared.emit()


## Enable/disable hover picking when console opens/closes
func _on_console_visibility_for_picker(visible: bool) -> void:
	picker.set_hover_enabled(visible)
	# Pass the console panel reference so picker can dynamically check its rect
	if not picker._console_panel:
		picker.set_console_panel(ui.panel)


## Register all built-in commands
func _register_builtin_commands() -> void:
	# System commands
	registry.register("help", _cmd_help, "Show help for commands", "system",
		PackedStringArray(["?"]),
		[CommandRegistry.ParameterInfo.new("command", TYPE_STRING, "Command to get help for", false)])

	registry.register("clear", _cmd_clear, "Clear console output", "system",
		PackedStringArray(["cls"]))

	registry.register("version", _cmd_version, "Show console version", "system")

	registry.register("echo", _cmd_echo, "Print a message", "system",
		PackedStringArray(["print"]),
		[CommandRegistry.ParameterInfo.new("message", TYPE_STRING, "Message to print")])

	# Selection commands
	registry.register("select", _cmd_select, "Enter object selection mode", "inspect",
		PackedStringArray(["sel", "pick"]))

	registry.register("deselect", _cmd_deselect, "Clear current selection", "inspect",
		PackedStringArray(["unselect", "clear_selection"]))

	registry.register("inspect", _cmd_inspect, "Show detailed info about selection or object", "inspect",
		PackedStringArray(["info", "i"]),
		[CommandRegistry.ParameterInfo.new("target", TYPE_STRING, "Object to inspect (default: selection)", false)])

	# Navigation commands
	registry.register("tp", _cmd_teleport, "Teleport to a location", "navigation",
		PackedStringArray(["teleport", "goto", "warp"]),
		[CommandRegistry.ParameterInfo.new("target", TYPE_STRING, "Cell name, coordinates, or 'selected'")],
		PackedStringArray(["tp seyda_neen", "tp -2,-9", "tp selected"]))

	registry.register("pos", _cmd_pos, "Show current position", "navigation",
		PackedStringArray(["position", "where"]))

	# World commands
	registry.register("cells", _cmd_cells, "List loaded cells", "world")

	registry.register("stats", _cmd_stats, "Show/hide performance stats", "debug",
		PackedStringArray(["perf"]),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on/off/toggle", false, "toggle")])

	# Variables
	registry.register("set", _cmd_set, "Set a variable", "system",
		PackedStringArray(["var"]),
		[
			CommandRegistry.ParameterInfo.new("name", TYPE_STRING, "Variable name"),
			CommandRegistry.ParameterInfo.new("value", TYPE_STRING, "Value to set")
		])

	registry.register("get", _cmd_get, "Get a variable value", "system",
		[CommandRegistry.ParameterInfo.new("name", TYPE_STRING, "Variable name")])

	registry.register("vars", _cmd_vars, "List all variables", "system",
		PackedStringArray(["variables"]))

	# Distant rendering debug commands
	registry.register("tier_debug", _cmd_tier_debug, "Show distance tier debug info", "debug",
		PackedStringArray(["tiers"]),
		[CommandRegistry.ParameterInfo.new("verbose", TYPE_STRING, "Show detailed cell info (on/off)", false, "off")])

	registry.register("distant_toggle", _cmd_distant_toggle, "Toggle distant rendering on/off", "debug",
		PackedStringArray(["distant", "far_render"]),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on/off/toggle", false, "toggle")])

	registry.register("distant_stats", _cmd_distant_stats, "Show distant rendering statistics", "debug",
		PackedStringArray(["far_stats"]))

	registry.register("impostor_debug", _cmd_impostor_debug, "Show detailed impostor system diagnostics", "debug",
		PackedStringArray(["imp_debug", "impostor_diag"]))

	registry.register("impostor_verbose", _cmd_impostor_verbose, "Toggle verbose impostor debug logging", "debug",
		PackedStringArray(["imp_verbose"]),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on/off", false, "on")])

	registry.register("impostor_show", _cmd_impostor_show, "Toggle impostor shader debug (shows magenta at ANY distance)", "debug",
		PackedStringArray(["imp_show"]),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on/off", false, "on")])

	registry.register("impostor_dump", _cmd_impostor_dump, "Dump detailed impostor renderer state to console", "debug",
		PackedStringArray(["imp_dump"]))

	# Ocean debug commands
	registry.register("ocean_debug", _cmd_ocean_debug, "Toggle ocean shore mask debug visualization", "debug",
		PackedStringArray(["shore_debug", "water_debug"]),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on/off/toggle", false, "toggle")])

	registry.register("ocean_info", _cmd_ocean_info, "Show ocean and shore mask information", "debug",
		PackedStringArray(["water_info", "shore_info"]))

	registry.register("ocean_fade", _cmd_ocean_fade, "Set/get shore fade distance", "debug",
		PackedStringArray(["shore_fade"]),
		[CommandRegistry.ParameterInfo.new("distance", TYPE_STRING, "Fade distance in meters (or empty to show current)", false, "")],
		PackedStringArray(["ocean_fade", "ocean_fade 200"]))


#endregion


#region Built-in Command Implementations

func _cmd_help(args: Dictionary) -> CommandRegistry.CommandResult:
	var cmd_name: String = args.get("command", "")
	if cmd_name.is_empty():
		return CommandRegistry.CommandResult.ok(registry.get_full_help())

	var cmd := registry.get_command(cmd_name)
	if cmd:
		return CommandRegistry.CommandResult.ok(registry.get_help_text(cmd))
	return CommandRegistry.CommandResult.error("Unknown command: %s" % cmd_name)


func _cmd_clear(_args: Dictionary) -> CommandRegistry.CommandResult:
	ui.clear_output()
	return CommandRegistry.CommandResult.ok()


func _cmd_version(_args: Dictionary) -> CommandRegistry.CommandResult:
	return CommandRegistry.CommandResult.ok("Godotwind Console v%s" % VERSION)


func _cmd_echo(args: Dictionary) -> CommandRegistry.CommandResult:
	var message: String = args.get("message", "")
	return CommandRegistry.CommandResult.ok(message)


func _cmd_select(_args: Dictionary) -> CommandRegistry.CommandResult:
	if not _camera:
		return CommandRegistry.CommandResult.error("No camera set - cannot pick objects")

	picker.enter_picker_mode()
	return CommandRegistry.CommandResult.ok()


func _cmd_deselect(_args: Dictionary) -> CommandRegistry.CommandResult:
	picker.clear_selection()
	return CommandRegistry.CommandResult.ok("Selection cleared")


func _cmd_inspect(args: Dictionary) -> CommandRegistry.CommandResult:
	var target: String = args.get("target", "")

	if target.is_empty():
		# Inspect current selection
		var sel := picker.current_selection
		if not sel:
			return CommandRegistry.CommandResult.error("Nothing selected. Use 'select' to pick an object.")

		return CommandRegistry.CommandResult.ok(picker.get_selection_info())

	# Object lookup by name/ID not yet implemented — use 'select' to pick visually
	return CommandRegistry.CommandResult.error("Object lookup not yet implemented. Use 'select' to pick an object.")


func _cmd_teleport(args: Dictionary) -> CommandRegistry.CommandResult:
	var target: String = args.get("target", "")

	if target.is_empty():
		return CommandRegistry.CommandResult.error("Specify a target: cell name, x,y coordinates, or 'selected'")

	# Check for "selected"
	if target.to_lower() == "selected":
		var sel := picker.current_selection
		if not sel:
			return CommandRegistry.CommandResult.error("Nothing selected")

		# Teleport to selection - needs camera/player context
		var player: Variant = _context.get("player")
		var camera: Variant = _context.get("camera")

		if player is Object:
			var player_obj: Object = player
			if player_obj.has_method("teleport_to"):
				player_obj.call("teleport_to", sel.hit_position + Vector3(0, 2, 0))
				return CommandRegistry.CommandResult.ok("Teleported to selection")
		if camera is Camera3D:
			var cam: Camera3D = camera
			cam.global_position = sel.hit_position + Vector3(0, 50, 50)
			cam.look_at(sel.hit_position)
			return CommandRegistry.CommandResult.ok("Teleported camera to selection")

		return CommandRegistry.CommandResult.error("No player or camera in context")

	# Check for coordinates (x,y or x,y,z)
	if "," in target:
		var parts: PackedStringArray = target.split(",")
		if parts.size() >= 2:
			var x: float = parts[0].strip_edges().to_float()
			var y: float = parts[1].strip_edges().to_float()
			var z: float = parts[2].strip_edges().to_float() if parts.size() > 2 else 0.0

			if parts.size() == 2:
				return CommandRegistry.CommandResult.ok("Would teleport to cell (%d, %d)" % [int(x), int(y)])

			# World coordinates
			var player2: Variant = _context.get("player")
			var camera2: Variant = _context.get("camera")

			if player2 is Object:
				var player2_obj: Object = player2
				if player2_obj.has_method("teleport_to"):
					player2_obj.call("teleport_to", Vector3(x, y, z))
					return CommandRegistry.CommandResult.ok("Teleported to (%.1f, %.1f, %.1f)" % [x, y, z])
			if camera2 is Camera3D:
				var cam: Camera3D = camera2
				cam.global_position = Vector3(x, y, z)
				return CommandRegistry.CommandResult.ok("Teleported camera to (%.1f, %.1f, %.1f)" % [x, y, z])

			return CommandRegistry.CommandResult.error("No player or camera in context")

	# Assume it's a cell name - would need ESMManager integration
	return CommandRegistry.CommandResult.ok("Would teleport to cell: %s" % target)


func _cmd_pos(_args: Dictionary) -> CommandRegistry.CommandResult:
	var player: Variant = _context.get("player")
	var camera: Variant = _context.get("camera")

	var pos: Vector3
	if player and player is Node3D:
		pos = (player as Node3D).global_position
	elif camera and camera is Camera3D:
		pos = (camera as Camera3D).global_position
	else:
		return CommandRegistry.CommandResult.error("No player or camera in context")

	return CommandRegistry.CommandResult.ok("Position: (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z])


func _cmd_cells(_args: Dictionary) -> CommandRegistry.CommandResult:
	var world: Variant = _context.get("world")
	if not world:
		return CommandRegistry.CommandResult.error("No world streaming manager in context")

	if not world is Object:
		return CommandRegistry.CommandResult.error("World manager is not a valid object")

	var world_obj: Object = world
	if not world_obj.has_method("get_loaded_cell_coordinates"):
		return CommandRegistry.CommandResult.error("World manager doesn't support cell listing")

	var coords: Array = world_obj.call("get_loaded_cell_coordinates")
	var lines: PackedStringArray = ["Loaded cells (%d):" % coords.size()]
	for coord: Variant in coords:
		if coord is Vector2i:
			lines.append("  (%d, %d)" % [coord.x, coord.y])
	return CommandRegistry.CommandResult.ok("\n".join(lines))


func _cmd_stats(args: Dictionary) -> CommandRegistry.CommandResult:
	var state: String = args.get("state", "toggle")

	# This would need integration with the explorer's stats panel
	return CommandRegistry.CommandResult.ok("Stats: %s (would toggle stats panel)" % state)


func _cmd_set(args: Dictionary) -> CommandRegistry.CommandResult:
	var name: String = args.get("name", "")
	var value: String = args.get("value", "")

	if name.is_empty():
		return CommandRegistry.CommandResult.error("Variable name required")

	_variables[name] = value
	return CommandRegistry.CommandResult.ok("%s = %s" % [name, value])


func _cmd_get(args: Dictionary) -> CommandRegistry.CommandResult:
	var name: String = args.get("name", "")

	if name.is_empty():
		return CommandRegistry.CommandResult.error("Variable name required")

	if _variables.has(name):
		return CommandRegistry.CommandResult.ok("%s = %s" % [name, _variables[name]])
	else:
		return CommandRegistry.CommandResult.error("Variable not found: %s" % name)


func _cmd_vars(_args: Dictionary) -> CommandRegistry.CommandResult:
	if _variables.is_empty():
		return CommandRegistry.CommandResult.ok("No variables set")

	var lines: PackedStringArray = ["Variables:"]
	for name: String in _variables:
		lines.append("  %s = %s" % [name, _variables[name]])

	return CommandRegistry.CommandResult.ok("\n".join(lines))


func _cmd_tier_debug(args: Dictionary) -> CommandRegistry.CommandResult:
	var world: Variant = _context.get("world")
	var verbose: String = args.get("verbose", "off")

	if not world or not world is Object:
		return CommandRegistry.CommandResult.error("No world streaming manager in context")

	var world_obj: Object = world as Object

	# Try to get tier manager from world
	var tier_manager: Variant = null
	if world_obj.has_method("get_tier_manager"):
		tier_manager = world_obj.call("get_tier_manager")
	elif "tier_manager" in world_obj:
		tier_manager = world_obj.get("tier_manager")

	if not tier_manager or not tier_manager is Object:
		return CommandRegistry.CommandResult.error("No distance tier manager found")

	var tier_obj: Object = tier_manager as Object
	var lines: PackedStringArray = ["[b]Distance Tier Debug Info[/b]"]

	# Get debug info from tier manager
	if tier_obj.has_method("get_debug_info"):
		var debug_info: Dictionary = tier_obj.call("get_debug_info")

		lines.append("Distant rendering: %s" % ("enabled" if debug_info.get("enabled", false) else "disabled"))
		lines.append("Max view distance: %.0fm" % debug_info.get("max_view_distance", 0))
		lines.append("Cell size: %.1fm" % debug_info.get("cell_size_meters", 117))
		lines.append("Tracked cells: %d" % debug_info.get("tracked_cells", 0))

		lines.append("")
		lines.append("[b]Tier Distances:[/b]")
		var distances: Dictionary = debug_info.get("tier_distances", {})
		for tier: int in distances:
			var tier_name := _tier_to_string(tier)
			lines.append("  %s: %.0fm" % [tier_name, distances[tier]])

	# Show cell counts by tier if verbose
	if verbose.to_lower() == "on":
		lines.append("")
		lines.append("[b]Cells by Tier:[/b]")

		if tier_obj.has_method("get_tier_cell_counts"):
			var camera: Variant = _context.get("camera")
			if camera and camera is Camera3D:
				# Get camera cell (would need coordinate system)
				var counts: Dictionary = tier_obj.call("get_tier_cell_counts", Vector2i.ZERO)
				for tier: int in counts:
					var tier_name := _tier_to_string(tier)
					lines.append("  %s: %d cells" % [tier_name, counts[tier]])

	return CommandRegistry.CommandResult.ok("\n".join(lines))


func _cmd_distant_toggle(args: Dictionary) -> CommandRegistry.CommandResult:
	var world: Variant = _context.get("world")
	var state: String = args.get("state", "toggle")

	if not world or not world is Object:
		return CommandRegistry.CommandResult.error("No world streaming manager in context")

	var world_obj: Object = world as Object

	# Try to get tier manager
	var tier_manager: Variant = null
	if world_obj.has_method("get_tier_manager"):
		tier_manager = world_obj.call("get_tier_manager")
	elif "tier_manager" in world_obj:
		tier_manager = world_obj.get("tier_manager")

	if not tier_manager or not tier_manager is Object:
		return CommandRegistry.CommandResult.error("No distance tier manager found")

	var tier_obj: Object = tier_manager as Object

	# Determine new state
	var new_enabled: bool
	match state.to_lower():
		"on", "true", "1", "enabled":
			new_enabled = true
		"off", "false", "0", "disabled":
			new_enabled = false
		_:  # toggle
			new_enabled = not tier_obj.get("distant_rendering_enabled")

	# Apply state
	tier_obj.set("distant_rendering_enabled", new_enabled)

	return CommandRegistry.CommandResult.ok("Distant rendering: %s" % ("enabled" if new_enabled else "disabled"))


func _cmd_distant_stats(_args: Dictionary) -> CommandRegistry.CommandResult:
	var world: Variant = _context.get("world")

	if not world or not world is Object:
		return CommandRegistry.CommandResult.error("No world streaming manager in context")

	var world_obj: Object = world as Object
	var lines: PackedStringArray = ["[b]Distant Rendering Statistics[/b]"]

	# Try to get distant static renderer
	var distant_renderer: Variant = null
	if world_obj.has_method("get_distant_renderer"):
		distant_renderer = world_obj.call("get_distant_renderer")
	elif "distant_renderer" in world_obj:
		distant_renderer = world_obj.get("distant_renderer")

	if distant_renderer is Object:
		var renderer_obj: Object = distant_renderer as Object
		if renderer_obj.has_method("get_stats"):
			var stats: Dictionary = renderer_obj.call("get_stats")
			lines.append("")
			lines.append("[color=cyan]MID Tier (Merged Meshes):[/color]")
			lines.append("  Loaded cells: %d" % stats.get("loaded_cells", 0))
			lines.append("  Visible cells: %d" % stats.get("visible_cells", 0))
			lines.append("  Total vertices: %d" % stats.get("total_vertices", 0))
			lines.append("  Total objects: %d" % stats.get("total_objects", 0))

	# Try to get impostor manager
	var impostor_manager: Variant = null
	if world_obj.has_method("get_impostor_manager"):
		impostor_manager = world_obj.call("get_impostor_manager")
	elif "impostor_manager" in world_obj:
		impostor_manager = world_obj.get("impostor_manager")

	if impostor_manager is Object:
		var impostor_obj: Object = impostor_manager as Object
		if impostor_obj.has_method("get_stats"):
			var stats: Dictionary = impostor_obj.call("get_stats")
			lines.append("")
			lines.append("[color=yellow]FAR Tier (Impostors):[/color]")
			lines.append("  Total impostors: %d" % stats.get("total_impostors", 0))
			lines.append("  MultiMesh instances: %d" % stats.get("multimesh_instance_count", 0))
			lines.append("  Texture cache: %d" % stats.get("texture_cache_size", 0))
			lines.append("  Texture array layers: %d" % stats.get("texture_array_layers", 0))
			lines.append("  Loaded cells: %d" % stats.get("loaded_impostor_cells", 0))
			lines.append("  Pending texture loads: %d" % stats.get("pending_texture_loads", 0))
			lines.append("  Pending impostors: %d" % stats.get("pending_impostors", 0))
			# Highlight issues
			var process_enabled: bool = stats.get("process_enabled", true)
			var has_candidates: bool = stats.get("has_candidates", false)
			if not process_enabled:
				lines.append("  [color=red]WARNING: _process() DISABLED - impostors won't update![/color]")
			if not has_candidates:
				lines.append("  [color=red]WARNING: ImpostorCandidates not set![/color]")

	if lines.size() == 1:
		lines.append("No distant rendering components found in world")

	return CommandRegistry.CommandResult.ok("\n".join(lines))


## Helper to convert tier enum to string
func _tier_to_string(tier: int) -> String:
	match tier:
		0: return "NEAR"
		1: return "MID"
		2: return "FAR"
		3: return "HORIZON"
		4: return "NONE"
		_: return "UNKNOWN(%d)" % tier


func _cmd_impostor_debug(_args: Dictionary) -> CommandRegistry.CommandResult:
	var lines: PackedStringArray = ["[b]Impostor System Diagnostics[/b]"]

	# Get world object
	var world: Variant = _context.get("world")
	if not world:
		return CommandRegistry.CommandResult.error("No world context set. Use 'help context' to set up.")

	var world_obj: Object = world as Object

	# Check distant_rendering_enabled setting
	var settings_manager: Variant = get_node_or_null("/root/SettingsManager")
	if settings_manager:
		var distant_enabled: bool = settings_manager.call("get_distant_rendering_enabled") if settings_manager.has_method("get_distant_rendering_enabled") else true
		lines.append("")
		lines.append("[color=cyan]Settings:[/color]")
		lines.append("  distant_rendering_enabled (saved): %s" % ("ON" if distant_enabled else "[color=red]OFF[/color]"))

	# Check streaming manager setting
	if "distant_rendering_enabled" in world_obj:
		var runtime_enabled: bool = world_obj.get("distant_rendering_enabled")
		lines.append("  distant_rendering_enabled (runtime): %s" % ("ON" if runtime_enabled else "[color=red]OFF[/color]"))

	# Get impostor renderer
	var impostor_renderer: Variant = null
	if world_obj.has_method("get_impostor_manager"):
		impostor_renderer = world_obj.call("get_impostor_manager")

	if not impostor_renderer:
		lines.append("")
		lines.append("[color=red]ERROR: No impostor renderer found![/color]")
		lines.append("Check that NativeStreamingManager is set as world context")
		return CommandRegistry.CommandResult.ok("\n".join(lines))

	var renderer: Object = impostor_renderer as Object

	# Core state
	lines.append("")
	lines.append("[color=cyan]Renderer State:[/color]")
	lines.append("  _process() enabled: %s" % ("ON" if renderer.is_processing() else "[color=red]OFF - CRITICAL![/color]"))
	lines.append("  ImpostorCandidates set: %s" % ("YES" if renderer.get("impostor_candidates") != null else "[color=red]NO[/color]"))
	lines.append("  Debug logging: %s" % ("ON" if renderer.get("debug_enabled") else "OFF"))

	# Stats
	if renderer.has_method("get_stats"):
		var stats: Dictionary = renderer.call("get_stats")
		lines.append("")
		lines.append("[color=cyan]Impostor Data:[/color]")
		lines.append("  Total impostors: %d" % stats.get("total_impostors", 0))
		lines.append("  MultiMesh instances: %d" % stats.get("multimesh_instance_count", 0))
		lines.append("  Loaded cells: %d" % stats.get("loaded_impostor_cells", 0))
		lines.append("")
		lines.append("[color=cyan]Texture System:[/color]")
		lines.append("  Texture cache size: %d" % stats.get("texture_cache_size", 0))
		lines.append("  Texture array layers: %d" % stats.get("texture_array_layers", 0))
		lines.append("  Pending texture loads: %d" % stats.get("pending_texture_loads", 0))
		lines.append("  Pending impostors: %d" % stats.get("pending_impostors", 0))

	# Check impostor texture directory
	lines.append("")
	lines.append("[color=cyan]Impostor Textures:[/color]")
	if settings_manager and settings_manager.has_method("get_impostors_path"):
		var imp_path: String = settings_manager.call("get_impostors_path")
		lines.append("  Directory: %s" % imp_path)
		if DirAccess.dir_exists_absolute(imp_path):
			var files := DirAccess.get_files_at(imp_path)
			var png_count := 0
			var json_count := 0
			for f: String in files:
				if f.ends_with(".png"):
					png_count += 1
				elif f.ends_with(".json"):
					json_count += 1
			lines.append("  PNG textures: %d" % png_count)
			lines.append("  JSON metadata: %d" % json_count)
			if png_count == 0:
				lines.append("  [color=yellow]WARNING: No impostor textures found! Run prebaking.[/color]")
		else:
			lines.append("  [color=red]ERROR: Directory does not exist![/color]")
	else:
		lines.append("  [color=red]ERROR: Cannot determine impostor path[/color]")

	# Test texture path lookup with a sample model
	lines.append("")
	lines.append("[color=cyan]Texture Path Test:[/color]")
	var ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
	var test_model := "x\\ex_common_house_01.nif"
	var test_hash := ImpostorCandidatesScript.get_hash_key(test_model)
	var test_path := ImpostorCandidatesScript.get_impostor_texture_path_v6(test_model)
	lines.append("  Test model: %s" % test_model)
	lines.append("  Hash key: %s" % test_hash)
	lines.append("  Expected path: %s" % test_path)
	lines.append("  File exists: %s" % ("YES" if FileAccess.file_exists(test_path) else "[color=red]NO[/color]"))

	# Diagnosis
	lines.append("")
	lines.append("[color=cyan]Diagnosis:[/color]")
	var issues_found := false

	if renderer.is_processing() == false:
		lines.append("  [color=red]CRITICAL: _process() disabled - set distant_rendering_enabled=true[/color]")
		issues_found = true

	if renderer.get("impostor_candidates") == null:
		lines.append("  [color=red]CRITICAL: ImpostorCandidates not initialized[/color]")
		issues_found = true

	if renderer.has_method("get_stats"):
		var stats: Dictionary = renderer.call("get_stats")
		if stats.get("loaded_impostor_cells", 0) == 0:
			lines.append("  [color=yellow]WARNING: No impostor cells loaded yet[/color]")
			issues_found = true
		if stats.get("texture_array_layers", 0) == 0 and stats.get("total_impostors", 0) > 0:
			lines.append("  [color=yellow]WARNING: Impostors exist but no textures loaded[/color]")
			issues_found = true
		if stats.get("multimesh_instance_count", 0) == 0 and stats.get("total_impostors", 0) > 0:
			lines.append("  [color=yellow]WARNING: Impostors exist but MultiMesh is empty[/color]")
			issues_found = true
		if stats.get("total_impostors", 0) == 0 and stats.get("loaded_impostor_cells", 0) > 0:
			lines.append("  [color=yellow]WARNING: Cells loaded but no impostors created[/color]")
			lines.append("    - Check if ESMManager has cell data")
			lines.append("    - Check if ImpostorCandidates patterns match your models")
			issues_found = true

	if not issues_found:
		lines.append("  [color=green]No obvious issues detected[/color]")
		lines.append("  If impostors still don't appear:")
		lines.append("    1. Move camera into the active FAR tier")
		lines.append("    2. Run 'impostor_verbose' to enable debug logging")
		lines.append("    3. Run 'impostor_dump' and check ImpostorPage visibility ranges")

	return CommandRegistry.CommandResult.ok("\n".join(lines))


func _cmd_impostor_dump(_args: Dictionary) -> CommandRegistry.CommandResult:
	# Get world object
	var world: Variant = _context.get("world")
	if not world:
		return CommandRegistry.CommandResult.error("No world context set")

	var world_obj: Object = world as Object
	var impostor_renderer: Variant = null
	if world_obj.has_method("get_impostor_manager"):
		impostor_renderer = world_obj.call("get_impostor_manager")

	if not impostor_renderer:
		return CommandRegistry.CommandResult.error("No impostor renderer found")

	var renderer: Object = impostor_renderer as Object
	if renderer.has_method("dump_diagnostic"):
		var output: String = renderer.call("dump_diagnostic")
		return CommandRegistry.CommandResult.ok(output)
	else:
		return CommandRegistry.CommandResult.error("Renderer doesn't have dump_diagnostic method")


func _cmd_impostor_verbose(args: Dictionary) -> CommandRegistry.CommandResult:
	var state: String = args.get("state", "on")

	# Get world object
	var world: Variant = _context.get("world")
	if not world:
		return CommandRegistry.CommandResult.error("No world context set")

	var world_obj: Object = world as Object
	var impostor_renderer: Variant = null
	if world_obj.has_method("get_impostor_manager"):
		impostor_renderer = world_obj.call("get_impostor_manager")

	if not impostor_renderer:
		return CommandRegistry.CommandResult.error("No impostor renderer found")

	var renderer: Object = impostor_renderer as Object
	var enable := state == "on"
	renderer.set("debug_enabled", enable)

	if enable:
		Log.debug("console", "Impostor verbose logging ENABLED - move to new cell to see output")
	else:
		Log.debug("console", "Impostor verbose logging DISABLED")

	return CommandRegistry.CommandResult.ok("Impostor verbose logging: %s" % ("ON" if enable else "OFF"))


func _cmd_impostor_show(args: Dictionary) -> CommandRegistry.CommandResult:
	var state: String = args.get("state", "on")

	# Get world object
	var world: Variant = _context.get("world")
	if not world:
		return CommandRegistry.CommandResult.error("No world context set")

	var world_obj: Object = world as Object
	var impostor_renderer: Variant = null
	if world_obj.has_method("get_impostor_manager"):
		impostor_renderer = world_obj.call("get_impostor_manager")

	if not impostor_renderer:
		return CommandRegistry.CommandResult.error("No impostor renderer found")

	var renderer: Object = impostor_renderer as Object
	var enable := state == "on"

	# Call set_shader_debug_mode to toggle magenta debug rendering
	if renderer.has_method("set_shader_debug_mode"):
		renderer.call("set_shader_debug_mode", enable)
		if enable:
			return CommandRegistry.CommandResult.ok("Impostor shader debug: ON\nImpostors now show as MAGENTA at ANY distance.\nIf you don't see magenta squares, the MultiMesh isn't rendering.")
		else:
			return CommandRegistry.CommandResult.ok("Impostor shader debug: OFF\nImpostors now render normally (visible only at 500m+)")
	else:
		return CommandRegistry.CommandResult.error("Renderer doesn't have set_shader_debug_mode method")


func _cmd_ocean_debug(args: Dictionary) -> CommandRegistry.CommandResult:
	var state: String = args.get("state", "toggle")

	# Get OceanManager autoload
	var ocean: Variant = _context.get("ocean")
	if not ocean:
		# Try to find it
		ocean = get_node_or_null("/root/OceanManager")
		if ocean:
			_context["ocean"] = ocean

	if not ocean or not ocean is Object:
		return CommandRegistry.CommandResult.error("OceanManager not found")

	var ocean_obj: Object = ocean as Object
	if not ocean_obj.has_method("get_ocean_mesh"):
		return CommandRegistry.CommandResult.error("OceanManager doesn't have get_ocean_mesh method")

	var ocean_mesh: Variant = ocean_obj.call("get_ocean_mesh")
	if not ocean_mesh or not ocean_mesh is Object:
		return CommandRegistry.CommandResult.error("Ocean mesh not available")

	var mesh_obj: Object = ocean_mesh as Object

	# Determine new state
	var new_enabled: bool
	var current: bool = mesh_obj.call("is_debug_shore_mask") if mesh_obj.has_method("is_debug_shore_mask") else false

	match state.to_lower():
		"on", "true", "1", "enabled":
			new_enabled = true
		"off", "false", "0", "disabled":
			new_enabled = false
		_:  # toggle
			new_enabled = not current

	# Apply state
	if mesh_obj.has_method("set_debug_shore_mask"):
		mesh_obj.call("set_debug_shore_mask", new_enabled)

	var help_msg := ""
	if new_enabled:
		help_msg = "\n[color=gray]Magenta = shore/land (factor 0), Cyan = ocean (factor 1)[/color]"

	return CommandRegistry.CommandResult.ok("Shore mask debug: %s%s" % [
		"[color=green]enabled[/color]" if new_enabled else "[color=red]disabled[/color]",
		help_msg
	])


func _cmd_ocean_info(_args: Dictionary) -> CommandRegistry.CommandResult:
	# Get OceanManager autoload
	var ocean: Variant = _context.get("ocean")
	if not ocean:
		ocean = get_node_or_null("/root/OceanManager")
		if ocean:
			_context["ocean"] = ocean

	if not ocean or not ocean is Object:
		return CommandRegistry.CommandResult.error("OceanManager not found")

	var ocean_obj: Object = ocean as Object
	var lines: PackedStringArray = ["[b]Ocean System Info[/b]"]

	# Basic state
	var is_enabled: bool = ocean_obj.call("is_system_enabled") if ocean_obj.has_method("is_system_enabled") else false
	var is_init: bool = ocean_obj.call("is_initialized") if ocean_obj.has_method("is_initialized") else false
	lines.append("System enabled: %s" % ("yes" if is_enabled else "no"))
	lines.append("Initialized: %s" % ("yes" if is_init else "no"))

	# Sea level and fade distance
	var sea_level: float = ocean_obj.get("sea_level") if "sea_level" in ocean_obj else 0.0
	var fade_dist: float = ocean_obj.get("shore_fade_distance") if "shore_fade_distance" in ocean_obj else 50.0
	var mask_res: int = ocean_obj.get("shore_mask_resolution") if "shore_mask_resolution" in ocean_obj else 2048
	lines.append("Sea level: %.1fm" % sea_level)
	lines.append("Shore fade distance: %.1fm" % fade_dist)
	lines.append("Shore mask resolution: %dx%d" % [mask_res, mask_res])

	# Quality mode
	if ocean_obj.has_method("get_water_quality_name"):
		var quality_name: String = ocean_obj.call("get_water_quality_name")
		lines.append("Quality mode: %s" % quality_name)

	# Shore mask info
	lines.append("")
	lines.append("[b]Shore Mask[/b]")

	var shore_gen: Variant = ocean_obj.call("get_shore_mask_generator") if ocean_obj.has_method("get_shore_mask_generator") else null
	if shore_gen and shore_gen is Object:
		var shore_obj: Object = shore_gen as Object
		var bounds: Rect2 = shore_obj.call("get_world_bounds") if shore_obj.has_method("get_world_bounds") else Rect2()
		lines.append("World bounds: (%.0f, %.0f) to (%.0f, %.0f)" % [
			bounds.position.x, bounds.position.y,
			bounds.end.x, bounds.end.y
		])
		var world_size: float = bounds.size.x
		var meters_per_pixel: float = world_size / float(mask_res)
		var fade_pixels: float = fade_dist / meters_per_pixel
		lines.append("Meters per pixel: %.2f" % meters_per_pixel)
		lines.append("Fade distance in pixels: %.1f" % fade_pixels)

		if fade_pixels < 10:
			lines.append("[color=yellow]Warning: Low pixel resolution for fade![/color]")
			lines.append("[color=gray]Consider increasing fade distance or mask resolution[/color]")
	else:
		lines.append("[color=gray]Shore mask generator not available[/color]")

	# Ocean mesh info
	var ocean_mesh: Variant = ocean_obj.call("get_ocean_mesh") if ocean_obj.has_method("get_ocean_mesh") else null
	if ocean_mesh and ocean_mesh is Object:
		var mesh_obj: Object = ocean_mesh as Object
		var debug_mode: bool = mesh_obj.call("is_debug_shore_mask") if mesh_obj.has_method("is_debug_shore_mask") else false
		lines.append("")
		lines.append("Debug shore mask: %s" % ("on" if debug_mode else "off"))

	lines.append("")
	lines.append("[color=gray]Use 'ocean_debug' to visualize the shore mask gradient[/color]")

	return CommandRegistry.CommandResult.ok("\n".join(lines))


func _cmd_ocean_fade(args: Dictionary) -> CommandRegistry.CommandResult:
	var distance_str: String = args.get("distance", "")

	# Get OceanManager autoload
	var ocean: Variant = _context.get("ocean")
	if not ocean:
		ocean = get_node_or_null("/root/OceanManager")
		if ocean:
			_context["ocean"] = ocean

	if not ocean or not ocean is Object:
		return CommandRegistry.CommandResult.error("OceanManager not found")

	var ocean_obj: Object = ocean as Object

	# If no distance provided, show current value
	if distance_str.is_empty():
		var current: float = ocean_obj.get("shore_fade_distance") if "shore_fade_distance" in ocean_obj else 50.0
		return CommandRegistry.CommandResult.ok("Current shore fade distance: %.1fm" % current)

	# Parse and set new distance
	if not distance_str.is_valid_float():
		return CommandRegistry.CommandResult.error("Invalid distance value: %s" % distance_str)

	var new_distance: float = distance_str.to_float()
	if new_distance <= 0:
		return CommandRegistry.CommandResult.error("Distance must be positive")

	# Set the new value
	ocean_obj.set("shore_fade_distance", new_distance)

	# Regenerate shore mask if possible
	if ocean_obj.has_method("regenerate_shore_mask"):
		ocean_obj.call("regenerate_shore_mask")
		return CommandRegistry.CommandResult.ok("Shore fade distance set to %.1fm (mask regenerated)" % new_distance)
	else:
		return CommandRegistry.CommandResult.ok("Shore fade distance set to %.1fm\n[color=yellow]Note: Restart or rebake shore mask to see effect[/color]" % new_distance)

#endregion
