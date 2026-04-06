## DialogueData — Generic data structures for dialogue systems
##
## Framework-level types. Game-specific providers return these.
## UI and game logic consume these without knowing the data source.
class_name DialogueData
extends RefCounted


## A single line of dialogue (greeting or response)
class DialogueLine extends RefCounted:
	var text: String = ""           # The response/greeting text
	var speaker_name: String = ""   # Who said it
	var source_id: String = ""      # Provider-specific ID for tracking


## A topic that can be discussed
class TopicEntry extends RefCounted:
	var topic_id: String = ""       # Unique identifier (lowercase)
	var display_name: String = ""   # How to show it in the UI
