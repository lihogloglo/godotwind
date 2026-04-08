## DialogueContext — Player/world state for dialogue evaluation
##
## Generic framework class. Holds the cross-RPG player and world state that
## any dialogue system needs to filter and present conversations.
##
## Game-specific fields (Morrowind's 8-attribute / 27-skill arrays, disease/
## vampire/werewolf flags, clothing-value disposition modifier, etc.) belong
## in a subclass under the game's adapter directory — e.g.
## `src/core/dialogue/morrowind/mw_dialogue_context.gd`. Framework code only
## ever sees this base class; adapters downcast at their entry points.
class_name DialogueContext
extends RefCounted

# Player identity
var pc_race: String = ""
var pc_class: String = ""
var pc_gender: int = 0       # 0=male, 1=female
var pc_level: int = 1
var pc_faction: String = ""  # Current primary faction
var pc_rank: int = 0         # Rank in primary faction

# Player resources / standing — every RPG has some form of these
var pc_reputation: int = 0
var pc_crime_level: int = 0
var pc_health: int = 100
var pc_health_percent: int = 100
var pc_magicka: int = 100
var pc_fatigue: int = 100

# NPC interaction state (set per conversation)
var detected: bool = true        # NPC is aware of the player (true = normal conversation)
var attacked: bool = false       # NPC has been attacked by player
var talked_to_pc: bool = false   # NPC has spoken to player before
var alarmed: bool = false        # NPC is alarmed

# World state
var current_cell: String = ""
var weather: int = 0             # 0=clear, 1=cloudy, etc.

# Dialogue state
var known_topics: Dictionary = {}    # topic_id (lowercase) -> bool
var journal_indices: Dictionary = {}  # quest_id (lowercase) -> int (highest journal index)
var choice: int = -1             # Current dialogue choice index (-1 = not in a choice)

# Per-NPC state
var disposition: int = 50    # Current NPC disposition toward player (0-100)

# Global variables (game-specific, string -> float)
var globals: Dictionary = {}


## Check if player knows a topic
func knows_topic(topic_id: String) -> bool:
	return known_topics.has(topic_id.to_lower())


## Learn a new topic
func add_topic(topic_id: String) -> void:
	known_topics[topic_id.to_lower()] = true


## Get journal index for a quest (0 if not started)
func get_journal_index(quest_id: String) -> int:
	return journal_indices.get(quest_id.to_lower(), 0)


## Set journal index for a quest
func set_journal_index(quest_id: String, index: int) -> void:
	journal_indices[quest_id.to_lower()] = index


## Get a global variable value (0.0 if not set)
func get_global(name: String) -> float:
	return globals.get(name.to_lower(), 0.0)


## Set a global variable
func set_global(name: String, value: float) -> void:
	globals[name.to_lower()] = value
