## Command Registry - Manages console command registration and lookup
##
## Provides a centralized registry for console commands with:
## - Command registration with metadata (description, aliases, parameters)
## - Fuzzy matching for autocomplete
## - Parameter parsing and validation
## - Help text generation
class_name CommandRegistry
extends RefCounted


#region Classes

## Describes a registered command
class CommandInfo:
	## Primary command name
	var name: String

	## Description shown in help
	var description: String

	## Category for grouping (e.g., "navigation", "world", "debug")
	var category: String

	## Alternative names for this command
	var aliases: PackedStringArray

	## Parameter definitions
	var parameters: Array[ParameterInfo]

	## The callable to execute
	var callback: Callable

	## Usage examples
	var examples: PackedStringArray

	func _init() -> void:
		aliases = PackedStringArray()
		parameters = []
		examples = PackedStringArray()

	func get_usage() -> String:
		var parts: PackedStringArray = [name]
		for param in parameters:
			if param.required:
				parts.append("<%s>" % param.name)
			else:
				parts.append("[%s]" % param.name)
		return " ".join(parts)

	func get_all_names() -> PackedStringArray:
		var result := PackedStringArray([name])
		result.append_array(aliases)
		return result


## Describes a command parameter
class ParameterInfo:
	var name: String
	var type: Variant.Type
	var description: String
	var required: bool
	var default_value: Variant

	func _init(p_name: String, p_type: Variant.Type = TYPE_STRING, p_desc: String = "", p_required: bool = true, p_default: Variant = null) -> void:
		name = p_name
		type = p_type
		description = p_desc
		required = p_required
		default_value = p_default


## Result of command execution
class CommandResult:
	var success: bool
	var message: String
	var data: Variant  # Optional data returned by command

	func _init(p_success: bool = true, p_message: String = "", p_data: Variant = null) -> void:
		success = p_success
		message = p_message
		data = p_data

	static func ok(message: String = "", data: Variant = null) -> CommandResult:
		return CommandResult.new(true, message, data)

	static func error(message: String) -> CommandResult:
		return CommandResult.new(false, message)

#endregion


#region State

## Registered commands by primary name
var _commands: Dictionary = {}  # String -> CommandInfo

## Alias mapping to primary names
var _aliases: Dictionary = {}  # String -> String (alias -> primary name)

## Commands grouped by category
var _categories: Dictionary = {}  # String -> Array[String] (category -> command names)

#endregion


## Register a new command
func register(
	name: String,
	callback: Callable,
	description: String = "",
	category: String = "misc",
	aliases: PackedStringArray = PackedStringArray(),
	parameters: Array[ParameterInfo] = [],
	examples: PackedStringArray = PackedStringArray()
) -> void:
	var cmd := CommandInfo.new()
	cmd.name = name.to_lower()
	cmd.description = description
	cmd.category = category
	cmd.aliases = aliases
	cmd.parameters = parameters
	cmd.callback = callback
	cmd.examples = examples

	_commands[cmd.name] = cmd

	# Register aliases
	for alias in aliases:
		_aliases[alias.to_lower()] = cmd.name

	# Add to category
	if not _categories.has(category):
		_categories[category] = []
	if cmd.name not in _categories[category]:
		_categories[category].append(cmd.name)


## Unregister a command
func unregister(name: String) -> void:
	var lower_name := name.to_lower()

	# Check if it's an alias
	if _aliases.has(lower_name):
		lower_name = _aliases[lower_name]

	if not _commands.has(lower_name):
		return

	var cmd: CommandInfo = _commands[lower_name]

	# Remove aliases
	for alias in cmd.aliases:
		_aliases.erase(alias.to_lower())

	# Remove from category
	if _categories.has(cmd.category):
		_categories[cmd.category].erase(cmd.name)

	# Remove command
	_commands.erase(lower_name)


## Get a command by name or alias
func get_command(name: String) -> CommandInfo:
	var lower_name := name.to_lower()

	# Check direct match
	if _commands.has(lower_name):
		return _commands[lower_name]

	# Check alias
	if _aliases.has(lower_name):
		return _commands[_aliases[lower_name]]

	return null


## Check if a command exists
func has_command(name: String) -> bool:
	var lower_name := name.to_lower()
	return _commands.has(lower_name) or _aliases.has(lower_name)


## Get all command names (primary only, sorted)
func get_all_command_names() -> PackedStringArray:
	var names := PackedStringArray(_commands.keys())
	names.sort()
	return names


## Get all categories
func get_categories() -> PackedStringArray:
	var cats := PackedStringArray(_categories.keys())
	cats.sort()
	return cats


## Get commands in a category
func get_commands_in_category(category: String) -> Array[CommandInfo]:
	var result: Array[CommandInfo] = []
	if _categories.has(category):
		for cmd_name in _categories[category]:
			if _commands.has(cmd_name):
				result.append(_commands[cmd_name])
	return result


## Find commands matching a prefix (for autocomplete)
func find_commands_by_prefix(prefix: String) -> Array[CommandInfo]:
	var lower_prefix := prefix.to_lower()
	var result: Array[CommandInfo] = []

	# Check primary names
	for cmd_name in _commands:
		if cmd_name.begins_with(lower_prefix):
			result.append(_commands[cmd_name])

	# Check aliases
	for alias in _aliases:
		if alias.begins_with(lower_prefix):
			var cmd: CommandInfo = _commands[_aliases[alias]]
			if cmd not in result:
				result.append(cmd)

	return result


## Fuzzy find commands (for smart autocomplete)
func find_commands_fuzzy(query: String, max_results: int = 10) -> Array[CommandInfo]:
	var lower_query := query.to_lower()
	var scored: Array[Dictionary] = []  # [{cmd: CommandInfo, score: float}]

	for cmd_name in _commands:
		var cmd: CommandInfo = _commands[cmd_name]
		var score := _fuzzy_score(lower_query, cmd_name)

		# Also check aliases
		for alias in cmd.aliases:
			var alias_score := _fuzzy_score(lower_query, alias.to_lower())
			score = maxf(score, alias_score)

		if score > 0:
			scored.append({"cmd": cmd, "score": score})

	# Sort by score descending
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score > b.score)

	# Return top results
	var result: Array[CommandInfo] = []
	for i in mini(max_results, scored.size()):
		result.append(scored[i].cmd)

	return result


## Calculate fuzzy match score (0 = no match, higher = better)
func _fuzzy_score(query: String, target: String) -> float:
	if query.is_empty():
		return 0.0

	# Exact prefix match is best
	if target.begins_with(query):
		return 100.0 + (1.0 / target.length())  # Shorter matches score higher

	# Exact substring match
	var idx := target.find(query)
	if idx >= 0:
		return 50.0 - idx  # Earlier matches score higher

	# Fuzzy consonant matching (all query chars must appear in order)
	var qi := 0
	var ti := 0
	var matches := 0
	var consecutive := 0
	var max_consecutive := 0

	while qi < query.length() and ti < target.length():
		if query[qi] == target[ti]:
			matches += 1
			consecutive += 1
			max_consecutive = maxi(max_consecutive, consecutive)
			qi += 1
		else:
			consecutive = 0
		ti += 1

	if qi == query.length():
		# All query chars matched
		return 10.0 + matches + max_consecutive * 2

	return 0.0


## Parse command arguments from a string
func parse_arguments(cmd: CommandInfo, args_string: String) -> Dictionary:
	var result := {
		"success": true,
		"error": "",
		"args": {}
	}

	var tokens := _tokenize(args_string)
	var param_idx := 0

	for i in tokens.size():
		var token: String = tokens[i]

		# Check if we have more args than parameters
		if param_idx >= cmd.parameters.size():
			# Collect remaining as "rest" if last param exists
			if not cmd.parameters.is_empty():
				var last_param := cmd.parameters[-1]
				if result.args.has(last_param.name):
					result.args[last_param.name] += " " + token
				else:
					result.args[last_param.name] = token
			continue

		var param := cmd.parameters[param_idx]
		var parsed := _parse_value(token, param.type)

		if parsed.success:
			result.args[param.name] = parsed.value
		else:
			result.success = false
			result.error = "Invalid value for '%s': %s" % [param.name, parsed.error]
			return result

		param_idx += 1

	# Check required parameters
	for param in cmd.parameters:
		if param.required and not result.args.has(param.name):
			result.success = false
			result.error = "Missing required parameter: %s" % param.name
			return result

	# Fill in defaults
	for param in cmd.parameters:
		if not result.args.has(param.name) and param.default_value != null:
			result.args[param.name] = param.default_value

	return result


## Tokenize an argument string (respects quotes)
func _tokenize(text: String) -> PackedStringArray:
	var tokens: PackedStringArray = []
	var current := ""
	var in_quotes := false
	var quote_char := ""

	for i in text.length():
		var c := text[i]

		if in_quotes:
			if c == quote_char:
				in_quotes = false
				if not current.is_empty():
					tokens.append(current)
					current = ""
			else:
				current += c
		elif c == '"' or c == "'":
			in_quotes = true
			quote_char = c
		elif c == ' ' or c == '\t':
			if not current.is_empty():
				tokens.append(current)
				current = ""
		else:
			current += c

	if not current.is_empty():
		tokens.append(current)

	return tokens


## Parse a value to the expected type
func _parse_value(text: String, type: Variant.Type) -> Dictionary:
	match type:
		TYPE_STRING:
			return {"success": true, "value": text}

		TYPE_INT:
			if text.is_valid_int():
				return {"success": true, "value": text.to_int()}
			return {"success": false, "error": "Expected integer"}

		TYPE_FLOAT:
			if text.is_valid_float():
				return {"success": true, "value": text.to_float()}
			return {"success": false, "error": "Expected number"}

		TYPE_BOOL:
			var lower := text.to_lower()
			if lower in ["true", "1", "yes", "on"]:
				return {"success": true, "value": true}
			elif lower in ["false", "0", "no", "off"]:
				return {"success": true, "value": false}
			return {"success": false, "error": "Expected boolean (true/false)"}

		TYPE_VECTOR2:
			var parts := text.split(",")
			if parts.size() == 2:
				if parts[0].strip_edges().is_valid_float() and parts[1].strip_edges().is_valid_float():
					return {"success": true, "value": Vector2(parts[0].to_float(), parts[1].to_float())}
			return {"success": false, "error": "Expected x,y"}

		TYPE_VECTOR3:
			var parts := text.split(",")
			if parts.size() == 3:
				if parts[0].strip_edges().is_valid_float() and parts[1].strip_edges().is_valid_float() and parts[2].strip_edges().is_valid_float():
					return {"success": true, "value": Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())}
			return {"success": false, "error": "Expected x,y,z"}

		_:
			return {"success": true, "value": text}


## Generate help text for a command
func get_help_text(cmd: CommandInfo) -> String:
	var lines: PackedStringArray = []

	lines.append("[b]%s[/b] - %s" % [cmd.name.to_upper(), cmd.description])
	lines.append("")
	lines.append("[color=gray]Usage:[/color] %s" % cmd.get_usage())

	if not cmd.aliases.is_empty():
		lines.append("[color=gray]Aliases:[/color] %s" % ", ".join(cmd.aliases))

	if not cmd.parameters.is_empty():
		lines.append("")
		lines.append("[color=gray]Parameters:[/color]")
		for param in cmd.parameters:
			var req_str := " [required]" if param.required else ""
			var default_str := " (default: %s)" % str(param.default_value) if param.default_value != null else ""
			lines.append("  %s - %s%s%s" % [param.name, param.description, req_str, default_str])

	if not cmd.examples.is_empty():
		lines.append("")
		lines.append("[color=gray]Examples:[/color]")
		for example in cmd.examples:
			lines.append("  %s" % example)

	return "\n".join(lines)


## Generate help text for all commands
func get_full_help() -> String:
	var lines: PackedStringArray = []

	for category in get_categories():
		lines.append("[b]%s[/b]" % category.to_upper())

		var cmds := get_commands_in_category(category)
		for cmd in cmds:
			var alias_str := ""
			if not cmd.aliases.is_empty():
				alias_str = " (%s)" % ", ".join(cmd.aliases)
			lines.append("  [color=cyan]%s[/color]%s - %s" % [cmd.name, alias_str, cmd.description])

		lines.append("")

	return "\n".join(lines)
