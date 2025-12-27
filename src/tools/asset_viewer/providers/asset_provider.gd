## AssetProvider - Base class for asset viewer providers
##
## Extend this class to add new asset types to the unified viewer.
## Each provider handles loading, browsing, and displaying one type of asset.
@warning_ignore("untyped_declaration")
class_name AssetProvider
extends RefCounted

signal loading_started
signal loading_progress(current: int, total: int, message: String)
signal loading_completed
signal loading_failed(error: String)
signal item_loaded(node: Node3D, info: Dictionary)
signal log_message(text: String)

# Provider identification
var provider_name: String = "Base Provider"
var provider_icon: Texture2D = null


## Initialize the provider (load archives, parse data, etc.)
## Override in subclass
func initialize() -> Error:
	return OK


## Check if provider is ready to use
## Override in subclass
func is_ready() -> bool:
	return false


## Get available categories for filtering
## Override in subclass
func get_categories() -> Array[String]:
	return []


## Get all browsable items
## Returns Array of {id: String, name: String, category: String, tooltip: String, metadata: Variant}
## Override in subclass
func get_items() -> Array[Dictionary]:
	return []


## Load and return a 3D node for the given item
## Override in subclass
func load_item(item: Dictionary) -> Node3D:
	return null


## Get info text (BBCode) for the given item
## Override in subclass
func get_info_text(item: Dictionary) -> String:
	return "[b]No info available[/b]"


## Get custom tabs for this provider
## Returns Array of {name: String, build_func: Callable}
## The build_func receives (container: Control, item: Dictionary) and should populate the container
## Override in subclass
func get_custom_tabs() -> Array[Dictionary]:
	return []


## Called when an item is selected (before loading)
## Override in subclass for pre-load actions
func on_item_selected(_item: Dictionary) -> void:
	pass


## Called after an item is loaded
## Override in subclass for post-load actions
func on_item_loaded(_item: Dictionary, _node: Node3D) -> void:
	pass


## Clean up resources
## Override in subclass
func cleanup() -> void:
	pass


## Emit a log message
func _log(text: String) -> void:
	log_message.emit(text)


## Emit loading progress
func _progress(current: int, total: int, message: String = "") -> void:
	loading_progress.emit(current, total, message)
