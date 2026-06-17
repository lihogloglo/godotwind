class_name WorldSource
extends RefCounted

## Root source contract for dependency-injected world data.
##
## Boot/sample code owns one WorldSource and injects it into runtime systems.
## Core systems consume these source-neutral providers instead of reaching for
## parser/autoload globals.

var source_id: StringName = &""
var display_name: String = "World Source"
var coordinate_mapper: RefCounted = null
var object_source: RefCounted = null
var object_spawn_adapter: RefCounted = null
var terrain_provider: RefCounted = null
var asset_provider: RefCounted = null
var character_source: RefCounted = null
var weather_provider: RefCounted = null
var dialogue_provider: RefCounted = null
var water_provider: RefCounted = null
var transition_provider: RefCounted = null
var impostor_candidates: RefCounted = null


func initialize() -> Error:
	return OK


func is_configured() -> bool:
	return is_object_streaming_configured() \
		or is_terrain_configured() \
		or character_source != null \
		or weather_provider != null \
		or dialogue_provider != null \
		or water_provider != null \
		or transition_provider != null \
		or impostor_candidates != null


func is_object_streaming_configured() -> bool:
	return coordinate_mapper != null \
		and object_source != null \
		and object_spawn_adapter != null \
		and asset_provider != null


func is_terrain_configured() -> bool:
	return terrain_provider != null


func get_coordinate_mapper() -> RefCounted:
	return coordinate_mapper


func get_object_source() -> RefCounted:
	return object_source


func get_object_spawn_adapter() -> RefCounted:
	return object_spawn_adapter


func get_terrain_provider() -> RefCounted:
	return terrain_provider


func get_asset_provider() -> RefCounted:
	return asset_provider


func get_character_source() -> RefCounted:
	return character_source


func get_weather_provider() -> RefCounted:
	return weather_provider


func get_dialogue_provider() -> RefCounted:
	return dialogue_provider


func get_water_provider() -> RefCounted:
	return water_provider


func get_transition_provider() -> RefCounted:
	return transition_provider


func get_impostor_candidates() -> RefCounted:
	return impostor_candidates
