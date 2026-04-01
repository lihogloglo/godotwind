@tool
extends Button
class_name AccordionButton

#var downcaret : CompressedTexture2D = preload("res://addons/SunshineClouds2/Dock/Icons/caret-down-solid.svg")
#var upcaret : CompressedTexture2D = preload("res://addons/SunshineClouds2/Dock/Icons/caret-down-solid.svg")

var curvisible : bool = false

func _enter_tree() -> void:
	icon = ResourceLoader.load("res://addons/SunshineClouds2/Dock/Icons/caret-down-solid.svg")
	expand_icon = true
	icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if (!pressed.is_connected(ButtonPressed.bind())):
		pressed.connect(ButtonPressed.bind())

func ButtonPressed():
	curvisible = !curvisible
	_handleVisibility()

func Open():
	curvisible = true
	_handleVisibility()

func Close():
	curvisible = false
	_handleVisibility()

func _handleVisibility():
	if (!curvisible):
		icon = ResourceLoader.load("res://addons/SunshineClouds2/Dock/Icons/caret-down-solid.svg")
	else:
		icon = ResourceLoader.load("res://addons/SunshineClouds2/Dock/Icons/caret-up-solid.svg")
	
	for child in get_parent().get_children():
		if (child != self and child is Control):
			child.visible = curvisible
