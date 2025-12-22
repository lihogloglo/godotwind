# TerrainTextureNameParser.gd
# Automatically parses texture filenames to assign deformation heights
# Designed for Morrowind/OpenMW texture naming conventions

class_name TerrainTextureNameParser
extends RefCounted

## Parsing rules for texture classification
var rules: Array[TextureRule] = []

## Special case overrides (exact filename matches)
var special_cases: Dictionary = {}

## Default fallback height if no rules match
var default_height: float = 0.05

## Case-sensitive matching
var case_sensitive: bool = false

## Debug logging
var debug: bool = false

func _init():
	# Initialize with Morrowind default rules
	_setup_morrowind_rules()

## Parse a texture filename and return suggested rest height
func parse_texture_name(filename: String) -> float:
	var clean_name = _clean_filename(filename)

	if debug:
		print("[Parser] Analyzing: ", filename, " → ", clean_name)

	# Check special cases first (exact matches)
	if special_cases.has(clean_name):
		var height = special_cases[clean_name]
		if debug:
			print("  → Special case match: %.3fm" % height)
		return height

	# Try pattern matching rules (in priority order)
	for rule in rules:
		if _matches_rule(clean_name, rule):
			if debug:
				print("  → Rule match '%s': %.3fm" % [rule.name, rule.height])
			return rule.height

	# Fallback
	if debug:
		print("  → No match, using default: %.3fm" % default_height)
	return default_height

## Batch parse texture list
func parse_texture_list(texture_names: Array) -> Dictionary:
	var results = {}
	for i in range(texture_names.size()):
		var name = texture_names[i]
		var height = parse_texture_name(name)
		results[i] = {
			"name": name,
			"height": height
		}
	return results

## Check if filename matches a rule
func _matches_rule(filename: String, rule: TextureRule) -> bool:
	# Must contain all required patterns
	for pattern in rule.contains:
		if not _contains_pattern(filename, pattern):
			return false

	# Must NOT contain any excluded patterns
	for pattern in rule.excludes:
		if _contains_pattern(filename, pattern):
			return false

	# Must start with prefix (if specified)
	if rule.prefix != "" and not filename.begins_with(_normalize(rule.prefix)):
		return false

	# Must end with suffix (if specified)
	if rule.suffix != "" and not filename.ends_with(_normalize(rule.suffix)):
		return false

	return true

## Check if filename contains pattern
func _contains_pattern(filename: String, pattern: String) -> bool:
	var normalized_filename = _normalize(filename)
	var normalized_pattern = _normalize(pattern)
	return normalized_filename.contains(normalized_pattern)

## Normalize string for comparison
func _normalize(text: String) -> String:
	return text.to_lower() if not case_sensitive else text

## Clean filename (remove path and extension)
func _clean_filename(path: String) -> String:
	# Remove path
	var filename = path.get_file()
	# Remove extension
	var base = filename.get_basename()
	return base

## Setup default Morrowind rules (priority order matters!)
func _setup_morrowind_rules():
	# Special cases (exact matches) - these override pattern rules
	special_cases = {
		# Grass-like textures with "snow" in name
		"tx_snow_grass": 0.03,      # Actually grass
		"tx_snow_grass_01": 0.03,
		"tx_snow_grass_02": 0.03,

		# Rocky textures with "snow" in name
		"tx_snow_rock": 0.00,       # Actually rock
		"tx_snow_rock_01": 0.00,
		"tx_snow_rock_02": 0.00,

		# Ice (hard surface)
		"tx_ice_01": 0.00,
		"tx_ice_02": 0.00,
		"tx_ice_03": 0.00,

		# Cobblestone/paved (hard surface)
		"tx_cobblestone_01": 0.00,
		"tx_cobblestone_02": 0.00,
		"tx_marble_white": 0.00,
		"tx_marble_dark": 0.00,

		# Water (no deformation)
		"tx_water": 0.00,
		"tx_lava": 0.00,
	}

	# Pattern-based rules (checked in order)
	# Higher priority rules first!

	# 1. HARD SURFACES (no deformation) - check these first
	add_rule("Rock", 0.00, ["rock"], ["snow_rock"])
	add_rule("Stone", 0.00, ["stone"])
	add_rule("Cobble", 0.00, ["cobble"])
	add_rule("Marble", 0.00, ["marble"])
	add_rule("Ice", 0.00, ["ice"])
	add_rule("Lava", 0.00, ["lava"])
	add_rule("Metal", 0.00, ["metal"])

	# 2. SNOW (before grass, since "snow_grass" exists)
	# Use "snow" but exclude "snow_grass" and "snow_rock"
	add_rule("Snow (Deep)", 0.25, ["snow"], ["grass", "rock", "light"])
	add_rule("Snow (Light)", 0.15, ["snow", "light"], ["grass", "rock"])

	# 3. ASH (Morrowind-specific)
	add_rule("Ash (Red)", 0.12, ["ash", "red"])
	add_rule("Ash (Gray/Generic)", 0.15, ["ash"], ["red"])

	# 4. MUD / WET SURFACES
	add_rule("Mud", 0.10, ["mud"])
	add_rule("Swamp", 0.10, ["swamp"])
	add_rule("Marsh", 0.10, ["marsh"])

	# 5. SAND
	add_rule("Sand", 0.08, ["sand"])

	# 6. DIRT
	add_rule("Dirt", 0.05, ["dirt"])
	add_rule("Soil", 0.05, ["soil"])

	# 7. GRASS (after snow_grass check)
	add_rule("Grass", 0.03, ["grass"])

	# 8. PATHS/ROADS (compacted)
	add_rule("Path", 0.02, ["path"])
	add_rule("Road", 0.02, ["road"])

## Add a pattern rule
func add_rule(name: String, height: float, contains: Array, excludes: Array = []) -> void:
	var rule = TextureRule.new()
	rule.name = name
	rule.height = height
	rule.contains = contains
	rule.excludes = excludes
	rules.append(rule)

## Add a special case (exact filename match)
func add_special_case(filename: String, height: float) -> void:
	special_cases[_clean_filename(filename)] = height

## Clear all rules
func clear_rules() -> void:
	rules.clear()

## Print all rules (debug)
func print_rules() -> void:
	print("=== Texture Name Parser Rules ===")
	print("Special Cases: ", special_cases.size())
	for filename in special_cases:
		print("  '%s' → %.3fm" % [filename, special_cases[filename]])

	print("\nPattern Rules: ", rules.size())
	for i in range(rules.size()):
		var rule = rules[i]
		print("  [%d] %s → %.3fm" % [i, rule.name, rule.height])
		print("      Contains: %s" % str(rule.contains))
		if rule.excludes.size() > 0:
			print("      Excludes: %s" % str(rule.excludes))
	print("==================================")

## Export configuration as TerrainDeformationTextureConfig
func create_config_from_terrain(terrain: Terrain3D) -> TerrainDeformationTextureConfig:
	var config = TerrainDeformationTextureConfig.new()

	var assets = terrain.get_assets()
	if assets == null:
		push_error("[Parser] Terrain3D has no assets!")
		return config

	var texture_list = assets.get_texture_list()
	if texture_list == null:
		push_error("[Parser] Terrain3D has no texture list!")
		return config

	if debug:
		print("[Parser] Processing %d textures..." % texture_list.size())

	for i in range(texture_list.size()):
		var texture_asset = texture_list[i]
		if texture_asset == null:
			continue

		# Get texture name (try multiple sources)
		var texture_name = _get_texture_name(texture_asset)
		if texture_name == "":
			if debug:
				print("  [%d] Skipped (no name)" % i)
			continue

		# Parse and assign height
		var height = parse_texture_name(texture_name)
		config.set_height(i, height, texture_name)

		if debug:
			print("  [%d] %s → %.3fm" % [i, texture_name, height])

	return config

## Get texture name from Terrain3DTextureAsset
func _get_texture_name(texture_asset) -> String:
	# Try resource name
	if texture_asset.has_method("get_name"):
		var name = texture_asset.get_name()
		if name != "":
			return name

	# Try albedo texture path
	if texture_asset.has_method("get_albedo_texture"):
		var albedo = texture_asset.get_albedo_texture()
		if albedo != null and albedo.resource_path != "":
			return albedo.resource_path

	return ""


# Rule definition for pattern matching
class TextureRule:
	var name: String = ""           # Human-readable name
	var height: float = 0.0          # Rest height in meters
	var contains: Array = []         # Must contain these patterns
	var excludes: Array = []         # Must NOT contain these patterns
	var prefix: String = ""          # Must start with (optional)
	var suffix: String = ""          # Must end with (optional)
