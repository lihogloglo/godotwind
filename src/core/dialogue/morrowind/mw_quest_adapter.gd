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


## Signal handler for DialogueUI.response_selected.
## Reads the MW-specific metadata populated by MWDialogueProvider.get_response()
## and advances the journal without having to re-run the filter.
## Returns true if the journal was actually updated.
##
## Connect via:
##   dialogue_ui.response_selected.connect(quest_adapter.on_response_selected)
func on_response_selected(_topic_id: String, response: DialogueProvider.Response) -> bool:
	if not response.ok() or response.line == null:
		return false
	if not response.quest_updated:
		return false

	var meta := response.metadata
	if meta.is_empty():
		Log.warn("dialogue", "on_response_selected: response has quest_updated=true but empty metadata")
		return false

	var quest_id: String = meta.get("parent_topic", "")
	if quest_id.is_empty():
		Log.warn("dialogue", "on_response_selected: metadata missing parent_topic")
		return false

	var line: RefCounted = response.line
	var clean_text := TextFormatterScript.to_bbcode(line.text)

	_quest_manager.update_journal(
		quest_id,
		meta.get("journal_index", 0),
		clean_text,
		meta.get("quest_finish", false),
		meta.get("quest_restart", false)
	)

	Log.info("dialogue", "Journal updated via signal: quest='%s' index=%d finish=%s restart=%s" % [
		quest_id,
		meta.get("journal_index", 0),
		meta.get("quest_finish", false),
		meta.get("quest_restart", false),
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
