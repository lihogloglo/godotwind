## MWDialogueContext — Morrowind-specific dialogue context
##
## Extends the generic DialogueContext with fields that only make sense for
## Morrowind's dialogue system:
##   - Fixed-size 8-attribute / 27-skill arrays (MW's stat schema)
##   - Disease / vampirism / werewolf status flags
##   - pc_clothing_value — running total used by MW's derived-disposition formula
##
## Framework code (DialogueUI, DialogueProvider base, QuestManager) only ever
## sees the base `DialogueContext`. MW-specific dialogue components
## (MWDialogueProvider, MWDialogueFilter, MWDialogueFunctions) downcast to
## this class at their entry points via `context as MWDialogueContext`.
##
## A different game (Oblivion, Witcher, etc.) would ship its own context
## subclass alongside its own provider/filter/functions — no touch to the
## framework layer.
class_name MWDialogueContext
extends DialogueContext

# Player attributes (MW's 8, indexed 0-7: Str, Int, Wil, Agi, Spd, End, Per, Lck)
var pc_attributes: Array[int] = [50, 50, 50, 50, 50, 50, 50, 50]

# Player skills (MW's 27, indexed 0-26: Block through HandToHand)
var pc_skills: Array[int] = []

# Sum of equipped clothing/armor base values — feeds MW's disposition formula
var pc_clothing_value: int = 0

# MW-specific player status flags
var pc_expelled: bool = false      # Expelled from primary faction
var pc_common_disease: bool = false
var pc_blight_disease: bool = false
var pc_corprus: bool = false
var pc_vampire: bool = false
var pc_werewolf: bool = false
var pc_werewolf_kills: int = 0


## Get a player attribute by index (0-7). Out-of-range indices return 0.
func get_attribute(index: int) -> int:
	if index >= 0 and index < pc_attributes.size():
		return pc_attributes[index]
	return 0


## Get a player skill by index (0-26). Out-of-range indices return 0.
func get_skill(index: int) -> int:
	if index >= 0 and index < pc_skills.size():
		return pc_skills[index]
	return 0
