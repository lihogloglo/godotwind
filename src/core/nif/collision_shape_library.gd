## Collision Shape Library - Provides explicit collision shape mappings for items
## Uses YAML configuration for pattern-based and exact-match shape assignments
## Priority: exact item ID match > pattern match > auto-detect from geometry
##
## This is useful for dynamic objects (MISC items, weapons, ingredients) where
## predictable physics behavior is important. Jolt physics performs better with
## primitive shapes (sphere, cylinder, capsule, box) than with trimesh/convex.
class_name CollisionShapeLibrary
extends RefCounted

## Shape types that can be specified in the YAML
enum ShapeType {
	BOX,
	SPHERE,
	CYLINDER,
	CAPSULE,
	CONVEX,      ## Fall back to convex hull from geometry
	TRIMESH,     ## Fall back to trimesh from geometry
	AUTO,        ## Use auto-detection from geometry
}

## Compiled pattern for efficient matching
class CompiledPattern:
	var pattern: String         ## Original pattern string
	var regex: RegEx            ## Compiled regex (null if simple wildcard)
	var shape_type: ShapeType   ## Shape to use when matched
	var is_simple: bool         ## True if pattern uses simple * wildcard only
	var prefix: String          ## For simple patterns: text before *
	var suffix: String          ## For simple patterns: text after *

## Singleton instance
static var _instance: CollisionShapeLibrary = null

## Exact item ID -> ShapeType mappings (case-insensitive keys)
var _item_shapes: Dictionary = {}

## Compiled patterns for pattern matching (ordered, first match wins)
var _patterns: Array[CompiledPattern] = []

## Whether the library has been loaded
var _loaded: bool = false

## Path to the YAML file
var _yaml_path: String = ""

## Debug mode
var debug_mode: bool = false


## Default path for collision shapes YAML file
const DEFAULT_YAML_PATH := "res://collision-shapes.yaml"

## Alternative paths to search for YAML file
const YAML_SEARCH_PATHS := [
	"res://collision-shapes.yaml",
	"res://data/collision-shapes.yaml",
	"res://config/collision-shapes.yaml",
	"res://../collision-shapes.yaml",  # Project root (outside godotwind folder)
]


## Get singleton instance (auto-loads from default path if available)
static func get_instance() -> CollisionShapeLibrary:
	if _instance == null:
		_instance = CollisionShapeLibrary.new()
		_instance._try_auto_load()
	return _instance


## Try to auto-load from default/search paths
func _try_auto_load() -> void:
	for path in YAML_SEARCH_PATHS:
		if FileAccess.file_exists(path):
			if load_from_file(path):
				if debug_mode:
					print("CollisionShapeLibrary: Auto-loaded from %s" % path)
				return
	# No file found - that's OK, library will work without explicit mappings


## Load collision shapes from YAML file
## Returns true on success, false on failure
func load_from_file(path: String) -> bool:
	_yaml_path = path
	_item_shapes.clear()
	_patterns.clear()
	_loaded = false

	if not FileAccess.file_exists(path):
		push_warning("CollisionShapeLibrary: File not found: %s" % path)
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("CollisionShapeLibrary: Failed to open file: %s" % path)
		return false

	var content := file.get_as_text()
	file.close()

	return _parse_yaml(content)


## Load collision shapes from YAML string content
func load_from_string(content: String) -> bool:
	_item_shapes.clear()
	_patterns.clear()
	_loaded = false
	return _parse_yaml(content)


## Parse YAML content (simple parser for our specific format)
func _parse_yaml(content: String) -> bool:
	var lines := content.split("\n")
	var current_section := ""  ## "patterns" or "items"
	var in_pattern_block := false
	var current_pattern := ""
	var current_shape := ""

	for line in lines:
		# Skip comments and empty lines
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue

		# Detect section headers
		if trimmed == "patterns:":
			current_section = "patterns"
			continue
		elif trimmed == "items:":
			current_section = "items"
			continue

		# Process based on section
		if current_section == "patterns":
			# Pattern entries are like:
			#   - pattern: "misc_com_bottle_*"
			#     shape: cylinder
			if trimmed.begins_with("- pattern:"):
				# Start of a new pattern block
				var pattern_str := _extract_quoted_value(trimmed, "- pattern:")
				current_pattern = pattern_str
				in_pattern_block = true
			elif trimmed.begins_with("pattern:"):
				var pattern_str := _extract_quoted_value(trimmed, "pattern:")
				current_pattern = pattern_str
				in_pattern_block = true
			elif trimmed.begins_with("shape:") and in_pattern_block:
				var shape_str := trimmed.substr(6).strip_edges()
				var shape_type := _parse_shape_type(shape_str)
				if not current_pattern.is_empty():
					_add_pattern(current_pattern, shape_type)
				in_pattern_block = false
				current_pattern = ""

		elif current_section == "items":
			# Item entries are like:
			#   misc_com_bottle_01: cylinder
			# or with quotes:
			#   "Gold_001": cylinder
			if ":" in trimmed:
				var parts := trimmed.split(":", true, 1)
				if parts.size() == 2:
					var item_id := parts[0].strip_edges().trim_prefix("\"").trim_suffix("\"")
					var shape_str := parts[1].strip_edges()
					# Remove trailing comments
					if "#" in shape_str:
						shape_str = shape_str.split("#")[0].strip_edges()
					var shape_type := _parse_shape_type(shape_str)
					_add_item(item_id, shape_type)

	_loaded = true

	if debug_mode:
		print("CollisionShapeLibrary: Loaded %d items, %d patterns" % [
			_item_shapes.size(), _patterns.size()
		])

	return true


## Extract quoted value from a line like '- pattern: "value"' or 'pattern: "value"'
func _extract_quoted_value(line: String, prefix: String) -> String:
	var after_prefix := line.substr(line.find(prefix) + prefix.length()).strip_edges()
	# Remove quotes if present
	if after_prefix.begins_with("\"") and after_prefix.ends_with("\""):
		return after_prefix.substr(1, after_prefix.length() - 2)
	elif after_prefix.begins_with("'") and after_prefix.ends_with("'"):
		return after_prefix.substr(1, after_prefix.length() - 2)
	return after_prefix


## Parse shape type string to enum
func _parse_shape_type(shape_str: String) -> ShapeType:
	match shape_str.to_lower():
		"box":
			return ShapeType.BOX
		"sphere":
			return ShapeType.SPHERE
		"cylinder":
			return ShapeType.CYLINDER
		"capsule":
			return ShapeType.CAPSULE
		"convex":
			return ShapeType.CONVEX
		"trimesh":
			return ShapeType.TRIMESH
		"auto":
			return ShapeType.AUTO
		_:
			push_warning("CollisionShapeLibrary: Unknown shape type '%s', defaulting to AUTO" % shape_str)
			return ShapeType.AUTO


## Add an exact item ID mapping
func _add_item(item_id: String, shape_type: ShapeType) -> void:
	# Store lowercase for case-insensitive lookup
	_item_shapes[item_id.to_lower()] = shape_type


## Add a pattern mapping
func _add_pattern(pattern: String, shape_type: ShapeType) -> void:
	var compiled := CompiledPattern.new()
	compiled.pattern = pattern
	compiled.shape_type = shape_type

	# Check if it's a simple wildcard pattern (only contains * at start/end or middle)
	if pattern.count("*") == 1:
		compiled.is_simple = true
		var star_pos := pattern.find("*")
		compiled.prefix = pattern.substr(0, star_pos).to_lower()
		compiled.suffix = pattern.substr(star_pos + 1).to_lower()
		compiled.regex = null
	else:
		# Convert glob pattern to regex
		compiled.is_simple = false
		var regex_pattern := "^" + _glob_to_regex(pattern) + "$"
		compiled.regex = RegEx.new()
		var err := compiled.regex.compile(regex_pattern)
		if err != OK:
			push_warning("CollisionShapeLibrary: Failed to compile pattern '%s'" % pattern)
			return

	_patterns.append(compiled)


## Convert glob pattern to regex pattern
func _glob_to_regex(glob: String) -> String:
	var result := ""
	for c in glob:
		match c:
			"*":
				result += ".*"
			"?":
				result += "."
			".":
				result += "\\."
			"[", "]", "(", ")", "{", "}", "^", "$", "+", "|", "\\":
				result += "\\" + c
			_:
				result += c
	return result


## Look up the collision shape for an item ID
## Returns null if no explicit mapping found (use auto-detection)
func get_shape_for_item(item_id: String) -> Variant:  ## Returns ShapeType or null
	if not _loaded:
		return null

	var lower_id := item_id.to_lower()

	# Check exact match first
	if lower_id in _item_shapes:
		if debug_mode:
			print("CollisionShapeLibrary: Exact match for '%s' -> %s" % [
				item_id, ShapeType.keys()[_item_shapes[lower_id]]
			])
		return _item_shapes[lower_id]

	# Check patterns (first match wins)
	for compiled in _patterns:
		if _pattern_matches(compiled, lower_id):
			if debug_mode:
				print("CollisionShapeLibrary: Pattern '%s' matched '%s' -> %s" % [
					compiled.pattern, item_id, ShapeType.keys()[compiled.shape_type]
				])
			return compiled.shape_type

	# No match found
	return null


## Check if a compiled pattern matches an item ID
func _pattern_matches(compiled: CompiledPattern, item_id_lower: String) -> bool:
	if compiled.is_simple:
		# Simple * wildcard matching
		if compiled.prefix.is_empty() and compiled.suffix.is_empty():
			return true  ## Pattern is just "*"
		elif compiled.prefix.is_empty():
			return item_id_lower.ends_with(compiled.suffix)
		elif compiled.suffix.is_empty():
			return item_id_lower.begins_with(compiled.prefix)
		else:
			return item_id_lower.begins_with(compiled.prefix) and item_id_lower.ends_with(compiled.suffix)
	else:
		# Regex matching
		if compiled.regex == null:
			return false
		var match_result := compiled.regex.search(item_id_lower)
		return match_result != null


## Create a Godot Shape3D from ShapeType and AABB bounds
## This creates a primitive shape sized to fit the given bounds
static func create_shape_from_type(shape_type: ShapeType, bounds: AABB) -> Shape3D:
	var center := bounds.get_center()
	var size := bounds.size

	match shape_type:
		ShapeType.BOX:
			var box := BoxShape3D.new()
			box.size = size
			return box

		ShapeType.SPHERE:
			var sphere := SphereShape3D.new()
			# Use half the longest dimension as radius
			sphere.radius = maxf(maxf(size.x, size.y), size.z) * 0.5
			return sphere

		ShapeType.CYLINDER:
			var cylinder := CylinderShape3D.new()
			# Height is Y, radius is average of X/Z
			cylinder.height = size.y
			cylinder.radius = (size.x + size.z) * 0.25
			return cylinder

		ShapeType.CAPSULE:
			var capsule := CapsuleShape3D.new()
			# Height is Y, radius is average of X/Z
			capsule.radius = (size.x + size.z) * 0.25
			capsule.height = size.y
			return capsule

		_:
			# CONVEX, TRIMESH, AUTO - return null, caller should use geometry
			return null


## Get shape type name for debugging
static func shape_type_name(shape_type: ShapeType) -> String:
	return ShapeType.keys()[shape_type]


## Check if a shape type requires geometry data (not a simple primitive)
static func requires_geometry(shape_type: ShapeType) -> bool:
	return shape_type == ShapeType.CONVEX or shape_type == ShapeType.TRIMESH or shape_type == ShapeType.AUTO


## Reload the library from the original file
func reload() -> bool:
	if _yaml_path.is_empty():
		return false
	return load_from_file(_yaml_path)


## Check if the library is loaded
func is_loaded() -> bool:
	return _loaded


## Get statistics about loaded data
func get_stats() -> Dictionary:
	return {
		"loaded": _loaded,
		"item_count": _item_shapes.size(),
		"pattern_count": _patterns.size(),
		"yaml_path": _yaml_path
	}
