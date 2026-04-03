## DialogueProvider — Base class for game-specific dialogue providers
##
## Defines the contract that the framework UI uses to get dialogue data.
## Game-specific implementations (e.g. MWDialogueProvider) extend this class.
## The UI never needs to know about game-specific record types — it only
## passes speaker_id strings and receives generic DialogueData types.
class_name DialogueProvider
extends RefCounted


## Get an NPC's greeting line
## Returns DialogueData.DialogueLine or null if no greeting found
func get_greeting(speaker_id: String, context: DialogueContext) -> RefCounted:
	push_warning("DialogueProvider.get_greeting() not implemented")
	return null


## Get topics available for this speaker that the player knows
## Returns Array of DialogueData.TopicEntry
func get_available_topics(speaker_id: String, context: DialogueContext) -> Array:
	push_warning("DialogueProvider.get_available_topics() not implemented")
	return []


## Get response for a specific topic from this speaker
## Returns DialogueData.DialogueResult
func get_response(topic_id: String, speaker_id: String, context: DialogueContext) -> RefCounted:
	push_warning("DialogueProvider.get_response() not implemented")
	return null


## Get the goodbye line for this speaker
## Returns DialogueData.DialogueLine or null
func get_goodbye(speaker_id: String, context: DialogueContext) -> RefCounted:
	push_warning("DialogueProvider.get_goodbye() not implemented")
	return null


## Highlight known topic keywords in text as clickable [url] BBCode links
## Returns BBCode string with topics wrapped in [url=topic_id]
func highlight_topics_in_text(text: String, known_topics: Dictionary) -> String:
	# Default: no highlighting
	return text


## Discover topic keywords mentioned in text
## Returns array of topic IDs found
func discover_topics_in_text(text: String) -> Array[String]:
	return []


## Get the display name for a speaker (for the UI header)
func get_speaker_name(speaker_id: String) -> String:
	return speaker_id
