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
	ui.console_visibility_changed.connect(func(v: bool): visibility_changed.emit(v))
	ui.autocomplete_requested.connect(_on_autocomplete_requested)

	picker.object_selected.connect(_on_object_selected)
	picker.selection_cleared.connect(_on_selection_cleared)
	picker.picker_mode_entered.connect(func(): ui.print_line("[color=yellow]Click on an object to select it...[/color]"))
	picker.picker_mode_exited.connect(func(): pass)

	# Register built-in commands
	_register_builtin_commands()

	# Print welcome message when first shown
	ui.console_visibility_changed.connect(func(visible: bool):
		if visible and ui.output_text.get_total_character_count() == 0:
			_print_welcome()
	, CONNECT_ONE_SHOT)


func _input(event: InputEvent) -> void:
	# Toggle console with tilde key
	if event is InputEventKey and event.pressed and event.keycode == TOGGLE_KEY:
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
func register_context(name: String, obj: Variant) -> void:
	_context[name] = obj


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
		ui.print_error(parsed.error)
		ui.print_line("[color=gray]Usage: %s[/color]" % cmd.get_usage())
		return

	# Execute command
	var result: CommandRegistry.CommandResult
	if cmd.callback.is_valid():
		result = cmd.callback.call(parsed.args)
	else:
		result = CommandRegistry.CommandResult.error("Command callback is invalid")

	# Display result
	if result:
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


#endregion


#region Built-in Command Implementations

func _cmd_help(args: Dictionary) -> CommandRegistry.CommandResult:
	if args.has("command") and not args.command.is_empty():
		var cmd := registry.get_command(args.command)
		if cmd:
			return CommandRegistry.CommandResult.ok(registry.get_help_text(cmd))
		else:
			return CommandRegistry.CommandResult.error("Unknown command: %s" % args.command)

	return CommandRegistry.CommandResult.ok(registry.get_full_help())


func _cmd_clear(_args: Dictionary) -> CommandRegistry.CommandResult:
	ui.clear_output()
	return CommandRegistry.CommandResult.ok()


func _cmd_version(_args: Dictionary) -> CommandRegistry.CommandResult:
	return CommandRegistry.CommandResult.ok("Godotwind Console v%s" % VERSION)


func _cmd_echo(args: Dictionary) -> CommandRegistry.CommandResult:
	return CommandRegistry.CommandResult.ok(args.get("message", ""))


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

	# TODO: Look up object by name/ID
	return CommandRegistry.CommandResult.error("Object lookup not yet implemented")


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
		var player = _context.get("player")
		var camera = _context.get("camera")

		if player and player.has_method("teleport_to"):
			player.teleport_to(sel.hit_position + Vector3(0, 2, 0))
			return CommandRegistry.CommandResult.ok("Teleported to selection")
		elif camera:
			if camera is Camera3D:
				camera.global_position = sel.hit_position + Vector3(0, 50, 50)
				camera.look_at(sel.hit_position)
				return CommandRegistry.CommandResult.ok("Teleported camera to selection")

		return CommandRegistry.CommandResult.error("No player or camera in context")

	# Check for coordinates (x,y or x,y,z)
	if "," in target:
		var parts := target.split(",")
		if parts.size() >= 2:
			var x := parts[0].strip_edges().to_float()
			var y := parts[1].strip_edges().to_float()
			var z := parts[2].strip_edges().to_float() if parts.size() > 2 else 0.0

			# If only 2 coords, assume cell coordinates
			if parts.size() == 2:
				# Cell coordinates - need to convert
				# This would need the coordinate system module
				return CommandRegistry.CommandResult.ok("Would teleport to cell (%d, %d)" % [int(x), int(y)])

			# World coordinates
			var player = _context.get("player")
			var camera = _context.get("camera")

			if player and player.has_method("teleport_to"):
				player.teleport_to(Vector3(x, y, z))
				return CommandRegistry.CommandResult.ok("Teleported to (%.1f, %.1f, %.1f)" % [x, y, z])
			elif camera and camera is Camera3D:
				camera.global_position = Vector3(x, y, z)
				return CommandRegistry.CommandResult.ok("Teleported camera to (%.1f, %.1f, %.1f)" % [x, y, z])

			return CommandRegistry.CommandResult.error("No player or camera in context")

	# Assume it's a cell name - would need ESMManager integration
	return CommandRegistry.CommandResult.ok("Would teleport to cell: %s" % target)


func _cmd_pos(_args: Dictionary) -> CommandRegistry.CommandResult:
	var player = _context.get("player")
	var camera = _context.get("camera")

	var pos: Vector3

	if player and player is Node3D:
		pos = player.global_position
	elif camera and camera is Camera3D:
		pos = camera.global_position
	else:
		return CommandRegistry.CommandResult.error("No player or camera in context")

	return CommandRegistry.CommandResult.ok("Position: (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z])


func _cmd_cells(_args: Dictionary) -> CommandRegistry.CommandResult:
	var world = _context.get("world")

	if not world:
		return CommandRegistry.CommandResult.error("No world streaming manager in context")

	if world.has_method("get_loaded_cell_coordinates"):
		var coords: Array = world.get_loaded_cell_coordinates()
		var lines: PackedStringArray = ["Loaded cells (%d):" % coords.size()]

		for coord in coords:
			if coord is Vector2i:
				lines.append("  (%d, %d)" % [coord.x, coord.y])

		return CommandRegistry.CommandResult.ok("\n".join(lines))

	return CommandRegistry.CommandResult.error("World manager doesn't support cell listing")


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
	for name in _variables:
		lines.append("  %s = %s" % [name, _variables[name]])

	return CommandRegistry.CommandResult.ok("\n".join(lines))

#endregion
