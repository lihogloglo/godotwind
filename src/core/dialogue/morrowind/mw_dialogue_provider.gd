## MWDialogueProvider — Morrowind translation layer for the dialogue framework
##
## Extends DialogueProvider to provide Morrowind-specific dialogue.
## Wraps MWDialogueFilter to query ESM dialogue records.
## This is the ONLY class the framework/UI should call for MW dialogue.
## All MW-specific logic (SCVR, 4-step filter, greeting 0-9) is encapsulated here.
##
## Accepts speaker_id (string) and does internal NPCRecord lookup.
class_name MWDialogueProvider
extends DialogueProvider

const MWDialogueFilterScript := preload("res://src/core/dialogue/morrowind/mw_dialogue_filter.gd")
const DialogueDataScript := preload("res://src/core/dialogue/dialogue_data.gd")
const DialogueContextScript := preload("res://src/core/dialogue/dialogue_context.gd")
const TextFormatterScript := preload("res://src/core/ui/text_formatter.gd")

## Regex for stripping HTML tags from response text
static var _tag_regex: RegEx = _compile_tag_regex()

## All topic DIAL record IDs (lowercase), cached on first use
var _topic_ids: Array[String] = []
var _topics_cached: bool = false


static func _compile_tag_regex() -> RegEx:
	var r := RegEx.new()
	r.compile("<[^>]*>")
	return r


## Resolve a speaker_id to an NPCRecord
## Returns null if not found
func _resolve_npc(speaker_id: String) -> NPCRecord:
	var key := speaker_id.to_lower()
	if ESMManager.npcs.has(key):
		return ESMManager.npcs[key] as NPCRecord
	# Try original case
	if ESMManager.npcs.has(speaker_id):
		return ESMManager.npcs[speaker_id] as NPCRecord
	Log.warn("dialogue", "NPC not found for speaker_id: %s" % speaker_id)
	return null


## Get an NPC's greeting
## Searches Greeting 0 through Greeting 9 (MW-specific ordering)
## Returns DialogueData.DialogueLine or null
func get_greeting(speaker_id: String, context: DialogueContext) -> RefCounted:
	var npc := _resolve_npc(speaker_id)
	if npc == null:
		return null

	for i in range(10):
		var topic_id := "greeting %d" % i
		var info: DialogueInfoRecord = MWDialogueFilterScript.search(topic_id, npc, context)
		if info != null and not info.response.is_empty():
			var line: RefCounted = DialogueDataScript.DialogueLine.new()
			line.text = info.response
			line.speaker_name = npc.name
			line.source_id = info.record_id
			return line

	return null


## Get topics available for this NPC that the player knows
## Pre-filters by actor fields for performance (avoids 118k+ filter evals)
## Returns Array of DialogueData.TopicEntry
func get_available_topics(speaker_id: String, context: DialogueContext) -> Array:
	var npc := _resolve_npc(speaker_id)
	if npc == null:
		return []

	_ensure_topic_cache()

	var results: Array = []

	for topic_id in _topic_ids:
		# Skip topics the player doesn't know
		if not context.knows_topic(topic_id):
			continue

		# Quick pre-filter: could any INFO match this NPC?
		if not MWDialogueFilterScript.could_match_npc(topic_id, npc):
			continue

		# Full filter: find the matching INFO
		var info: DialogueInfoRecord = MWDialogueFilterScript.search(topic_id, npc, context)
		if info != null and not info.response.is_empty():
			var entry: RefCounted = DialogueDataScript.TopicEntry.new()
			entry.topic_id = topic_id
			# Display name = original DIAL record_id (preserves case)
			var dial: DialogueRecord = ESMManager.get_dialogue(topic_id)
			entry.display_name = dial.record_id if dial != null else topic_id
			results.append(entry)

	return results


## Get response for a specific topic from this NPC
## Returns DialogueData.DialogueResult
func get_response(topic_id: String, speaker_id: String, context: DialogueContext) -> RefCounted:
	var npc := _resolve_npc(speaker_id)
	if npc == null:
		return DialogueDataScript.DialogueResult.new()

	var result: RefCounted = DialogueDataScript.DialogueResult.new()

	var info: DialogueInfoRecord = MWDialogueFilterScript.search(topic_id, npc, context)
	if info == null:
		return result

	var line: RefCounted = DialogueDataScript.DialogueLine.new()
	line.text = info.response
	line.speaker_name = npc.name
	line.source_id = info.record_id
	result.line = line

	# Discover topics mentioned in the response text
	result.topics_discovered = discover_topics_in_text(info.response)

	# Quest flags
	result.quest_updated = info.quest_name or info.quest_finish or info.quest_restart

	return result


## Get the goodbye line for this speaker
## Searches the "Goodbye" topic for a matching INFO
func get_goodbye(speaker_id: String, context: DialogueContext) -> RefCounted:
	var npc := _resolve_npc(speaker_id)
	if npc == null:
		return null

	var info: DialogueInfoRecord = MWDialogueFilterScript.search("goodbye", npc, context)
	if info != null and not info.response.is_empty():
		var line: RefCounted = DialogueDataScript.DialogueLine.new()
		line.text = info.response
		line.speaker_name = npc.name
		line.source_id = info.record_id
		return line

	return null


## Get the display name for a speaker
func get_speaker_name(speaker_id: String) -> String:
	var npc := _resolve_npc(speaker_id)
	if npc != null:
		return npc.name
	return speaker_id


## Highlight topic keywords in text as clickable [url] BBCode links
## Takes raw MW markup text, returns BBCode with topics wrapped in [url=topic_id]
## Preserves original text casing, links use topic_id as the URL metadata
func highlight_topics_in_text(text: String, known: Dictionary) -> String:
	_ensure_topic_cache()

	# First convert MW markup to BBCode
	var bbcode := TextFormatterScript.to_bbcode(text)

	# Build a lowercase version for matching, track character mapping
	var bbcode_lower := bbcode.to_lower()

	# Find all topic matches with positions (longest first to avoid partial overlaps)
	var matches: Array[Dictionary] = []  # [{pos, len, topic_id}]
	for topic_id in _topic_ids:
		if topic_id.length() < 2:
			continue
		# Only highlight topics the player knows (or just discovered)
		if not known.has(topic_id):
			continue
		# Search in the BBCode text, but skip content inside [...] tags
		var search_from := 0
		while search_from < bbcode_lower.length():
			var pos := bbcode_lower.find(topic_id, search_from)
			if pos < 0:
				break
			# Skip if inside a BBCode tag [...]
			if _is_inside_bbcode_tag(bbcode, pos):
				search_from = pos + 1
				continue
			# Word boundary check
			if _is_word_boundary(bbcode_lower, pos, topic_id.length()):
				matches.append({"pos": pos, "len": topic_id.length(), "topic_id": topic_id})
				search_from = pos + topic_id.length()
			else:
				search_from = pos + 1

	if matches.is_empty():
		return bbcode

	# Sort by position, then by length descending (longest wins at same position)
	matches.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["pos"] != b["pos"]:
			return a["pos"] < b["pos"]
		return a["len"] > b["len"])
	var filtered: Array[Dictionary] = []
	var last_end := -1
	for m: Dictionary in matches:
		if m["pos"] >= last_end:
			filtered.append(m)
			last_end = m["pos"] + m["len"]

	# Build result string with [url] tags inserted (reverse order to preserve positions)
	var result := bbcode
	for i in range(filtered.size() - 1, -1, -1):
		var m: Dictionary = filtered[i]
		var p: int = m["pos"]
		var l: int = m["len"]
		var tid: String = m["topic_id"]
		var original_word := result.substr(p, l)
		var linked := "[url=%s][color=#4466aa]%s[/color][/url]" % [tid, original_word]
		result = result.substr(0, p) + linked + result.substr(p + l)

	return result


## Check if a position is inside a BBCode tag [...]
static func _is_inside_bbcode_tag(text: String, pos: int) -> bool:
	# Look backwards for [ without a closing ]
	var i := pos - 1
	while i >= 0:
		if text[i] == "]":
			return false  # Found closing bracket first — not inside
		if text[i] == "[":
			return true   # Found opening bracket — inside a tag
		i -= 1
	return false


## Scan text for known topic keywords (MW's topic cross-referencing system)
## Returns array of topic IDs found in the text
## Uses word boundary matching to avoid false positives ("he" matching "the")
func discover_topics_in_text(text: String) -> Array[String]:
	_ensure_topic_cache()

	var found: Array[String] = []
	var text_lower := text.to_lower()

	# Strip HTML tags for cleaner matching
	var clean := _tag_regex.sub(text_lower, "", true)

	for topic_id in _topic_ids:
		if topic_id.length() < 2:
			continue
		var pos := clean.find(topic_id)
		if pos < 0:
			continue
		# Word boundary check: character before and after must be non-alphanumeric
		if _is_word_boundary(clean, pos, topic_id.length()):
			found.append(topic_id)

	return found


## Check if a match at pos with given length has word boundaries on both sides
static func _is_word_boundary(text: String, pos: int, match_len: int) -> bool:
	# Check character before match
	if pos > 0:
		var before := text.unicode_at(pos - 1)
		if _is_word_char(before):
			return false
	# Check character after match
	var after_pos := pos + match_len
	if after_pos < text.length():
		var after := text.unicode_at(after_pos)
		if _is_word_char(after):
			return false
	return true


## Is this a word character (letter, digit, underscore, apostrophe)?
static func _is_word_char(c: int) -> bool:
	return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 39


## Build/cache the list of all topic DIAL IDs
func _ensure_topic_cache() -> void:
	if _topics_cached:
		return

	_topic_ids.clear()
	for dial_id: String in ESMManager.dialogues:
		var dial: DialogueRecord = ESMManager.dialogues[dial_id]
		if dial.is_topic():
			_topic_ids.append(dial_id)

	# Sort by length descending — longer topics match first (avoids "little secret" matching "little" only)
	_topic_ids.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())

	_topics_cached = true
	Log.debug("dialogue", "Cached %d topic IDs for dialogue matching" % _topic_ids.size())
