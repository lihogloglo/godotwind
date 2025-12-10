## ESM Manager - Global autoload for managing ESM/ESP files
## Handles loading, storing, and querying game data from Morrowind files
## Note: No class_name here - this is an autoload singleton accessed via "ESMManager"
extends Node

# Signals
signal loading_started(file_path: String)
signal loading_progress(file_path: String, progress: float)
signal loading_completed(file_path: String, record_count: int)
signal loading_failed(file_path: String, error: String)

#region Record stores - keyed by record ID (lowercase for case-insensitive lookup)

# World/Environment
var statics: Dictionary = {}           # StaticRecord
var cells: Dictionary = {}             # CellRecord
var lands: Dictionary = {}             # LandRecord
var land_textures: Dictionary = {}     # LandTextureRecord
var regions: Dictionary = {}           # RegionRecord
var pathgrids: Dictionary = {}         # PathgridRecord

# Actors
var npcs: Dictionary = {}              # NPCRecord
var creatures: Dictionary = {}         # CreatureRecord
var body_parts: Dictionary = {}        # BodyPartRecord

# Items
var weapons: Dictionary = {}           # WeaponRecord
var armors: Dictionary = {}            # ArmorRecord
var clothing: Dictionary = {}          # ClothingRecord
var books: Dictionary = {}             # BookRecord
var potions: Dictionary = {}           # PotionRecord
var ingredients: Dictionary = {}       # IngredientRecord
var misc_items: Dictionary = {}        # MiscRecord
var containers: Dictionary = {}        # ContainerRecord
var lights: Dictionary = {}            # LightRecord
var doors: Dictionary = {}             # DoorRecord
var activators: Dictionary = {}        # ActivatorRecord
var apparatus: Dictionary = {}         # ApparatusRecord
var lockpicks: Dictionary = {}         # LockpickRecord
var probes: Dictionary = {}            # ProbeRecord
var repair_items: Dictionary = {}      # RepairRecord

# Magic
var spells: Dictionary = {}            # SpellRecord
var enchantments: Dictionary = {}      # EnchantmentRecord
var magic_effects: Dictionary = {}     # MagicEffectRecord

# Character Definition
var classes: Dictionary = {}           # ClassRecord
var races: Dictionary = {}             # RaceRecord
var factions: Dictionary = {}          # FactionRecord
var skills: Dictionary = {}            # SkillRecord
var birthsigns: Dictionary = {}        # BirthsignRecord

# Dialogue
var dialogues: Dictionary = {}         # DialogueRecord
var dialogue_infos: Dictionary = {}    # DialogueInfoRecord (grouped by topic)

# Audio
var sounds: Dictionary = {}            # SoundRecord
var sound_generators: Dictionary = {}  # SoundGenRecord

# Scripts & Settings
var scripts: Dictionary = {}           # ScriptRecord
var game_settings: Dictionary = {}     # GameSettingRecord
var globals: Dictionary = {}           # GlobalRecord
var start_scripts: Array[String] = []  # StartScriptRecord IDs

# Leveled Lists
var leveled_items: Dictionary = {}     # LeveledItemRecord
var leveled_creatures: Dictionary = {} # LeveledCreatureRecord

#endregion

# Exterior cells indexed by grid coordinates
var exterior_cells: Dictionary = {}  # "x,y" -> CellRecord

# Loaded files
var loaded_files: Array[String] = []

# Statistics
var total_records_loaded: int = 0
var records_by_type: Dictionary = {}
var load_time_ms: float = 0.0

# Current dialogue topic being loaded (INFO records follow DIAL)
var _current_dialogue_topic: String = ""

## Load an ESM or ESP file
func load_file(path: String) -> Error:
	loading_started.emit(path)
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
			var type_name := ESMDefs.four_cc_to_string(rec_name)
			skipped_types[type_name] = skipped_types.get(type_name, 0) + 1

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
		for type_name in sorted_skipped:
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

## Store a record in the appropriate dictionary
func _store_record(record: ESMRecord, rec_type: int) -> void:
	if record.is_deleted:
		_remove_record(record, rec_type)
		return

	var key := record.record_id.to_lower()

	# World/Environment
	if record is StaticRecord:
		statics[key] = record
	elif record is CellRecord:
		cells[key] = record
		if record.is_exterior():
			var grid_key := "%d,%d" % [record.grid_x, record.grid_y]
			exterior_cells[grid_key] = record
	elif record is LandRecord:
		lands[record.record_id] = record  # Keep original "x,y" format
	elif record is LandTextureRecord:
		land_textures[key] = record
	elif record is RegionRecord:
		regions[key] = record
	elif record is PathgridRecord:
		pathgrids[record.record_id] = record

	# Actors
	elif record is NPCRecord:
		npcs[key] = record
	elif record is CreatureRecord:
		creatures[key] = record
	elif record is BodyPartRecord:
		body_parts[key] = record

	# Items
	elif record is WeaponRecord:
		weapons[key] = record
	elif record is ArmorRecord:
		armors[key] = record
	elif record is ClothingRecord:
		clothing[key] = record
	elif record is BookRecord:
		books[key] = record
	elif record is PotionRecord:
		potions[key] = record
	elif record is IngredientRecord:
		ingredients[key] = record
	elif record is MiscRecord:
		misc_items[key] = record
	elif record is ContainerRecord:
		containers[key] = record
	elif record is LightRecord:
		lights[key] = record
	elif record is DoorRecord:
		doors[key] = record
	elif record is ActivatorRecord:
		activators[key] = record
	elif record is ApparatusRecord:
		apparatus[key] = record
	elif record is LockpickRecord:
		lockpicks[key] = record
	elif record is ProbeRecord:
		probes[key] = record
	elif record is RepairRecord:
		repair_items[key] = record

	# Magic
	elif record is SpellRecord:
		spells[key] = record
	elif record is EnchantmentRecord:
		enchantments[key] = record
	elif record is MagicEffectRecord:
		magic_effects[key] = record

	# Character Definition
	elif record is ClassRecord:
		classes[key] = record
	elif record is RaceRecord:
		races[key] = record
	elif record is FactionRecord:
		factions[key] = record
	elif record is SkillRecord:
		skills[key] = record
	elif record is BirthsignRecord:
		birthsigns[key] = record

	# Dialogue
	elif record is DialogueRecord:
		dialogues[key] = record
	elif record is DialogueInfoRecord:
		# Group INFO by topic
		var topic_key := _current_dialogue_topic.to_lower()
		if not dialogue_infos.has(topic_key):
			dialogue_infos[topic_key] = []
		dialogue_infos[topic_key].append(record)

	# Audio
	elif record is SoundRecord:
		sounds[key] = record
	elif record is SoundGenRecord:
		sound_generators[key] = record

	# Scripts & Settings
	elif record is ScriptRecord:
		scripts[key] = record
	elif record is GameSettingRecord:
		game_settings[key] = record
	elif record is GlobalRecord:
		globals[key] = record
	elif record is StartScriptRecord:
		if not record.record_id in start_scripts:
			start_scripts.append(record.record_id)

	# Leveled Lists
	elif record is LeveledItemRecord:
		leveled_items[key] = record
	elif record is LeveledCreatureRecord:
		leveled_creatures[key] = record

## Remove a deleted record
func _remove_record(record: ESMRecord, rec_type: int) -> void:
	var key := record.record_id.to_lower()

	match rec_type:
		ESMDefs.RecordType.REC_STAT: statics.erase(key)
		ESMDefs.RecordType.REC_CELL:
			cells.erase(key)
			if record is CellRecord and record.is_exterior():
				var grid_key := "%d,%d" % [record.grid_x, record.grid_y]
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

#region Query functions

# World
func get_static(id: String) -> StaticRecord:
	return statics.get(id.to_lower())
func get_cell(name: String) -> CellRecord:
	return cells.get(name.to_lower())
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
func get_game_setting(name: String) -> GameSettingRecord:
	return game_settings.get(name.to_lower())
func get_global(name: String) -> GlobalRecord:
	return globals.get(name.to_lower())
func get_start_scripts() -> Array[String]:
	return start_scripts

# Leveled Lists
func get_leveled_item(id: String) -> LeveledItemRecord:
	return leveled_items.get(id.to_lower())
func get_leveled_creature(id: String) -> LeveledCreatureRecord:
	return leveled_creatures.get(id.to_lower())

## Generic record lookup - tries all stores to find any record by ID
## Returns the record or null if not found
## Also returns the record type name via the optional out parameter
func get_any_record(id: String, out_type: Array = []) -> ESMRecord:
	var key := id.to_lower()
	var record: ESMRecord = null

	# Check each store in order of likelihood for cell references
	# Statics are most common in cells
	record = statics.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "static"
		return record

	record = doors.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "door"
		return record

	record = containers.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "container"
		return record

	record = lights.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "light"
		return record

	record = activators.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "activator"
		return record

	record = npcs.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "npc"
		return record

	record = creatures.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "creature"
		return record

	record = misc_items.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "misc"
		return record

	record = weapons.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "weapon"
		return record

	record = armors.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "armor"
		return record

	record = clothing.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "clothing"
		return record

	record = books.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "book"
		return record

	record = potions.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "potion"
		return record

	record = ingredients.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "ingredient"
		return record

	record = apparatus.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "apparatus"
		return record

	record = lockpicks.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "lockpick"
		return record

	record = probes.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "probe"
		return record

	record = repair_items.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "repair"
		return record

	record = leveled_items.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "leveled_item"
		return record

	record = leveled_creatures.get(key)
	if record:
		if out_type.size() > 0: out_type[0] = "leveled_creature"
		return record

	return null

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
		for type_name in sorted_types:
			print("  %s: %d" % [type_name, records_by_type[type_name]])

#endregion
