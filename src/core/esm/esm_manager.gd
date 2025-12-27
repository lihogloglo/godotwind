## ESM Manager - Global autoload for managing ESM/ESP files
## Handles loading, storing, and querying game data from Morrowind files
## Note: No class_name here - this is an autoload singleton accessed via "ESMManager"
##
## PERFORMANCE OPTIMIZATIONS:
## - Unified _all_records dictionary for O(1) get_any_record() lookup
## - Type-based dispatch table instead of if-elif chain for _store_record()
## - Strict typing on all dictionaries for GDScript compiler optimization
## - Native C# ESM loader (10-30x faster) when available via NativeBridge
extends Node

const NativeBridgeScript := preload("res://src/core/native_bridge.gd")

# Signals
signal loading_started(file_path: String)
signal loading_progress(file_path: String, progress: float)
signal loading_completed(file_path: String, record_count: int)
signal loading_failed(file_path: String, error: String)

#region Record stores - keyed by record ID (lowercase for case-insensitive lookup)

# UNIFIED RECORD LOOKUP - O(1) access for get_any_record()
# Maps lowercase ID -> {record: ESMRecord, type: String}
var _all_records: Dictionary = {}

# World/Environment
var statics: Dictionary = {}           # String -> StaticRecord
var cells: Dictionary = {}             # String -> CellRecord
var lands: Dictionary = {}             # String -> LandRecord
var land_textures: Dictionary = {}     # String -> LandTextureRecord
var regions: Dictionary = {}           # String -> RegionRecord
var pathgrids: Dictionary = {}         # String -> PathgridRecord

# Actors
var npcs: Dictionary = {}              # String -> NPCRecord
var creatures: Dictionary = {}         # String -> CreatureRecord
var body_parts: Dictionary = {}        # String -> BodyPartRecord

# Items
var weapons: Dictionary = {}           # String -> WeaponRecord
var armors: Dictionary = {}            # String -> ArmorRecord
var clothing: Dictionary = {}          # String -> ClothingRecord
var books: Dictionary = {}             # String -> BookRecord
var potions: Dictionary = {}           # String -> PotionRecord
var ingredients: Dictionary = {}       # String -> IngredientRecord
var misc_items: Dictionary = {}        # String -> MiscRecord
var containers: Dictionary = {}        # String -> ContainerRecord
var lights: Dictionary = {}            # String -> LightRecord
var doors: Dictionary = {}             # String -> DoorRecord
var activators: Dictionary = {}        # String -> ActivatorRecord
var apparatus: Dictionary = {}         # String -> ApparatusRecord
var lockpicks: Dictionary = {}         # String -> LockpickRecord
var probes: Dictionary = {}            # String -> ProbeRecord
var repair_items: Dictionary = {}      # String -> RepairRecord

# Magic
var spells: Dictionary = {}            # String -> SpellRecord
var enchantments: Dictionary = {}      # String -> EnchantmentRecord
var magic_effects: Dictionary = {}     # String -> MagicEffectRecord

# Character Definition
var classes: Dictionary = {}           # String -> ClassRecord
var races: Dictionary = {}             # String -> RaceRecord
var factions: Dictionary = {}          # String -> FactionRecord
var skills: Dictionary = {}            # String -> SkillRecord
var birthsigns: Dictionary = {}        # String -> BirthsignRecord

# Dialogue
var dialogues: Dictionary = {}         # String -> DialogueRecord
var dialogue_infos: Dictionary = {}    # String -> Array[DialogueInfoRecord]

# Audio
var sounds: Dictionary = {}            # String -> SoundRecord
var sound_generators: Dictionary = {}  # String -> SoundGenRecord

# Scripts & Settings
var scripts: Dictionary = {}           # String -> ScriptRecord
var game_settings: Dictionary = {}     # String -> GameSettingRecord
var globals: Dictionary = {}           # String -> GlobalRecord
var start_scripts: Array[String] = []  # StartScriptRecord IDs

# Leveled Lists
var leveled_items: Dictionary = {}     # String -> LeveledItemRecord
var leveled_creatures: Dictionary = {} # String -> LeveledCreatureRecord

#endregion

# Exterior cells indexed by grid coordinates
var exterior_cells: Dictionary = {}  # "x,y" -> CellRecord

# Loaded files
var loaded_files: Array[String] = []

# Statistics
var total_records_loaded: int = 0
var records_by_type: Dictionary = {}  # String -> int
var load_time_ms: float = 0.0

# Current dialogue topic being loaded (INFO records follow DIAL)
var _current_dialogue_topic: String = ""

# Native C# ESM loader (if available) - 10-30x faster than GDScript
var _native_loader: RefCounted = null
var _use_native: bool = false

# Record type dispatch table - maps rec_type int to storage info
# Initialized in _init() for O(1) dispatch instead of O(n) if-elif chain
var _store_dispatch: Dictionary = {}  # int -> Dictionary {dict, type_name, use_original_key}
var _remove_dispatch: Dictionary = {}  # int -> Dictionary


func _init() -> void:
	# Initialize dispatch tables for O(1) record storage
	# This replaces the O(n) if-elif chain in _store_record()
	_store_dispatch = {
		# World/Environment
		ESMDefs.RecordType.REC_STAT: {"dict": statics, "type": "static"},
		ESMDefs.RecordType.REC_CELL: {"dict": cells, "type": "cell", "special": "cell"},
		ESMDefs.RecordType.REC_LAND: {"dict": lands, "type": "land", "use_original_key": true},
		ESMDefs.RecordType.REC_LTEX: {"dict": land_textures, "type": "land_texture"},
		ESMDefs.RecordType.REC_REGN: {"dict": regions, "type": "region"},
		ESMDefs.RecordType.REC_PGRD: {"dict": pathgrids, "type": "pathgrid", "use_original_key": true},
		# Actors
		ESMDefs.RecordType.REC_NPC_: {"dict": npcs, "type": "npc"},
		ESMDefs.RecordType.REC_CREA: {"dict": creatures, "type": "creature"},
		ESMDefs.RecordType.REC_BODY: {"dict": body_parts, "type": "body_part"},
		# Items
		ESMDefs.RecordType.REC_WEAP: {"dict": weapons, "type": "weapon"},
		ESMDefs.RecordType.REC_ARMO: {"dict": armors, "type": "armor"},
		ESMDefs.RecordType.REC_CLOT: {"dict": clothing, "type": "clothing"},
		ESMDefs.RecordType.REC_BOOK: {"dict": books, "type": "book"},
		ESMDefs.RecordType.REC_ALCH: {"dict": potions, "type": "potion"},
		ESMDefs.RecordType.REC_INGR: {"dict": ingredients, "type": "ingredient"},
		ESMDefs.RecordType.REC_MISC: {"dict": misc_items, "type": "misc"},
		ESMDefs.RecordType.REC_CONT: {"dict": containers, "type": "container"},
		ESMDefs.RecordType.REC_LIGH: {"dict": lights, "type": "light"},
		ESMDefs.RecordType.REC_DOOR: {"dict": doors, "type": "door"},
		ESMDefs.RecordType.REC_ACTI: {"dict": activators, "type": "activator"},
		ESMDefs.RecordType.REC_APPA: {"dict": apparatus, "type": "apparatus"},
		ESMDefs.RecordType.REC_LOCK: {"dict": lockpicks, "type": "lockpick"},
		ESMDefs.RecordType.REC_PROB: {"dict": probes, "type": "probe"},
		ESMDefs.RecordType.REC_REPA: {"dict": repair_items, "type": "repair"},
		# Magic
		ESMDefs.RecordType.REC_SPEL: {"dict": spells, "type": "spell"},
		ESMDefs.RecordType.REC_ENCH: {"dict": enchantments, "type": "enchantment"},
		ESMDefs.RecordType.REC_MGEF: {"dict": magic_effects, "type": "magic_effect"},
		# Character Definition
		ESMDefs.RecordType.REC_CLAS: {"dict": classes, "type": "class"},
		ESMDefs.RecordType.REC_RACE: {"dict": races, "type": "race"},
		ESMDefs.RecordType.REC_FACT: {"dict": factions, "type": "faction"},
		ESMDefs.RecordType.REC_SKIL: {"dict": skills, "type": "skill"},
		ESMDefs.RecordType.REC_BSGN: {"dict": birthsigns, "type": "birthsign"},
		# Dialogue
		ESMDefs.RecordType.REC_DIAL: {"dict": dialogues, "type": "dialogue"},
		ESMDefs.RecordType.REC_INFO: {"dict": dialogue_infos, "type": "dialogue_info", "special": "info"},
		# Audio
		ESMDefs.RecordType.REC_SOUN: {"dict": sounds, "type": "sound"},
		ESMDefs.RecordType.REC_SNDG: {"dict": sound_generators, "type": "sound_generator"},
		# Scripts & Settings
		ESMDefs.RecordType.REC_SCPT: {"dict": scripts, "type": "script"},
		ESMDefs.RecordType.REC_GMST: {"dict": game_settings, "type": "game_setting"},
		ESMDefs.RecordType.REC_GLOB: {"dict": globals, "type": "global"},
		ESMDefs.RecordType.REC_SSCR: {"dict": null, "type": "start_script", "special": "start_script"},
		# Leveled Lists
		ESMDefs.RecordType.REC_LEVI: {"dict": leveled_items, "type": "leveled_item"},
		ESMDefs.RecordType.REC_LEVC: {"dict": leveled_creatures, "type": "leveled_creature"},
	}


## Load an ESM or ESP file
## Uses native C# loader with caching for performance (<50ms on cache hit)
## Falls back to GDScript if C# unavailable (significantly slower, ~10-30x)
func load_file(path: String) -> Error:
	loading_started.emit(path)

	# Try native C# loader with caching first (fastest path)
	if NativeBridgeScript.is_csharp_available():
		var result := _load_file_native_cached(path)
		if result == OK:
			return OK
		# Fall through to GDScript if native failed
		push_warning("ESMManager: Native C# loader failed, falling back to GDScript (10-30x slower)")

	# GDScript fallback - functional but slow
	# Consider using Godot Mono build for better performance
	if not NativeBridgeScript.is_csharp_available():
		push_warning("ESMManager: C# not available. Using GDScript loader (slow). " +
			"For better performance, use Godot Mono build.")

	return _load_file_gdscript(path)


## Load using native C# loader with caching (fastest path)
func _load_file_native_cached(path: String) -> Error:
	var bridge := NativeBridgeScript.new()
	var start_time := Time.get_ticks_msec()

	# Get cache path from SettingsManager (supports custom cache locations)
	var esm_name := path.get_file().get_basename() + ".esmcache"
	var cache_path := SettingsManager.get_cache_base_path().path_join(esm_name)

	# Use cached loading - will use cache if valid, otherwise load and create cache
	var loader: RefCounted = bridge.load_esm_file_cached(path, cache_path)
	var csharp_time := Time.get_ticks_msec() - start_time

	if loader == null:
		return ERR_CANT_OPEN

	_native_loader = loader
	_use_native = true

	# Populate GDScript dictionaries from native data
	var populate_start := Time.get_ticks_msec()
	_populate_from_native(loader)
	var populate_time := Time.get_ticks_msec() - populate_start

	# Supplement with GDScript loading for record types not handled by C# loader
	# (NPCs, creatures, races, body_parts, etc.)
	var supplement_start := Time.get_ticks_msec()
	_supplement_actor_data(path)
	var supplement_time := Time.get_ticks_msec() - supplement_start

	var total_time := Time.get_ticks_msec() - start_time
	var stats: Dictionary = bridge.get_esm_stats(loader)
	total_records_loaded += stats.get("total_records", 0) as int
	load_time_ms += total_time as float
	loaded_files.append(path)

	# Detailed timing breakdown for optimization
	print("ESMManager: Loaded %s in %d ms (C#: %d ms, populate: %d ms, actors: %d ms)" % [
		path.get_file(), total_time, csharp_time, populate_time, supplement_time])
	loading_completed.emit(path, stats.get("total_records", 0) as int)

	return OK


## Load using native C# loader without caching (for testing)
func _load_file_native(path: String) -> Error:
	var bridge := NativeBridgeScript.new()
	var loader: RefCounted = bridge.load_esm_file(path, false)  # Don't lazy load for now

	if loader == null:
		return ERR_CANT_OPEN

	_native_loader = loader
	_use_native = true

	# Populate GDScript dictionaries from native data
	_populate_from_native(loader)

	var stats: Dictionary = bridge.get_esm_stats(loader)
	total_records_loaded += stats.get("total_records", 0) as int
	load_time_ms += stats.get("load_time_ms", 0.0) as float
	loaded_files.append(path)

	print("ESMManager: Loaded %s via native C# in %.1f ms" % [path, stats.get("load_time_ms", 0.0)])
	loading_completed.emit(path, stats.get("total_records", 0) as int)

	return OK


## Helper: Populate records from native loader using a converter function
## Reduces boilerplate for simple record types
@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
func _populate_simple_records(
	loader: RefCounted,
	native_property: String,
	target_dict: Dictionary,
	type_name: String,
	converter: Callable
) -> void:
	var native_dict: Variant = loader.get(native_property)
	if native_dict is Dictionary:
		for key: Variant in native_dict:
			var native_rec: RefCounted = native_dict[key]
			var rec: ESMRecord = converter.call(native_rec)
			target_dict[key] = rec
			_all_records[key] = {"record": rec, "type": type_name}


## Helper: Copy common base fields from native record to GDScript record
@warning_ignore("unsafe_method_access")
static func _copy_base_fields(native_rec: RefCounted, rec: ESMRecord) -> void:
	rec.record_id = native_rec.get("RecordId")
	rec.is_deleted = native_rec.get("IsDeleted")


## Helper: Copy model record fields (record_id, model, is_deleted)
@warning_ignore("unsafe_method_access")
static func _copy_model_fields(native_rec: RefCounted, rec: ESMRecord) -> void:
	_copy_base_fields(native_rec, rec)
	rec.set("model", native_rec.get("Model"))


## Helper: Copy named model record fields (adds name, script_id)
@warning_ignore("unsafe_method_access")
static func _copy_named_model_fields(native_rec: RefCounted, rec: ESMRecord) -> void:
	_copy_model_fields(native_rec, rec)
	rec.set("name", native_rec.get("Name"))
	rec.set("script_id", native_rec.get("ScriptId"))


## Enable verbose timing output for population phase (for profiling)
const VERBOSE_POPULATE_TIMING := false


## Populate GDScript record dictionaries from native C# loader
@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
func _populate_from_native(loader: RefCounted) -> void:
	var t0 := Time.get_ticks_msec()

	# Copy statics (simplest: just ID + model)
	_populate_simple_records(loader, "Statics", statics, "static",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := StaticRecord.new()
			_copy_model_fields(native_rec, rec)
			return rec)
	var t1 := Time.get_ticks_msec()

	# Copy doors
	_populate_simple_records(loader, "Doors", doors, "door",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := DoorRecord.new()
			_copy_named_model_fields(native_rec, rec)
			rec.open_sound = native_rec.get("OpenSound")
			rec.close_sound = native_rec.get("CloseSound")
			return rec)

	# Copy activators
	_populate_simple_records(loader, "Activators", activators, "activator",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := ActivatorRecord.new()
			_copy_named_model_fields(native_rec, rec)
			return rec)

	# Copy containers
	_populate_simple_records(loader, "Containers", containers, "container",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := ContainerRecord.new()
			_copy_named_model_fields(native_rec, rec)
			rec.weight = native_rec.get("Weight")
			rec.flags = native_rec.get("Flags")
			return rec)

	# Copy lights
	_populate_simple_records(loader, "Lights", lights, "light",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := LightRecord.new()
			_copy_named_model_fields(native_rec, rec)
			rec.weight = native_rec.get("Weight")
			rec.value = native_rec.get("Value")
			rec.time = native_rec.get("Time")
			rec.radius = native_rec.get("Radius")
			rec.color = native_rec.get("LightColor")
			rec.flags = native_rec.get("Flags")
			return rec)
	var t2 := Time.get_ticks_msec()

	# Copy cells
	var native_cells: Variant = loader.get("Cells")
	if native_cells is Dictionary:
		for key: Variant in native_cells:
			var native_cell: RefCounted = native_cells[key]
			var rec := CellRecord.new()
			rec.record_id = native_cell.get("RecordId")
			rec.name = native_cell.get("Name")
			rec.region_id = native_cell.get("RegionId")
			rec.flags = native_cell.get("Flags")
			rec.grid_x = native_cell.get("GridX")
			rec.grid_y = native_cell.get("GridY")
			rec.has_ambient = native_cell.get("HasAmbient")
			rec.ambient_color = native_cell.get("AmbientColor")
			rec.sunlight_color = native_cell.get("SunlightColor")
			rec.fog_color = native_cell.get("FogColor")
			rec.fog_density = native_cell.get("FogDensity")
			rec.water_height = native_cell.get("WaterHeight")
			rec.has_water_height = native_cell.get("HasWaterHeight")
			rec.map_color = native_cell.get("MapColor")

			# Copy cell references
			var native_refs: Variant = native_cell.get("References")
			if native_refs is Array:
				for native_ref_v: Variant in native_refs:
					var native_ref: RefCounted = native_ref_v as RefCounted
					if native_ref != null:
						var ref := CellReference.new()
						ref.ref_num = native_ref.get("RefNum") as int
						var ref_id_str: Variant = native_ref.get("RefId")
						ref.ref_id = StringName(str(ref_id_str))
						ref.position = native_ref.get("Position") as Vector3
						ref.rotation = native_ref.get("Rotation") as Vector3
						ref.scale = native_ref.get("Scale") as float
						ref.is_teleport = native_ref.get("IsTeleport") as bool
						ref.teleport_pos = native_ref.get("TeleportPos") as Vector3
						ref.teleport_rot = native_ref.get("TeleportRot") as Vector3
						var tp_cell: Variant = native_ref.get("TeleportCell")
						ref.teleport_cell = str(tp_cell) if tp_cell != null else ""
						ref.is_deleted = native_ref.get("IsDeleted") as bool
						rec.references.append(ref)

			cells[key] = rec
			_all_records[key] = {"record": rec, "type": "cell"}

			# Index exterior cells by grid
			if rec.is_exterior():
				exterior_cells["%d,%d" % [rec.grid_x, rec.grid_y]] = rec

	# Copy land records
	var native_lands: Variant = loader.get("Lands")
	if native_lands is Dictionary:
		for key: Variant in native_lands:
			var native_land: RefCounted = native_lands[key]
			var rec := LandRecord.new()
			rec.record_id = native_land.get("RecordId")
			rec.cell_x = native_land.get("CellX")
			rec.cell_y = native_land.get("CellY")

			# Copy height data
			var heights: Variant = native_land.get("Heights")
			if heights is PackedFloat32Array:
				rec.heights = heights
			elif heights is Array:
				rec.heights = PackedFloat32Array(heights as Array)

			# Copy normals
			var normals: Variant = native_land.get("Normals")
			if normals is PackedByteArray:
				rec.normals = normals

			# Copy texture indices
			var tex_indices: Variant = native_land.get("TextureIndices")
			if tex_indices is PackedInt32Array:
				rec.texture_indices = tex_indices
			elif tex_indices is Array:
				rec.texture_indices = PackedInt32Array(tex_indices as Array)

			# Copy vertex colors
			var colors: Variant = native_land.get("VertexColors")
			if colors is PackedByteArray:
				rec.vertex_colors = colors

			lands[key] = rec
			_all_records[key] = {"record": rec, "type": "land"}

	var t3 := Time.get_ticks_msec()

	# Copy land textures
	_populate_simple_records(loader, "LandTextures", land_textures, "land_texture",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := LandTextureRecord.new()
			rec.record_id = str(native_rec.get("RecordId"))
			rec.texture_index = native_rec.get("Index") as int
			rec.texture_path = str(native_rec.get("Texture"))
			return rec)
	var t4 := Time.get_ticks_msec()

	# Copy NPCs
	_populate_simple_records(loader, "NPCs", npcs, "npc",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := NPCRecord.new()
			_copy_model_fields(native_rec, rec)
			rec.name = str(native_rec.get("Name"))
			rec.script_id = str(native_rec.get("ScriptId"))
			rec.race_id = str(native_rec.get("RaceId"))
			rec.class_id = str(native_rec.get("ClassId"))
			rec.faction_id = str(native_rec.get("FactionId"))
			rec.head_id = str(native_rec.get("HeadId"))
			rec.hair_id = str(native_rec.get("HairId"))
			rec.npc_flags = native_rec.get("NpcFlags") as int
			rec.level = native_rec.get("Level") as int
			rec.health = native_rec.get("Health") as int
			rec.mana = native_rec.get("Mana") as int
			rec.fatigue = native_rec.get("Fatigue") as int
			rec.disposition = native_rec.get("Disposition") as int
			rec.reputation = native_rec.get("Reputation") as int
			rec.rank = native_rec.get("Rank") as int
			rec.gold = native_rec.get("Gold") as int
			return rec)

	# Copy Creatures
	_populate_simple_records(loader, "Creatures", creatures, "creature",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := CreatureRecord.new()
			_copy_model_fields(native_rec, rec)
			rec.name = str(native_rec.get("Name"))
			rec.script_id = str(native_rec.get("ScriptId"))
			rec.original_id = str(native_rec.get("OriginalId"))
			rec.creature_flags = native_rec.get("CreatureFlags") as int
			rec.scale = native_rec.get("Scale") as float
			rec.creature_type = native_rec.get("CreatureType") as int
			rec.level = native_rec.get("Level") as int
			rec.health = native_rec.get("Health") as int
			rec.mana = native_rec.get("Mana") as int
			rec.fatigue = native_rec.get("Fatigue") as int
			rec.soul = native_rec.get("Soul") as int
			rec.combat = native_rec.get("Combat") as int
			rec.magic = native_rec.get("Magic") as int
			rec.stealth = native_rec.get("Stealth") as int
			rec.gold = native_rec.get("Gold") as int
			return rec)

	# Copy Races
	_populate_simple_records(loader, "Races", races, "race",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := RaceRecord.new()
			rec.record_id = str(native_rec.get("RecordId"))
			rec.is_deleted = native_rec.get("IsDeleted") as bool
			rec.name = str(native_rec.get("Name"))
			rec.description = str(native_rec.get("Description"))
			rec.male_height = native_rec.get("MaleHeight") as float
			rec.female_height = native_rec.get("FemaleHeight") as float
			rec.male_weight = native_rec.get("MaleWeight") as float
			rec.female_weight = native_rec.get("FemaleWeight") as float
			rec.flags = native_rec.get("Flags") as int
			return rec)

	# Copy BodyParts
	_populate_simple_records(loader, "BodyParts", body_parts, "body_part",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := BodyPartRecord.new()
			_copy_model_fields(native_rec, rec)
			rec.part_type = native_rec.get("PartType") as int
			rec.is_vampire = native_rec.get("IsVampire") as bool
			rec.flags = native_rec.get("Flags") as int
			rec.mesh_type = native_rec.get("MeshType") as int
			return rec)

	# Copy Weapons
	_populate_simple_records(loader, "Weapons", weapons, "weapon",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := WeaponRecord.new()
			_copy_named_model_fields(native_rec, rec)
			rec.icon = str(native_rec.get("Icon"))
			rec.enchant_id = str(native_rec.get("EnchantId"))
			rec.weight = native_rec.get("Weight") as float
			rec.value = native_rec.get("Value") as int
			rec.weapon_type = native_rec.get("WeaponType") as int
			rec.health = native_rec.get("Health") as int
			rec.speed = native_rec.get("Speed") as float
			rec.reach = native_rec.get("Reach") as float
			rec.enchant_points = native_rec.get("EnchantPoints") as int
			rec.chop_min = native_rec.get("ChopMin") as int
			rec.chop_max = native_rec.get("ChopMax") as int
			rec.slash_min = native_rec.get("SlashMin") as int
			rec.slash_max = native_rec.get("SlashMax") as int
			rec.thrust_min = native_rec.get("ThrustMin") as int
			rec.thrust_max = native_rec.get("ThrustMax") as int
			rec.flags = native_rec.get("Flags") as int
			return rec)

	# Copy Armors
	_populate_simple_records(loader, "Armors", armors, "armor",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := ArmorRecord.new()
			_copy_named_model_fields(native_rec, rec)
			rec.icon = str(native_rec.get("Icon"))
			rec.enchant_id = str(native_rec.get("EnchantId"))
			rec.armor_type = native_rec.get("ArmorType") as int
			rec.weight = native_rec.get("Weight") as float
			rec.value = native_rec.get("Value") as int
			rec.health = native_rec.get("Health") as int
			rec.enchant_points = native_rec.get("EnchantPoints") as int
			rec.armor_rating = native_rec.get("ArmorRating") as int
			return rec)

	# Copy Clothing
	_populate_simple_records(loader, "Clothing", clothing, "clothing",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := ClothingRecord.new()
			_copy_named_model_fields(native_rec, rec)
			rec.icon = str(native_rec.get("Icon"))
			rec.enchant_id = str(native_rec.get("EnchantId"))
			rec.clothing_type = native_rec.get("ClothingType") as int
			rec.weight = native_rec.get("Weight") as float
			rec.value = native_rec.get("Value") as int
			rec.enchant_points = native_rec.get("EnchantPoints") as int
			return rec)

	var t5 := Time.get_ticks_msec()

	# Output timing breakdown if verbose profiling enabled
	if VERBOSE_POPULATE_TIMING:
		var ref_count := 0
		for cell_key: Variant in cells:
			var cell_rec: CellRecord = cells[cell_key]
			ref_count += cell_rec.references.size()
		print("  Populate timing: statics=%dms, simple=%dms, cells+refs=%dms (%d refs), lands+ltex=%dms, actors+items=%dms" % [
			t1 - t0, t2 - t1, t3 - t2, ref_count, t4 - t3, t5 - t4])


## Supplement native C# load with actor data not handled by native loader
## This loads classes, factions, skills, birthsigns, and leveled creatures
## that are not yet implemented in the C# loader
## using GDScript parsing (slower but comprehensive)
func _supplement_actor_data(path: String) -> void:
	var reader := ESMReader.new()
	var err := reader.open(path)
	if err != OK:
		push_warning("ESMManager: Failed to open ESM for actor supplement: %s" % path)
		return

	var records_loaded := 0
	# Note: NPC_, CREA, RACE, BODY, WEAP, ARMO, CLOT are now handled by C# loader
	var target_types := [
		ESMDefs.RecordType.REC_CLAS,
		ESMDefs.RecordType.REC_FACT,
		ESMDefs.RecordType.REC_SKIL,
		ESMDefs.RecordType.REC_BSGN,
		ESMDefs.RecordType.REC_LEVC,  # Leveled creatures
	]

	while reader.has_more_recs():
		var rec_name := reader.get_rec_name()
		reader.get_rec_header()

		# Only parse actor-related record types
		if rec_name in target_types:
			var record := _load_record(reader, rec_name)
			if record != null:
				_store_record(record, rec_name)
				records_loaded += 1

		# Always skip to ensure we're at the correct position for the next record
		# This handles cases where parsers don't read all subrecords
		reader.skip_record()

	reader.close()

	if records_loaded > 0:
		print("ESMManager: Supplemented %d records (Classes: %d, Factions: %d, Skills: %d, Birthsigns: %d)" % [
			records_loaded, classes.size(), factions.size(), skills.size(), birthsigns.size()
		])


## Load using GDScript (fallback path)
func _load_file_gdscript(path: String) -> Error:
	var start_time := Time.get_ticks_msec()

	var reader := ESMReader.new()
	var err := reader.open(path)
	if err != OK:
		loading_failed.emit(path, "Failed to open file")
		return err

	print("Loading: %s" % path)
	print("  Author: %s" % reader.header.author)
	print("  Description: %s" % reader.header.description.substr(0, 100))
	print("  Records: %d" % reader.header.record_count)

	if reader.header.master_files.size() > 0:
		print("  Masters:")
		for master in reader.header.master_files:
			print("    - %s (%d bytes)" % [master.name, master.size])

	# Load all records
	var records_loaded := 0
	var records_parsed := 0
	var skipped_types: Dictionary = {}
	var expected_records := reader.header.record_count

	while reader.has_more_recs():
		var rec_name := reader.get_rec_name()
		reader.get_rec_header()

		var record := _load_record(reader, rec_name)
		if record != null:
			_store_record(record, rec_name)
			records_parsed += 1
		else:
			# Track skipped record types
			var skipped_type_name := ESMDefs.four_cc_to_string(rec_name)
			skipped_types[skipped_type_name] = skipped_types.get(skipped_type_name, 0) + 1

		# Safety: Always ensure we're at record end position
		# This handles cases where parsers don't read all subrecords
		reader.skip_record()

		# Track by type
		var type_name := ESMDefs.four_cc_to_string(rec_name)
		records_by_type[type_name] = records_by_type.get(type_name, 0) + 1

		records_loaded += 1

		# Emit progress every 1000 records
		if records_loaded % 1000 == 0:
			var progress := float(records_loaded) / float(expected_records)
			loading_progress.emit(path, progress)

	reader.close()

	var elapsed := Time.get_ticks_msec() - start_time
	load_time_ms += elapsed
	total_records_loaded += records_parsed
	loaded_files.append(path)

	print("  Loaded %d records in %d ms" % [records_parsed, elapsed])

	# Debug: Show skipped record types
	if skipped_types.size() > 0:
		print("  Skipped record types:")
		var sorted_skipped := skipped_types.keys()
		sorted_skipped.sort()
		for type_name: String in sorted_skipped:
			print("    %s: %d" % [type_name, skipped_types[type_name]])
	loading_completed.emit(path, records_loaded)

	return OK

## Load a record based on its type
func _load_record(reader: ESMReader, rec_type: int) -> ESMRecord:
	match rec_type:
		# World/Environment
		ESMDefs.RecordType.REC_STAT:
			var rec := StaticRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_CELL:
			var rec := CellRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_LAND:
			var rec := LandRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_LTEX:
			var rec := LandTextureRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_REGN:
			var rec := RegionRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_PGRD:
			var rec := PathgridRecord.new()
			rec.load(reader)
			return rec

		# Actors
		ESMDefs.RecordType.REC_NPC_:
			var rec := NPCRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_CREA:
			var rec := CreatureRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_BODY:
			var rec := BodyPartRecord.new()
			rec.load(reader)
			return rec

		# Items
		ESMDefs.RecordType.REC_WEAP:
			var rec := WeaponRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_ARMO:
			var rec := ArmorRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_CLOT:
			var rec := ClothingRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_BOOK:
			var rec := BookRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_ALCH:
			var rec := PotionRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_INGR:
			var rec := IngredientRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_MISC:
			var rec := MiscRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_CONT:
			var rec := ContainerRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_LIGH:
			var rec := LightRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_DOOR:
			var rec := DoorRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_ACTI:
			var rec := ActivatorRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_APPA:
			var rec := ApparatusRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_LOCK:
			var rec := LockpickRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_PROB:
			var rec := ProbeRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_REPA:
			var rec := RepairRecord.new()
			rec.load(reader)
			return rec

		# Magic
		ESMDefs.RecordType.REC_SPEL:
			var rec := SpellRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_ENCH:
			var rec := EnchantmentRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_MGEF:
			var rec := MagicEffectRecord.new()
			rec.load(reader)
			return rec

		# Character Definition
		ESMDefs.RecordType.REC_CLAS:
			var rec := ClassRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_RACE:
			var rec := RaceRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_FACT:
			var rec := FactionRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_SKIL:
			var rec := SkillRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_BSGN:
			var rec := BirthsignRecord.new()
			rec.load(reader)
			return rec

		# Dialogue
		ESMDefs.RecordType.REC_DIAL:
			var rec := DialogueRecord.new()
			rec.load(reader)
			_current_dialogue_topic = rec.record_id
			return rec
		ESMDefs.RecordType.REC_INFO:
			var rec := DialogueInfoRecord.new()
			rec.load(reader)
			return rec

		# Audio
		ESMDefs.RecordType.REC_SOUN:
			var rec := SoundRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_SNDG:
			var rec := SoundGenRecord.new()
			rec.load(reader)
			return rec

		# Scripts & Settings
		ESMDefs.RecordType.REC_SCPT:
			var rec := ScriptRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_GMST:
			var rec := GameSettingRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_GLOB:
			var rec := GlobalRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_SSCR:
			var rec := StartScriptRecord.new()
			rec.load(reader)
			return rec

		# Leveled Lists
		ESMDefs.RecordType.REC_LEVI:
			var rec := LeveledItemRecord.new()
			rec.load(reader)
			return rec
		ESMDefs.RecordType.REC_LEVC:
			var rec := LeveledCreatureRecord.new()
			rec.load(reader)
			return rec

		_:
			# Skip unknown record types
			reader.skip_record()
			return null

## Store a record in the appropriate dictionary using O(1) dispatch table
## Also stores in unified _all_records for fast get_any_record() lookup
func _store_record(record: ESMRecord, rec_type: int) -> void:
	if record.is_deleted:
		_remove_record(record, rec_type)
		return

	var key := record.record_id.to_lower()

	# Get dispatch info - O(1) lookup instead of O(n) if-elif chain
	var dispatch: Dictionary = _store_dispatch.get(rec_type, {})
	if dispatch.is_empty():
		return

	var type_name: String = dispatch.get("type", "unknown")
	var target_dict: Dictionary = dispatch.get("dict", {})
	var special: String = dispatch.get("special", "")
	var use_original_key: bool = dispatch.get("use_original_key", false)

	# Determine the storage key
	var storage_key: String = record.record_id if use_original_key else key

	# Handle special cases
	match special:
		"cell":
			# CellRecord needs additional exterior_cells indexing
			var cell_rec := record as CellRecord
			target_dict[key] = cell_rec
			if cell_rec.is_exterior():
				var grid_key := "%d,%d" % [cell_rec.grid_x, cell_rec.grid_y]
				exterior_cells[grid_key] = cell_rec
			# Add to unified lookup
			_all_records[key] = {"record": record, "type": type_name}
		"info":
			# DialogueInfoRecord - group by current topic
			var topic_key := _current_dialogue_topic.to_lower()
			if not dialogue_infos.has(topic_key):
				dialogue_infos[topic_key] = []
			var info_list: Array = dialogue_infos[topic_key]
			info_list.append(record)
			# Don't add to _all_records - INFO records are looked up by topic
		"start_script":
			# StartScriptRecord - add to array, not dictionary
			if not record.record_id in start_scripts:
				start_scripts.append(record.record_id)
			# Don't add to _all_records - start scripts are looked up separately
		_:
			# Standard case - store in type-specific dict and unified lookup
			if target_dict != null:
				target_dict[storage_key] = record
			# Add to unified lookup for O(1) get_any_record()
			_all_records[key] = {"record": record, "type": type_name}


## Remove a deleted record - also removes from unified lookup
func _remove_record(record: ESMRecord, rec_type: int) -> void:
	var key := record.record_id.to_lower()

	match rec_type:
		ESMDefs.RecordType.REC_STAT: statics.erase(key)
		ESMDefs.RecordType.REC_CELL:
			cells.erase(key)
			if record is CellRecord:
				var cell_rec := record as CellRecord
				if cell_rec.is_exterior():
					var grid_key := "%d,%d" % [cell_rec.grid_x, cell_rec.grid_y]
					exterior_cells.erase(grid_key)
		ESMDefs.RecordType.REC_LAND: lands.erase(record.record_id)
		ESMDefs.RecordType.REC_LTEX: land_textures.erase(key)
		ESMDefs.RecordType.REC_REGN: regions.erase(key)
		ESMDefs.RecordType.REC_PGRD: pathgrids.erase(record.record_id)
		ESMDefs.RecordType.REC_NPC_: npcs.erase(key)
		ESMDefs.RecordType.REC_CREA: creatures.erase(key)
		ESMDefs.RecordType.REC_BODY: body_parts.erase(key)
		ESMDefs.RecordType.REC_WEAP: weapons.erase(key)
		ESMDefs.RecordType.REC_ARMO: armors.erase(key)
		ESMDefs.RecordType.REC_CLOT: clothing.erase(key)
		ESMDefs.RecordType.REC_BOOK: books.erase(key)
		ESMDefs.RecordType.REC_ALCH: potions.erase(key)
		ESMDefs.RecordType.REC_INGR: ingredients.erase(key)
		ESMDefs.RecordType.REC_MISC: misc_items.erase(key)
		ESMDefs.RecordType.REC_CONT: containers.erase(key)
		ESMDefs.RecordType.REC_LIGH: lights.erase(key)
		ESMDefs.RecordType.REC_DOOR: doors.erase(key)
		ESMDefs.RecordType.REC_ACTI: activators.erase(key)
		ESMDefs.RecordType.REC_APPA: apparatus.erase(key)
		ESMDefs.RecordType.REC_LOCK: lockpicks.erase(key)
		ESMDefs.RecordType.REC_PROB: probes.erase(key)
		ESMDefs.RecordType.REC_REPA: repair_items.erase(key)
		ESMDefs.RecordType.REC_SPEL: spells.erase(key)
		ESMDefs.RecordType.REC_ENCH: enchantments.erase(key)
		ESMDefs.RecordType.REC_MGEF: magic_effects.erase(key)
		ESMDefs.RecordType.REC_CLAS: classes.erase(key)
		ESMDefs.RecordType.REC_RACE: races.erase(key)
		ESMDefs.RecordType.REC_FACT: factions.erase(key)
		ESMDefs.RecordType.REC_SKIL: skills.erase(key)
		ESMDefs.RecordType.REC_BSGN: birthsigns.erase(key)
		ESMDefs.RecordType.REC_DIAL: dialogues.erase(key)
		ESMDefs.RecordType.REC_SOUN: sounds.erase(key)
		ESMDefs.RecordType.REC_SNDG: sound_generators.erase(key)
		ESMDefs.RecordType.REC_SCPT: scripts.erase(key)
		ESMDefs.RecordType.REC_GMST: game_settings.erase(key)
		ESMDefs.RecordType.REC_GLOB: globals.erase(key)
		ESMDefs.RecordType.REC_LEVI: leveled_items.erase(key)
		ESMDefs.RecordType.REC_LEVC: leveled_creatures.erase(key)

	# Also remove from unified lookup
	_all_records.erase(key)


#region Query functions

# World
func get_static(id: String) -> StaticRecord:
	return statics.get(id.to_lower())
func get_cell(cell_name: String) -> CellRecord:
	return cells.get(cell_name.to_lower())
func get_exterior_cell(x: int, y: int) -> CellRecord:
	return exterior_cells.get("%d,%d" % [x, y])
func get_land(x: int, y: int) -> LandRecord:
	return lands.get("%d,%d" % [x, y])
func get_land_texture(id: String) -> LandTextureRecord:
	return land_textures.get(id.to_lower())
func get_region(id: String) -> RegionRecord:
	return regions.get(id.to_lower())
func get_pathgrid(cell_name: String) -> PathgridRecord:
	return pathgrids.get(cell_name)
func get_exterior_pathgrid(x: int, y: int) -> PathgridRecord:
	return pathgrids.get("%d,%d" % [x, y])

# Actors
func get_npc(id: String) -> NPCRecord:
	return npcs.get(id.to_lower())
func get_creature(id: String) -> CreatureRecord:
	return creatures.get(id.to_lower())
func get_body_part(id: String) -> BodyPartRecord:
	return body_parts.get(id.to_lower())

# Items
func get_weapon(id: String) -> WeaponRecord:
	return weapons.get(id.to_lower())
func get_armor(id: String) -> ArmorRecord:
	return armors.get(id.to_lower())
func get_clothing(id: String) -> ClothingRecord:
	return clothing.get(id.to_lower())
func get_book(id: String) -> BookRecord:
	return books.get(id.to_lower())
func get_potion(id: String) -> PotionRecord:
	return potions.get(id.to_lower())
func get_ingredient(id: String) -> IngredientRecord:
	return ingredients.get(id.to_lower())
func get_misc_item(id: String) -> MiscRecord:
	return misc_items.get(id.to_lower())
func get_container(id: String) -> ContainerRecord:
	return containers.get(id.to_lower())
func get_light(id: String) -> LightRecord:
	return lights.get(id.to_lower())
func get_door(id: String) -> DoorRecord:
	return doors.get(id.to_lower())
func get_activator(id: String) -> ActivatorRecord:
	return activators.get(id.to_lower())
func get_apparatus(id: String) -> ApparatusRecord:
	return apparatus.get(id.to_lower())
func get_lockpick(id: String) -> LockpickRecord:
	return lockpicks.get(id.to_lower())
func get_probe(id: String) -> ProbeRecord:
	return probes.get(id.to_lower())
func get_repair_item(id: String) -> RepairRecord:
	return repair_items.get(id.to_lower())

# Magic
func get_spell(id: String) -> SpellRecord:
	return spells.get(id.to_lower())
func get_enchantment(id: String) -> EnchantmentRecord:
	return enchantments.get(id.to_lower())
func get_magic_effect(id: String) -> MagicEffectRecord:
	return magic_effects.get(id.to_lower())

# Character Definition
func get_class_record(id: String) -> ClassRecord:
	return classes.get(id.to_lower())
func get_race(id: String) -> RaceRecord:
	return races.get(id.to_lower())
func get_faction(id: String) -> FactionRecord:
	return factions.get(id.to_lower())
func get_skill(id: String) -> SkillRecord:
	return skills.get(id.to_lower())
func get_birthsign(id: String) -> BirthsignRecord:
	return birthsigns.get(id.to_lower())

# Dialogue
func get_dialogue(id: String) -> DialogueRecord:
	return dialogues.get(id.to_lower())
func get_dialogue_infos(topic: String) -> Array:
	return dialogue_infos.get(topic.to_lower(), [])

# Audio
func get_sound(id: String) -> SoundRecord:
	return sounds.get(id.to_lower())
func get_sound_generator(id: String) -> SoundGenRecord:
	return sound_generators.get(id.to_lower())

# Scripts & Settings
func get_script_record(id: String) -> ScriptRecord:
	return scripts.get(id.to_lower())
func get_game_setting(setting_name: String) -> GameSettingRecord:
	return game_settings.get(setting_name.to_lower())
func get_global(global_name: String) -> GlobalRecord:
	return globals.get(global_name.to_lower())
func get_start_scripts() -> Array[String]:
	return start_scripts

# Leveled Lists
func get_leveled_item(id: String) -> LeveledItemRecord:
	return leveled_items.get(id.to_lower())
func get_leveled_creature(id: String) -> LeveledCreatureRecord:
	return leveled_creatures.get(id.to_lower())

## Generic record lookup - O(1) unified lookup instead of O(n) sequential search
## Returns the record or null if not found
## Also returns the record type name via the optional out parameter
func get_any_record(id: String, out_type: Array = []) -> ESMRecord:
	var key := id.to_lower()

	# O(1) lookup in unified dictionary
	var entry: Dictionary = _all_records.get(key, {})
	if entry.is_empty():
		return null

	if out_type.size() > 0:
		out_type[0] = entry.get("type", "unknown")

	return entry.get("record") as ESMRecord

#endregion

#region Statistics

## Get a summary of loaded data
func get_stats() -> Dictionary:
	return {
		"files": loaded_files.size(),
		"total_records": total_records_loaded,
		"load_time_ms": load_time_ms,
		# World
		"statics": statics.size(),
		"cells": cells.size(),
		"exterior_cells": exterior_cells.size(),
		"lands": lands.size(),
		"land_textures": land_textures.size(),
		"regions": regions.size(),
		"pathgrids": pathgrids.size(),
		# Actors
		"npcs": npcs.size(),
		"creatures": creatures.size(),
		"body_parts": body_parts.size(),
		# Items
		"weapons": weapons.size(),
		"armors": armors.size(),
		"clothing": clothing.size(),
		"books": books.size(),
		"potions": potions.size(),
		"ingredients": ingredients.size(),
		"misc_items": misc_items.size(),
		"containers": containers.size(),
		"lights": lights.size(),
		"doors": doors.size(),
		"activators": activators.size(),
		"apparatus": apparatus.size(),
		"lockpicks": lockpicks.size(),
		"probes": probes.size(),
		"repair_items": repair_items.size(),
		# Magic
		"spells": spells.size(),
		"enchantments": enchantments.size(),
		"magic_effects": magic_effects.size(),
		# Character
		"classes": classes.size(),
		"races": races.size(),
		"factions": factions.size(),
		"skills": skills.size(),
		"birthsigns": birthsigns.size(),
		# Dialogue
		"dialogues": dialogues.size(),
		"dialogue_topics_with_infos": dialogue_infos.size(),
		# Audio
		"sounds": sounds.size(),
		"sound_generators": sound_generators.size(),
		# Scripts
		"scripts": scripts.size(),
		"game_settings": game_settings.size(),
		"globals": globals.size(),
		"start_scripts": start_scripts.size(),
		# Leveled
		"leveled_items": leveled_items.size(),
		"leveled_creatures": leveled_creatures.size(),
	}

## Print a summary of loaded data
func print_stats() -> void:
	var stats := get_stats()
	print("=== ESM Manager Stats ===")
	print("Files loaded: %d" % stats.files)
	print("Total records: %d" % stats.total_records)
	print("Load time: %.2f seconds" % (stats.load_time_ms / 1000.0))
	print("")
	print("--- World ---")
	print("  Statics: %d" % stats.statics)
	print("  Cells: %d (exterior: %d)" % [stats.cells, stats.exterior_cells])
	print("  Lands: %d" % stats.lands)
	print("  Land Textures: %d" % stats.land_textures)
	print("  Regions: %d" % stats.regions)
	print("  Pathgrids: %d" % stats.pathgrids)
	print("")
	print("--- Actors ---")
	print("  NPCs: %d" % stats.npcs)
	print("  Creatures: %d" % stats.creatures)
	print("  Body Parts: %d" % stats.body_parts)
	print("")
	print("--- Items ---")
	print("  Weapons: %d" % stats.weapons)
	print("  Armors: %d" % stats.armors)
	print("  Clothing: %d" % stats.clothing)
	print("  Books: %d" % stats.books)
	print("  Potions: %d" % stats.potions)
	print("  Ingredients: %d" % stats.ingredients)
	print("  Misc Items: %d" % stats.misc_items)
	print("  Containers: %d" % stats.containers)
	print("  Lights: %d" % stats.lights)
	print("  Doors: %d" % stats.doors)
	print("  Activators: %d" % stats.activators)
	print("")
	print("--- Magic ---")
	print("  Spells: %d" % stats.spells)
	print("  Enchantments: %d" % stats.enchantments)
	print("  Magic Effects: %d" % stats.magic_effects)
	print("")
	print("--- Character ---")
	print("  Classes: %d" % stats.classes)
	print("  Races: %d" % stats.races)
	print("  Factions: %d" % stats.factions)
	print("  Skills: %d" % stats.skills)
	print("  Birthsigns: %d" % stats.birthsigns)
	print("")
	print("--- Dialogue ---")
	print("  Topics: %d" % stats.dialogues)
	print("  Topics with responses: %d" % stats.dialogue_topics_with_infos)
	print("")
	print("--- Audio ---")
	print("  Sounds: %d" % stats.sounds)
	print("  Sound Generators: %d" % stats.sound_generators)
	print("")
	print("--- Scripts ---")
	print("  Scripts: %d" % stats.scripts)
	print("  Game Settings: %d" % stats.game_settings)
	print("  Globals: %d" % stats.globals)
	print("  Start Scripts: %d" % stats.start_scripts)
	print("")
	print("--- Leveled Lists ---")
	print("  Leveled Items: %d" % stats.leveled_items)
	print("  Leveled Creatures: %d" % stats.leveled_creatures)

	if records_by_type.size() > 0:
		print("")
		print("--- Records by Type ---")
		var sorted_types := records_by_type.keys()
		sorted_types.sort()
		for type_name: String in sorted_types:
			print("  %s: %d" % [type_name, records_by_type[type_name]])

#endregion
