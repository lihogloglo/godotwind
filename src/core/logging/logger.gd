@tool
## Logger — Structured logging with levels and categories
##
## Replaces raw print() calls with categorized, level-gated output.
## Registered as autoload — use directly: Log.info("esm", "Loaded 500 cells")
##
## Levels: DEBUG < INFO < WARN < ERROR
## Categories match subsystem directories (streaming, esm, nif, etc.)
## Set minimum level per-category or globally to filter output.
extends Node


enum Level { DEBUG, INFO, WARN, ERROR, NONE }

## Global minimum log level — messages below this are suppressed
var min_level: Level = Level.INFO

## Per-category overrides: { "category": Level }
## Example: category_levels["streaming"] = Level.DEBUG
var category_levels: Dictionary = {}

## Whether to include timestamps in output
var show_timestamps: bool = false

## Level prefixes for output formatting
const _LEVEL_PREFIX: Dictionary = {
	Level.DEBUG: "[DEBUG]",
	Level.INFO: "[INFO]",
	Level.WARN: "[WARN]",
	Level.ERROR: "[ERROR]",
}


func debug(category: String, message: String) -> void:
	_log(Level.DEBUG, category, message)


func info(category: String, message: String) -> void:
	_log(Level.INFO, category, message)


func warn(category: String, message: String) -> void:
	_log(Level.WARN, category, message)


func error(category: String, message: String) -> void:
	_log(Level.ERROR, category, message)


## Set minimum level for a specific category
func set_category_level(category: String, level: Level) -> void:
	category_levels[category] = level


## Enable debug output for a category (useful during development)
func enable_debug(category: String) -> void:
	category_levels[category] = Level.DEBUG


## Disable all output for a category
func silence(category: String) -> void:
	category_levels[category] = Level.NONE


func _log(level: Level, category: String, message: String) -> void:
	var effective_level: Level = category_levels.get(category, min_level)
	if level < effective_level:
		return

	var prefix: String = _LEVEL_PREFIX[level]
	var output: String
	if show_timestamps:
		var time_ms := Time.get_ticks_msec()
		output = "%s %s [%s] %s" % [prefix, _format_time(time_ms), category, message]
	else:
		output = "%s [%s] %s" % [prefix, category, message]

	match level:
		Level.WARN:
			push_warning(output)
		Level.ERROR:
			push_error(output)
		_:
			print(output)


static func _format_time(ms: int) -> String:
	var secs := ms / 1000
	var mins := secs / 60
	return "%02d:%02d.%03d" % [mins % 60, secs % 60, ms % 1000]
