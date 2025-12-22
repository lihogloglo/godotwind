# TerrainDeformationTextureConfig.gd
# Configuration resource for terrain texture deformation heights
# Maps Terrain3D texture IDs to deformation rest heights

class_name TerrainDeformationTextureConfig
extends Resource

## List of texture height entries
@export var texture_heights: Array[TerrainDeformationTextureEntry] = []

## Preset configurations (quick setup)
enum Preset {
	CUSTOM,           ## User-defined
	MORROWIND,        ## Morrowind/OpenMW style
	SKYRIM,           ## Skyrim style
	OBLIVION,         ## Oblivion style
	SNOW_WORLD,       ## Heavy snow environment
	DESERT,           ## Desert/sand environment
	VOLCANIC          ## Volcanic ash environment
}

## Apply a preset configuration
func apply_preset(preset: Preset) -> void:
	texture_heights.clear()

	match preset:
		Preset.MORROWIND:
			_apply_morrowind_preset()
		Preset.SKYRIM:
			_apply_skyrim_preset()
		Preset.OBLIVION:
			_apply_oblivion_preset()
		Preset.SNOW_WORLD:
			_apply_snow_world_preset()
		Preset.DESERT:
			_apply_desert_preset()
		Preset.VOLCANIC:
			_apply_volcanic_preset()

## Get rest height for a texture ID
func get_height(texture_id: int) -> float:
	for entry in texture_heights:
		if entry.texture_id == texture_id:
			return entry.rest_height
	return 0.0

## Add or update a texture entry
func set_height(texture_id: int, height: float, name: String = "") -> void:
	# Find existing
	for entry in texture_heights:
		if entry.texture_id == texture_id:
			entry.rest_height = height
			if name != "":
				entry.texture_name = name
			return

	# Create new
	var new_entry = TerrainDeformationTextureEntry.new()
	new_entry.texture_id = texture_id
	new_entry.rest_height = height
	new_entry.texture_name = name if name != "" else "Texture %d" % texture_id
	texture_heights.append(new_entry)

## Preset: Morrowind/OpenMW
func _apply_morrowind_preset() -> void:
	# Adjust texture IDs to match YOUR Terrain3D setup!
	set_height(0, 0.15, "Ash (Gray)")
	set_height(1, 0.12, "Ash (Red)")
	set_height(2, 0.00, "Rock (Volcanic)")
	set_height(3, 0.00, "Rock (Black)")
	set_height(4, 0.05, "Dirt (Dry)")
	set_height(5, 0.10, "Mud (Bitter Coast)")
	set_height(6, 0.08, "Sand (Grazelands)")
	set_height(7, 0.03, "Grass (Grazelands)")
	set_height(8, 0.25, "Snow (Solstheim Deep)")
	set_height(9, 0.15, "Snow (Solstheim Light)")
	set_height(10, 0.00, "Cobblestone (Roads)")
	set_height(11, 0.00, "Marble (Vivec/Mournhold)")
	set_height(12, 0.00, "Ice (Frozen)")

## Preset: Skyrim
func _apply_skyrim_preset() -> void:
	set_height(0, 0.30, "Snow (Deep)")
	set_height(1, 0.20, "Snow (Medium)")
	set_height(2, 0.10, "Snow (Light)")
	set_height(3, 0.00, "Rock (Mountain)")
	set_height(4, 0.00, "Stone (Ruins)")
	set_height(5, 0.05, "Dirt (Tundra)")
	set_height(6, 0.08, "Mud (Swamp)")
	set_height(7, 0.03, "Grass (Plains)")
	set_height(8, 0.00, "Cobblestone (Roads)")
	set_height(9, 0.00, "Ice (Frozen Lake)")

## Preset: Oblivion
func _apply_oblivion_preset() -> void:
	set_height(0, 0.05, "Grass (Cyrodiil)")
	set_height(1, 0.08, "Dirt (Roads)")
	set_height(2, 0.10, "Mud (Marsh)")
	set_height(3, 0.00, "Rock (Cliff)")
	set_height(4, 0.00, "Stone (Ruins)")
	set_height(5, 0.15, "Snow (Bruma)")
	set_height(6, 0.12, "Sand (Desert)")
	set_height(7, 0.00, "Cobblestone (Imperial City)")

## Preset: Snow World
func _apply_snow_world_preset() -> void:
	set_height(0, 0.40, "Deep Powder Snow")
	set_height(1, 0.30, "Fresh Snow")
	set_height(2, 0.20, "Packed Snow")
	set_height(3, 0.10, "Icy Snow")
	set_height(4, 0.00, "Solid Ice")
	set_height(5, 0.00, "Rock (Exposed)")

## Preset: Desert
func _apply_desert_preset() -> void:
	set_height(0, 0.12, "Loose Sand (Dunes)")
	set_height(1, 0.08, "Compact Sand")
	set_height(2, 0.05, "Hard Sand")
	set_height(3, 0.00, "Rock (Desert)")
	set_height(4, 0.00, "Stone (Ruins)")
	set_height(5, 0.15, "Dust")

## Preset: Volcanic
func _apply_volcanic_preset() -> void:
	set_height(0, 0.18, "Loose Ash")
	set_height(1, 0.12, "Packed Ash")
	set_height(2, 0.08, "Volcanic Dust")
	set_height(3, 0.00, "Volcanic Rock")
	set_height(4, 0.00, "Obsidian")
	set_height(5, 0.00, "Lava Rock")

## Debug: Print configuration
func print_config() -> void:
	print("=== Terrain Deformation Config ===")
	print("Textures: ", texture_heights.size())
	for entry in texture_heights:
		print("  [%2d] %-25s: %.3fm" % [entry.texture_id, entry.texture_name, entry.rest_height])
	print("==================================")


# Individual texture entry
class_name TerrainDeformationTextureEntry
extends Resource

## Terrain3D texture slot ID (0-31)
@export_range(0, 31, 1) var texture_id: int = 0

## Deformation rest height in meters (0.0 = no deformation)
@export_range(0.0, 1.0, 0.01, "or_greater") var rest_height: float = 0.0

## Human-readable name for this texture (optional, for editor clarity)
@export var texture_name: String = ""

## Category/type hint (optional)
@export_enum("Soft", "Medium", "Hard") var category: String = "Medium"

## Notes (optional)
@export_multiline var notes: String = ""
