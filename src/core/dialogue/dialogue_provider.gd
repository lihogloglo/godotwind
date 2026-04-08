## DialogueProvider — Base class for game-specific dialogue providers
##
## Defines the contract that the framework UI uses to get dialogue data.
## Game-specific implementations (e.g. MWDialogueProvider) extend this class.
## The UI never needs to know about game-specific record types — it only
## passes speaker_id strings and receives generic DialogueData types wrapped
## in a Response envelope.
##
## ## Response envelope
##
## All four query methods (get_greeting, get_available_topics, get_response,
## get_goodbye) return a Response with:
##   - error: Error enum — OK, SPEAKER_NOT_FOUND, NO_INFO_MATCH
##   - line: DialogueLine or null (filled by single-line queries)
##   - topics: Array (filled by get_available_topics)
##   - topics_discovered: Array[String] (filled by get_response)
##   - quest_updated: bool (filled by get_response)
##   - disposition_change: int (filled by get_response)
##
## SPEAKER_NOT_FOUND = bug, speaker_id does not exist in the provider's world.
## NO_INFO_MATCH = valid state, speaker exists but no dialogue entry passed the
## filter for this query (e.g. NPC has no greeting matching current context).
## Callers should distinguish: SPEAKER_NOT_FOUND = log+abort,
## NO_INFO_MATCH = show fallback UI.
class_name DialogueProvider
extends RefCounted


## Query result classification
enum Error {
	OK,                  # Query succeeded, Response.line (or .topics) is populated
	SPEAKER_NOT_FOUND,   # speaker_id does not exist in the provider's database
	NO_INFO_MATCH,       # speaker exists but no dialogue entry matched the filter
}


## Envelope returned by all provider query methods.
## Which fields are populated depends on which method was called:
##
## | Method                  | line | topics | topics_discovered | quest_updated | disposition_change | metadata |
## |-------------------------|------|--------|-------------------|---------------|--------------------|----------|
## | get_greeting            | yes  |        |                   |               |                    | provider |
## | get_available_topics    |      | yes    |                   |               |                    |          |
## | get_response            | yes  |        | yes               | yes           | yes                | provider |
## | get_goodbye             | yes  |        |                   |               |                    | provider |
##
## Do NOT read fields left blank by the method you called — they hold zero-value
## defaults and will mislead you. Read only the columns marked "yes" above.
##
## ## metadata dictionary
##
## Reserved for provider-specific extras that don't fit the generic envelope.
## Providers are free to populate arbitrary keys; the framework ignores them.
## Game-specific adapters (e.g. quest systems) read the keys they know about.
## Example: MWDialogueProvider.get_response() populates metadata with
## {"info_id": ..., "parent_topic": ..., "journal_index": ..., "quest_finish": ...,
##  "quest_restart": ..., "quest_name_flag": ...} so MWQuestAdapter can advance
## the journal without having to re-run the dialogue filter.
class Response extends RefCounted:
	var error: int = Error.OK                       # DialogueProvider.Error
	var line: RefCounted = null                     # DialogueData.DialogueLine
	var topics: Array = []                          # Array of DialogueData.TopicEntry
	var topics_discovered: Array[String] = []       # Newly found topic IDs in response text
	var quest_updated: bool = false                 # Triggered by QSTN/QSTF/QSTR on the INFO
	var disposition_change: int = 0                 # Provider may report delta for UI feedback
	var metadata: Dictionary = {}                   # Provider-specific extras

	## Convenience: success means error == OK
	func ok() -> bool:
		return error == Error.OK


## Get an NPC's greeting line.
## On success, Response.line is the DialogueLine.
func get_greeting(speaker_id: String, context: DialogueContext) -> Response:
	push_warning("DialogueProvider.get_greeting() not implemented")
	var r := Response.new()
	r.error = Error.NO_INFO_MATCH
	return r


## Get topics available for this speaker that the player knows.
## On success, Response.topics is Array[DialogueData.TopicEntry].
## Empty topic list is NOT an error — returns Response with error=OK and empty topics.
func get_available_topics(speaker_id: String, context: DialogueContext) -> Response:
	push_warning("DialogueProvider.get_available_topics() not implemented")
	var r := Response.new()
	r.error = Error.NO_INFO_MATCH
	return r


## Get response for a specific topic from this speaker.
## On success, Response.line is the DialogueLine and quest_updated/topics_discovered
## are populated from the matched entry.
func get_response(topic_id: String, speaker_id: String, context: DialogueContext) -> Response:
	push_warning("DialogueProvider.get_response() not implemented")
	var r := Response.new()
	r.error = Error.NO_INFO_MATCH
	return r


## Get the goodbye line for this speaker.
## On success, Response.line is the DialogueLine.
func get_goodbye(speaker_id: String, context: DialogueContext) -> Response:
	push_warning("DialogueProvider.get_goodbye() not implemented")
	var r := Response.new()
	r.error = Error.NO_INFO_MATCH
	return r


## Highlight known topic keywords in text as clickable [url] BBCode links.
## Not a query — pure text transform — so it does NOT return a Response.
func highlight_topics_in_text(text: String, known_topics: Dictionary) -> String:
	return text


## Discover topic keywords mentioned in text.
## Not a query — returns Array[String] directly.
func discover_topics_in_text(text: String) -> Array[String]:
	return []


## Get the display name for a speaker (for the UI header).
## Returns the empty string if the speaker is unknown to the provider.
## Callers MUST check for empty and decide how to render missing speakers
## (typically fall back to `speaker_id` with a visible marker so broken
## lookups don't silently masquerade as valid names).
func get_speaker_name(_speaker_id: String) -> String:
	# Base implementation has no speaker database — always unknown.
	return ""
