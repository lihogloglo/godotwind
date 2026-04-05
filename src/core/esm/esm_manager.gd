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
var statics: Dictionary[String, StaticRecord] = {}
var cells: Dictionary[String, CellRecord] = {}
var lands: Dictionary[String, LandRecord] = {}
var land_textures: Dictionary[String, LandTextureRecord] = {}
var regions: Dictionary[String, RegionRecord] = {}
var pathgrids: Dictionary[String, PathgridRecord] = {}

# Actors
var npcs: Dictionary[String, NPCRecord] = {}
var creatures: Dictionary[String, CreatureRecord] = {}
var body_parts: Dictionary[String, BodyPartRecord] = {}

# Items
var weapons: Dictionary[String, WeaponRecord] = {}
var armors: Dictionary[String, ArmorRecord] = {}
var clothing: Dictionary[String, ClothingRecord] = {}
var books: Dictionary[String, BookRecord] = {}
var potions: Dictionary[String, PotionRecord] = {}
var ingredients: Dictionary[String, IngredientRecord] = {}
var misc_items: Dictionary[String, MiscRecord] = {}
var containers: Dictionary[String, ContainerRecord] = {}
var lights: Dictionary[String, LightRecord] = {}
var doors: Dictionary[String, DoorRecord] = {}
var activators: Dictionary[String, ActivatorRecord] = {}
var apparatus: Dictionary[String, ApparatusRecord] = {}
var lockpicks: Dictionary[String, LockpickRecord] = {}
var probes: Dictionary[String, ProbeRecord] = {}
var repair_items: Dictionary[String, RepairRecord] = {}

# Magic
var spells: Dictionary[String, SpellRecord] = {}
var enchantments: Dictionary[String, EnchantmentRecord] = {}
var magic_effects: Dictionary[String, MagicEffectRecord] = {}

# Character Definition
var classes: Dictionary[String, ClassRecord] = {}
var races: Dictionary[String, RaceRecord] = {}
var factions: Dictionary[String, FactionRecord] = {}
var skills: Dictionary[String, SkillRecord] = {}
var birthsigns: Dictionary[String, BirthsignRecord] = {}

# Dialogue
var dialogues: Dictionary[String, DialogueRecord] = {}
var dialogue_infos: Dictionary[String, Array] = {}    # String -> Array[DialogueInfoRecord]

# Audio
var sounds: Dictionary[String, SoundRecord] = {}
var sound_generators: Dictionary[String, SoundGenRecord] = {}

# Scripts & Settings
var scripts: Dictionary[String, ScriptRecord] = {}
var game_settings: Dictionary[String, GameSettingRecord] = {}
var globals: Dictionary[String, GlobalRecord] = {}
var start_scripts: Array[String] = []  # StartScriptRecord IDs

# Leveled Lists
var leveled_items: Dictionary[String, LeveledItemRecord] = {}
var leveled_creatures: Dictionary[String, LeveledCreatureRecord] = {}

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

# Cached bridge instance for on-demand record creation (avoids per-call allocation)
var _bridge: RefCounted = null

# Whether ensure_typed_dicts_populated() has already run
var _typed_dicts_populated: bool = false

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
	Log.info("esm", "Loaded %s in %d ms (C#: %d ms, populate: %d ms, actors: %d ms)" % [
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

	Log.info("esm", "Loaded %s via native C# in %.1f ms" % [path, stats.get("load_time_ms", 0.0)])
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
			# Only add to unified lookup if no collision, or if this type has higher priority
			# Priority: static/activator > container/door > misc/weapon > light
			# This prevents lights from overwriting statics with the same name (e.g., "bc mushroom 256")
			var dominated: bool = _all_records.has(key)
			var dominated_by: String = _all_records[key].get("type", "") if dominated else ""
			var dominated_priority: int = _get_type_priority(dominated_by) if dominated else -1
			var new_priority: int = _get_type_priority(type_name)
			if not dominated or new_priority > dominated_priority:
				_all_records[key] = {"record": rec, "type": type_name}
			elif dominated and "mushroom" in str(key):
				Log.debug("esm", "Key '%s': keeping %s (pri=%d) over %s (pri=%d)" % [
					key, dominated_by, dominated_priority, type_name, new_priority
				])


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

	# Cache bridge instance for on-demand record creation
	_bridge = NativeBridgeScript.new()

	# Batch cell + reference export — ~30 packed array marshals instead of ~1.2M .get() calls
	var packed_data: Dictionary = _bridge.export_all_cells_packed(loader)
	if not packed_data.is_empty():
		_populate_cells_from_packed(packed_data)
	else:
		push_warning("ESMManager: Batch cell export failed, falling back to per-record population")
		_populate_cells_from_native_fallback(loader)
	var t1 := Time.get_ticks_msec()
	Log.info("esm", "Cell+ref batch populate: %d ms (was ~7000ms)" % [t1 - t0])

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

	# Copy Races (EAGER - needed for NPC assembly)
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

	# Copy BodyParts (EAGER - needed for NPC assembly)
	_populate_simple_records(loader, "BodyParts", body_parts, "body_part",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := BodyPartRecord.new()
			_copy_model_fields(native_rec, rec)
			rec.part_type = native_rec.get("PartType") as int
			rec.is_vampire = native_rec.get("IsVampire") as bool
			rec.flags = native_rec.get("Flags") as int
			rec.mesh_type = native_rec.get("MeshType") as int
			return rec)

	var t5 := Time.get_ticks_msec()

	# All other record types (statics, doors, activators, containers, lights,
	# NPCs, creatures, weapons, armors, clothing) are loaded ON-DEMAND via
	# get_any_record() when first accessed. This eliminates ~5s of startup time
	# from ~1.4M individual C#↔GDScript boundary crossings.

	# Output timing breakdown if verbose profiling enabled
	if VERBOSE_POPULATE_TIMING:
		var ref_count := 0
		for cell_key: Variant in cells:
			var cell_rec: CellRecord = cells[cell_key]
			ref_count += cell_rec.references.size()
		Log.debug("esm", "Populate timing: cells=%dms (%d refs), lands=%dms, ltex=%dms, races+bparts=%dms" % [
			t1 - t0, ref_count, t3 - t1, t4 - t3, t5 - t4])


## Batch populate cells + references from packed arrays (Phase 1 optimization)
## All data is already in GDScript Variants after the single batch call.
## The inner loop creates GDScript objects from local arrays — no C# crossings.
@warning_ignore("unsafe_property_access")
func _populate_cells_from_packed(data: Dictionary) -> void:
	# Extract cell parallel arrays (single boundary crossing each)
	var keys: PackedStringArray = data["cell_keys"]
	var record_ids: PackedStringArray = data["cell_record_ids"]
	var names: PackedStringArray = data["cell_names"]
	var flags_arr: PackedInt32Array = data["cell_flags"]
	var grid_x_arr: PackedInt32Array = data["cell_grid_x"]
	var grid_y_arr: PackedInt32Array = data["cell_grid_y"]
	var region_ids: PackedStringArray = data["cell_region_ids"]
	var has_ambient_arr: PackedByteArray = data["cell_has_ambient"]
	var ambient_colors: PackedColorArray = data["cell_ambient_colors"]
	var sunlight_colors: PackedColorArray = data["cell_sunlight_colors"]
	var fog_colors: PackedColorArray = data["cell_fog_colors"]
	var fog_densities: PackedFloat32Array = data["cell_fog_densities"]
	var water_heights: PackedFloat32Array = data["cell_water_heights"]
	var has_water_arr: PackedByteArray = data["cell_has_water_heights"]
	var map_colors: PackedInt32Array = data["cell_map_colors"]

	# Extract reference flat arrays
	var ref_counts: PackedInt32Array = data["ref_counts"]
	var ref_ids: PackedStringArray = data["ref_ids"]
	var ref_nums: PackedInt32Array = data["ref_nums"]
	var ref_positions: PackedVector3Array = data["ref_positions"]
	var ref_rotations: PackedVector3Array = data["ref_rotations"]
	var ref_scales: PackedFloat32Array = data["ref_scales"]
	var ref_is_deleted: PackedByteArray = data["ref_is_deleted"]
	var ref_is_teleport: PackedByteArray = data["ref_is_teleport"]
	var ref_teleport_pos: PackedVector3Array = data["ref_teleport_pos"]
	var ref_teleport_rot: PackedVector3Array = data["ref_teleport_rot"]
	var ref_teleport_cells: PackedStringArray = data["ref_teleport_cells"]

	var cell_count: int = keys.size()
	var ref_offset: int = 0
	var total_refs: int = 0

	for i in cell_count:
		var rec := CellRecord.new()
		rec.record_id = record_ids[i]  # Original ESM record ID (preserves case for interiors)
		rec.name = names[i]
		rec.flags = flags_arr[i]
		rec.grid_x = grid_x_arr[i]
		rec.grid_y = grid_y_arr[i]
		rec.region_id = region_ids[i]
		rec.has_ambient = has_ambient_arr[i] != 0
		rec.ambient_color = ambient_colors[i]
		rec.sunlight_color = sunlight_colors[i]
		rec.fog_color = fog_colors[i]
		rec.fog_density = fog_densities[i]
		rec.water_height = water_heights[i]
		rec.has_water_height = has_water_arr[i] != 0
		rec.map_color = map_colors[i]

		# Create CellReferences from flat ref arrays (all local, no boundary crossings)
		var count: int = ref_counts[i]
		for j in count:
			var idx: int = ref_offset + j
			var ref := CellReference.new()
			ref.ref_id = StringName(ref_ids[idx])
			ref.ref_num = ref_nums[idx]
			ref.position = ref_positions[idx]
			ref.rotation = ref_rotations[idx]
			ref.scale = ref_scales[idx]
			ref.is_deleted = ref_is_deleted[idx] != 0
			ref.is_teleport = ref_is_teleport[idx] != 0
			ref.teleport_pos = ref_teleport_pos[idx]
			ref.teleport_rot = ref_teleport_rot[idx]
			ref.teleport_cell = ref_teleport_cells[idx]
			rec.references.append(ref)
		ref_offset += count
		total_refs += count

		cells[keys[i]] = rec
		_all_records[keys[i]] = {"record": rec, "type": "cell"}

		# Index exterior cells by grid
		if rec.is_exterior():
			exterior_cells["%d,%d" % [rec.grid_x, rec.grid_y]] = rec

	Log.info("esm", "Batch populated %d cells with %d refs from packed arrays" % [cell_count, total_refs])


## Fallback: populate cells per-record if batch export fails
@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
func _populate_cells_from_native_fallback(loader: RefCounted) -> void:
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

			if rec.is_exterior():
				exterior_cells["%d,%d" % [rec.grid_x, rec.grid_y]] = rec


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
		ESMDefs.RecordType.REC_BOOK,  # Books, scrolls, notes
		ESMDefs.RecordType.REC_DIAL,  # Dialogue topics
		ESMDefs.RecordType.REC_INFO,  # Dialogue info entries
		ESMDefs.RecordType.REC_LIGH,  # Light definitions (color, radius, flags)
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
		Log.info("esm", "Supplemented %d records (Classes: %d, Factions: %d, Skills: %d, Birthsigns: %d, Books: %d, Dialogues: %d, Lights: %d)" % [
			records_loaded, classes.size(), factions.size(), skills.size(), birthsigns.size(), books.size(), dialogues.size(), lights.size()
		])


## Load using GDScript (fallback path)
func _load_file_gdscript(path: String) -> Error:
	var start_time := Time.get_ticks_msec()

	var reader := ESMReader.new()
	var err := reader.open(path)
	if err != OK:
		loading_failed.emit(path, "Failed to open file")
		return err

	Log.info("esm", "Loading: %s" % path)
	Log.info("esm", "  Author: %s, Records: %d" % [reader.header.author, reader.header.record_count])
	if reader.header.master_files.size() > 0:
		for master in reader.header.master_files:
			Log.info("esm", "  Master: %s (%d bytes)" % [master.name, master.size])

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

	Log.info("esm", "  Loaded %d records in %d ms" % [records_parsed, elapsed])
	if skipped_types.size() > 0:
		var skipped_summary := ""
		var sorted_skipped := skipped_types.keys()
		sorted_skipped.sort()
		for type_name: String in sorted_skipped:
			skipped_summary += " %s:%d" % [type_name, skipped_types[type_name]]
		Log.debug("esm", "  Skipped types:%s" % skipped_summary)
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

## Get all body parts for a race and gender
## Morrowind body parts use naming convention: b_n_<race>_<gender>_<part>
## e.g., "b_n_dark elf_m_chest", "b_n_wood elf_f_hand"
func get_body_parts_for_race(race_id: String, is_female: bool) -> Array[BodyPartRecord]:
	var result: Array[BodyPartRecord] = []

	# Normalize race name for matching (lowercase, spaces)
	var race_lower := race_id.to_lower().strip_edges()
	var gender_char := "f" if is_female else "m"

	# Match pattern: b_n_<race>_<gender>_
	var prefix := "b_n_%s_%s_" % [race_lower, gender_char]

	for part_id: String in body_parts:
		var part: BodyPartRecord = body_parts[part_id]

		# Skip non-skin parts (clothing/armor overlays)
		if part.mesh_type != BodyPartRecord.MeshType.SKIN:
			continue

		# Skip vampire parts
		if part.is_vampire:
			continue

		# Check gender match via flags (more reliable than name parsing)
		if part.is_female() != is_female:
			continue

		# Check if this part belongs to the race
		# Body parts are named like "b_n_dark elf_m_chest"
		if part_id.begins_with(prefix):
			result.append(part)

	return result

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

## Generic record lookup - O(1) unified lookup with on-demand C# fallback
## Returns the record or null if not found
## Also returns the record type name via the optional out parameter
## On cache miss (for on-demand types), queries C# and creates record lazily
func get_any_record(id: String, out_type: Array = []) -> ESMRecord:
	var key := id.to_lower()

	# O(1) lookup in unified dictionary (cache hit)
	var entry: Dictionary = _all_records.get(key, {})
	if not entry.is_empty():
		if out_type.size() > 0:
			out_type[0] = entry.get("type", "unknown")
		return entry.get("record") as ESMRecord

	# Cache miss — try on-demand creation from C# (Phase 2)
	if _native_loader != null:
		var rec := _create_record_on_demand(key, id)
		if rec != null:
			var cached_entry: Dictionary = _all_records.get(key, {})
			if out_type.size() > 0:
				out_type[0] = cached_entry.get("type", "unknown")
			return rec

	return null


## On-demand record creation from C# data (Phase 2)
## Called on cache miss in get_any_record() — queries C# once, creates GDScript record, caches it
## Returns the created record or null if not found in C#
@warning_ignore("unsafe_method_access")
func _create_record_on_demand(key: String, original_id: String) -> ESMRecord:
	var info: Variant = _bridge.get_record_info(_native_loader, original_id)
	if info == null or not (info is Array) or (info as Array).size() < 3:
		return null

	var info_arr: Array = info as Array
	var type_name: String = str(info_arr[0])
	var model_path: String = str(info_arr[1])
	var record_id: String = str(info_arr[2])

	var rec: ESMRecord = null
	match type_name:
		"static":
			var srec := StaticRecord.new()
			srec.record_id = record_id
			srec.model = model_path
			statics[key] = srec
			rec = srec
		"activator":
			var arec := ActivatorRecord.new()
			arec.record_id = record_id
			arec.model = model_path
			var data: Dictionary = _bridge.get_typed_record_data(_native_loader, type_name, original_id)
			if not data.is_empty():
				arec.name = str(data.get("name", ""))
				arec.script_id = str(data.get("script_id", ""))
			activators[key] = arec
			rec = arec
		"door":
			var drec := DoorRecord.new()
			drec.record_id = record_id
			drec.model = model_path
			var data: Dictionary = _bridge.get_typed_record_data(_native_loader, type_name, original_id)
			if not data.is_empty():
				drec.name = str(data.get("name", ""))
				drec.script_id = str(data.get("script_id", ""))
				drec.open_sound = str(data.get("open_sound", ""))
				drec.close_sound = str(data.get("close_sound", ""))
			doors[key] = drec
			rec = drec
		"container":
			var crec := ContainerRecord.new()
			crec.record_id = record_id
			crec.model = model_path
			var data: Dictionary = _bridge.get_typed_record_data(_native_loader, type_name, original_id)
			if not data.is_empty():
				crec.name = str(data.get("name", ""))
				crec.script_id = str(data.get("script_id", ""))
				crec.weight = data.get("weight", 0.0) as float
				crec.flags = data.get("flags", 0) as int
			containers[key] = crec
			rec = crec
		"light":
			var lrec := LightRecord.new()
			lrec.record_id = record_id
			lrec.model = model_path
			var data: Dictionary = _bridge.get_typed_record_data(_native_loader, type_name, original_id)
			if not data.is_empty():
				lrec.name = str(data.get("name", ""))
				lrec.script_id = str(data.get("script_id", ""))
				lrec.weight = data.get("weight", 0.0) as float
				lrec.value = data.get("value", 0) as int
				lrec.time = data.get("time", 0) as int
				lrec.radius = data.get("radius", 0) as int
				lrec.color = data.get("color", Color.WHITE) as Color
				lrec.flags = data.get("flags", 0) as int
			lights[key] = lrec
			rec = lrec
		"npc":
			var nrec := NPCRecord.new()
			nrec.record_id = record_id
			nrec.model = model_path
			var data: Dictionary = _bridge.get_typed_record_data(_native_loader, type_name, original_id)
			if not data.is_empty():
				nrec.name = str(data.get("name", ""))
				nrec.script_id = str(data.get("script_id", ""))
				nrec.race_id = str(data.get("race_id", ""))
				nrec.class_id = str(data.get("class_id", ""))
				nrec.faction_id = str(data.get("faction_id", ""))
				nrec.head_id = str(data.get("head_id", ""))
				nrec.hair_id = str(data.get("hair_id", ""))
				nrec.npc_flags = data.get("npc_flags", 0) as int
				nrec.level = data.get("level", 0) as int
				nrec.health = data.get("health", 0) as int
				nrec.mana = data.get("mana", 0) as int
				nrec.fatigue = data.get("fatigue", 0) as int
				nrec.disposition = data.get("disposition", 0) as int
				nrec.reputation = data.get("reputation", 0) as int
				nrec.rank = data.get("rank", 0) as int
				nrec.gold = data.get("gold", 0) as int
			npcs[key] = nrec
			rec = nrec
		"creature":
			var crec := CreatureRecord.new()
			crec.record_id = record_id
			crec.model = model_path
			var data: Dictionary = _bridge.get_typed_record_data(_native_loader, type_name, original_id)
			if not data.is_empty():
				crec.name = str(data.get("name", ""))
				crec.script_id = str(data.get("script_id", ""))
				crec.original_id = str(data.get("original_id", ""))
				crec.creature_flags = data.get("creature_flags", 0) as int
				crec.scale = data.get("scale", 1.0) as float
				crec.creature_type = data.get("creature_type", 0) as int
				crec.level = data.get("level", 0) as int
				crec.health = data.get("health", 0) as int
				crec.mana = data.get("mana", 0) as int
				crec.fatigue = data.get("fatigue", 0) as int
				crec.soul = data.get("soul", 0) as int
				crec.combat = data.get("combat", 0) as int
				crec.magic = data.get("magic", 0) as int
				crec.stealth = data.get("stealth", 0) as int
				crec.gold = data.get("gold", 0) as int
			creatures[key] = crec
			rec = crec
		"weapon":
			var wrec := WeaponRecord.new()
			wrec.record_id = record_id
			wrec.model = model_path
			var data: Dictionary = _bridge.get_typed_record_data(_native_loader, type_name, original_id)
			if not data.is_empty():
				wrec.name = str(data.get("name", ""))
				wrec.script_id = str(data.get("script_id", ""))
				wrec.icon = str(data.get("icon", ""))
				wrec.enchant_id = str(data.get("enchant_id", ""))
				wrec.weight = data.get("weight", 0.0) as float
				wrec.value = data.get("value", 0) as int
				wrec.weapon_type = data.get("weapon_type", 0) as int
				wrec.health = data.get("health", 0) as int
				wrec.speed = data.get("speed", 0.0) as float
				wrec.reach = data.get("reach", 0.0) as float
				wrec.enchant_points = data.get("enchant_points", 0) as int
				wrec.chop_min = data.get("chop_min", 0) as int
				wrec.chop_max = data.get("chop_max", 0) as int
				wrec.slash_min = data.get("slash_min", 0) as int
				wrec.slash_max = data.get("slash_max", 0) as int
				wrec.thrust_min = data.get("thrust_min", 0) as int
				wrec.thrust_max = data.get("thrust_max", 0) as int
				wrec.flags = data.get("flags", 0) as int
			weapons[key] = wrec
			rec = wrec
		"armor":
			var arec := ArmorRecord.new()
			arec.record_id = record_id
			arec.model = model_path
			var data: Dictionary = _bridge.get_typed_record_data(_native_loader, type_name, original_id)
			if not data.is_empty():
				arec.name = str(data.get("name", ""))
				arec.script_id = str(data.get("script_id", ""))
				arec.icon = str(data.get("icon", ""))
				arec.enchant_id = str(data.get("enchant_id", ""))
				arec.armor_type = data.get("armor_type", 0) as int
				arec.weight = data.get("weight", 0.0) as float
				arec.value = data.get("value", 0) as int
				arec.health = data.get("health", 0) as int
				arec.enchant_points = data.get("enchant_points", 0) as int
				arec.armor_rating = data.get("armor_rating", 0) as int
			armors[key] = arec
			rec = arec
		"clothing":
			var clrec := ClothingRecord.new()
			clrec.record_id = record_id
			clrec.model = model_path
			var data: Dictionary = _bridge.get_typed_record_data(_native_loader, type_name, original_id)
			if not data.is_empty():
				clrec.name = str(data.get("name", ""))
				clrec.script_id = str(data.get("script_id", ""))
				clrec.icon = str(data.get("icon", ""))
				clrec.enchant_id = str(data.get("enchant_id", ""))
				clrec.clothing_type = data.get("clothing_type", 0) as int
				clrec.weight = data.get("weight", 0.0) as float
				clrec.value = data.get("value", 0) as int
				clrec.enchant_points = data.get("enchant_points", 0) as int
			clothing[key] = clrec
			rec = clrec

	if rec != null:
		# Priority-aware insertion (same logic as _populate_simple_records)
		var dominated: bool = _all_records.has(key)
		var dominated_priority: int = _get_type_priority(_all_records[key].get("type", "")) if dominated else -1
		var new_priority: int = _get_type_priority(type_name)
		if not dominated or new_priority > dominated_priority:
			_all_records[key] = {"record": rec, "type": type_name}

	return rec


## Eagerly populate ALL typed dictionaries from C# (for prebaking tools only)
## Call this BEFORE iterating ESMManager.statics, .doors, .npcs, etc.
## Not needed for streaming — streaming uses get_any_record() which is on-demand.
@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
func ensure_typed_dicts_populated() -> void:
	if _native_loader == null:
		push_warning("ESMManager: No native loader — typed dicts may be incomplete")
		return
	if _typed_dicts_populated:
		return

	var start_time := Time.get_ticks_msec()
	Log.info("esm", "Eagerly populating typed dicts for prebaking...")

	_populate_simple_records(_native_loader, "Statics", statics, "static",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := StaticRecord.new()
			_copy_model_fields(native_rec, rec)
			return rec)
	_populate_simple_records(_native_loader, "Doors", doors, "door",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := DoorRecord.new()
			_copy_named_model_fields(native_rec, rec)
			rec.open_sound = native_rec.get("OpenSound")
			rec.close_sound = native_rec.get("CloseSound")
			return rec)
	_populate_simple_records(_native_loader, "Activators", activators, "activator",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := ActivatorRecord.new()
			_copy_named_model_fields(native_rec, rec)
			return rec)
	_populate_simple_records(_native_loader, "Containers", containers, "container",
		func(native_rec: RefCounted) -> ESMRecord:
			var rec := ContainerRecord.new()
			_copy_named_model_fields(native_rec, rec)
			rec.weight = native_rec.get("Weight")
			rec.flags = native_rec.get("Flags")
			return rec)
	_populate_simple_records(_native_loader, "Lights", lights, "light",
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
	_populate_simple_records(_native_loader, "NPCs", npcs, "npc",
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
	_populate_simple_records(_native_loader, "Creatures", creatures, "creature",
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
	_populate_simple_records(_native_loader, "Weapons", weapons, "weapon",
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
	_populate_simple_records(_native_loader, "Armors", armors, "armor",
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
	_populate_simple_records(_native_loader, "Clothing", clothing, "clothing",
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

	_typed_dicts_populated = true
	var elapsed := Time.get_ticks_msec() - start_time
	Log.info("esm", "Typed dicts populated in %d ms (statics=%d, doors=%d, npcs=%d, creatures=%d)" % [
		elapsed, statics.size(), doors.size(), npcs.size(), creatures.size()])


## Get priority for a record type (higher = takes precedence in name collisions)
## Statics/activators should win over lights with the same name
static func _get_type_priority(type_name: String) -> int:
	match type_name:
		"static", "activator":
			return 100  # Highest - these are the "real" objects
		"container", "door":
			return 90   # Interactive objects
		"misc", "weapon", "armor", "clothing", "book", "ingredient", "apparatus", "potion":
			return 80   # Items
		"npc", "creature":
			return 70   # Actors
		"light":
			return 10   # Lowest - lights often share names with statics (e.g., "bc mushroom 256")
		_:
			return 50   # Default

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
	var lines: PackedStringArray = [
		"=== ESM Manager Stats ===",
		"Files loaded: %d | Total records: %d | Load time: %.2fs" % [stats.files, stats.total_records, stats.load_time_ms / 1000.0],
		"World: statics=%d cells=%d(%d ext) lands=%d ltex=%d regions=%d pathgrids=%d" % [
			stats.statics, stats.cells, stats.exterior_cells, stats.lands, stats.land_textures, stats.regions, stats.pathgrids],
		"Actors: npcs=%d creatures=%d bodyparts=%d" % [stats.npcs, stats.creatures, stats.body_parts],
		"Items: weapons=%d armors=%d clothing=%d books=%d potions=%d ingredients=%d misc=%d containers=%d lights=%d doors=%d activators=%d" % [
			stats.weapons, stats.armors, stats.clothing, stats.books, stats.potions, stats.ingredients,
			stats.misc_items, stats.containers, stats.lights, stats.doors, stats.activators],
		"Magic: spells=%d enchantments=%d effects=%d" % [stats.spells, stats.enchantments, stats.magic_effects],
		"Character: classes=%d races=%d factions=%d skills=%d birthsigns=%d" % [
			stats.classes, stats.races, stats.factions, stats.skills, stats.birthsigns],
		"Dialogue: topics=%d (with responses=%d)" % [stats.dialogues, stats.dialogue_topics_with_infos],
		"Audio: sounds=%d generators=%d | Scripts: %d | Settings: %d | Globals: %d" % [
			stats.sounds, stats.sound_generators, stats.scripts, stats.game_settings, stats.globals],
		"Leveled: items=%d creatures=%d" % [stats.leveled_items, stats.leveled_creatures],
	]
	if records_by_type.size() > 0:
		var type_parts: PackedStringArray = []
		var sorted_types := records_by_type.keys()
		sorted_types.sort()
		for type_name: String in sorted_types:
			type_parts.append("%s:%d" % [type_name, records_by_type[type_name]])
		lines.append("By type: %s" % " ".join(type_parts))
	Log.info("esm", "\n".join(lines))

#endregion
