## QuestManager — Generic quest state tracking
##
## Framework class. Tracks quest progression, journal entries, and state.
## Game-specific adapters (MW, etc.) feed data into this via update_journal().
class_name QuestManager
extends RefCounted


## Quest states
enum QuestState {
	INACTIVE,   # Not yet started
	ACTIVE,     # In progress
	COMPLETED,  # Finished successfully
	FAILED,     # Failed
}


## A single journal entry
class JournalEntry extends RefCounted:
	var quest_id: String = ""
	var index: int = 0          # Stage/index number (higher = later)
	var text: String = ""       # The journal text
	var timestamp: float = 0.0  # When this entry was added (game time or real time)
	var finishes_quest: bool = false
	var restarts_quest: bool = false


## A tracked quest
class Quest extends RefCounted:
	var quest_id: String = ""
	var display_name: String = ""  # Human-readable name (may be empty until discovered)
	var state: int = QuestState.INACTIVE
	var current_index: int = 0     # Highest journal index reached
	var entries: Array = []        # Array of JournalEntry, sorted by index


# Active quests: quest_id (lowercase) -> Quest
var _quests: Dictionary = {}

# Signals
signal quest_started(quest_id: String)
signal quest_updated(quest_id: String, index: int)
signal quest_completed(quest_id: String)
signal quest_restarted(quest_id: String)


## Update journal with a new entry
## Creates the quest if it doesn't exist, advances index, changes state
func update_journal(quest_id: String, index: int, text: String, finishes: bool = false, restarts: bool = false) -> void:
	var key := quest_id.to_lower()
	var quest: Quest

	if _quests.has(key):
		quest = _quests[key]
	else:
		quest = Quest.new()
		quest.quest_id = key
		quest.display_name = quest_id  # Use raw ID as name until we have a better source
		quest.state = QuestState.ACTIVE
		_quests[key] = quest
		quest_started.emit(key)

	# Create journal entry
	var entry := JournalEntry.new()
	entry.quest_id = key
	entry.index = index
	entry.text = text
	entry.timestamp = Time.get_unix_time_from_system()
	entry.finishes_quest = finishes
	entry.restarts_quest = restarts

	# Insert sorted by index
	var inserted := false
	for i in range(quest.entries.size()):
		var existing: JournalEntry = quest.entries[i]
		if existing.index == index:
			# Replace existing entry at same index
			quest.entries[i] = entry
			inserted = true
			break
		elif existing.index > index:
			quest.entries.insert(i, entry)
			inserted = true
			break
	if not inserted:
		quest.entries.append(entry)

	# Update quest state
	if restarts:
		quest.state = QuestState.ACTIVE
		quest.current_index = index
		quest_restarted.emit(key)
	elif finishes:
		quest.state = QuestState.COMPLETED
		quest.current_index = index
		quest_completed.emit(key)
	else:
		if index > quest.current_index:
			quest.current_index = index
		if quest.state == QuestState.INACTIVE:
			quest.state = QuestState.ACTIVE
		quest_updated.emit(key, index)


## Get a quest by ID (null if not tracked)
func get_quest(quest_id: String) -> Quest:
	return _quests.get(quest_id.to_lower())


## Get all active quests
func get_active_quests() -> Array:
	var results: Array = []
	for quest: Quest in _quests.values():
		if quest.state == QuestState.ACTIVE:
			results.append(quest)
	return results


## Get all completed quests
func get_completed_quests() -> Array:
	var results: Array = []
	for quest: Quest in _quests.values():
		if quest.state == QuestState.COMPLETED:
			results.append(quest)
	return results


## Get all quests (any state)
func get_all_quests() -> Array:
	return _quests.values()


## Get the highest journal index for a quest (0 if not started)
func get_journal_index(quest_id: String) -> int:
	var quest := get_quest(quest_id)
	if quest != null:
		return quest.current_index
	return 0
