## MWQuestAdapter — Morrowind quest/journal translation layer
##
## Reads journal-type DIAL/INFO records from ESM and maps them to QuestManager.
## In MW, quests are entirely dialogue-driven:
##   - Journal-type DIAL records = quest IDs
##   - INFO records under them = journal entries
##   - INFO.disposition = journal index (stage number) for journal-type DIALs
##   - QSTN flag = this INFO starts/adds to a quest
##   - QSTF flag = this INFO finishes a quest
##   - QSTR flag = this INFO restarts a quest
class_name MWQuestAdapter
extends RefCounted

const QuestManagerScript := preload("res://src/core/dialogue/quest_manager.gd")
const TextFormatterScript := preload("res://src/core/ui/text_formatter.gd")

var _quest_manager: RefCounted  # QuestManager


func _init(quest_manager: RefCounted) -> void:
	_quest_manager = quest_manager


## Process a dialogue result for quest updates
## Called after get_response() returns — checks if the INFO has quest flags
## and updates the quest manager accordingly
func process_dialogue_result(info: DialogueInfoRecord, parent_topic_id: String) -> bool:
	if not info.quest_name and not info.quest_finish and not info.quest_restart:
		return false

	# For journal-type dialogue, the parent topic IS the quest ID
	# The journal index is stored in the INFO's disposition field
	var quest_id := parent_topic_id
	var journal_index := info.disposition
	var entry_text := info.response

	# Convert MW markup to plain-ish text for the journal
	var clean_text := TextFormatterScript.to_bbcode(entry_text)

	_quest_manager.update_journal(
		quest_id,
		journal_index,
		clean_text,
		info.quest_finish,
		info.quest_restart
	)

	Log.info("dialogue", "Journal updated: quest='%s' index=%d finish=%s restart=%s" % [
		quest_id, journal_index, info.quest_finish, info.quest_restart
	])

	return true


## Pre-load all journal entries from ESM into a lookup table
## Returns a dictionary: quest_id -> Array[{index, text, finishes, restarts}]
## Useful for building a complete journal view without running the dialogue filter
static func get_all_journal_entries() -> Dictionary:
	var result: Dictionary = {}

	for dial_id: String in ESMManager.dialogues:
		var dial: DialogueRecord = ESMManager.dialogues[dial_id]
		if not dial.is_journal():
			continue

		var entries: Array = []
		var infos: Array = ESMManager.get_dialogue_infos(dial_id)

		for info: DialogueInfoRecord in infos:
			if info.is_deleted:
				continue
			if info.response.is_empty():
				continue

			entries.append({
				"index": info.disposition,  # Journal index = disposition for journal INFOs
				"text": info.response,
				"quest_name": info.quest_name,
				"quest_finish": info.quest_finish,
				"quest_restart": info.quest_restart,
				"record_id": info.record_id,
			})

		if not entries.is_empty():
			# Sort by index
			entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return a["index"] < b["index"])
			result[dial_id] = entries

	return result


## Dump journal data for diagnostics — logs the first few journal entries
## to verify the disposition-as-index mapping
static func dump_journal_sample(max_quests: int = 5) -> void:
	var all_journals := get_all_journal_entries()
	Log.info("dialogue", "=== JOURNAL DUMP: %d total journal topics ===" % all_journals.size())

	var count := 0
	for quest_id: String in all_journals:
		if count >= max_quests:
			break
		var entries: Array = all_journals[quest_id]
		Log.info("dialogue", "  Quest: '%s' (%d entries)" % [quest_id, entries.size()])
		for entry: Dictionary in entries:
			var text_preview: String = entry["text"].substr(0, 60).replace("\n", " ")
			var flags := ""
			if entry["quest_name"]: flags += " [QSTN]"
			if entry["quest_finish"]: flags += " [QSTF]"
			if entry["quest_restart"]: flags += " [QSTR]"
			Log.info("dialogue", "    [%d]%s %s..." % [entry["index"], flags, text_preview])
		count += 1
