class_name MorrowindWorldSource
extends "res://src/core/world/world_source.gd"

const MorrowindCoordinateMapperScript: Script = preload("res://src/core/world/morrowind/morrowind_coordinate_mapper.gd")
const MorrowindWorldObjectSourceScript: Script = preload("res://src/core/world/morrowind/morrowind_world_object_source.gd")
const MorrowindObjectSpawnAdapterScript := preload("res://src/core/world/morrowind/morrowind_object_spawn_adapter.gd")
const MorrowindAssetProviderScript: Script = preload("res://src/core/world/morrowind/morrowind_asset_provider.gd")
const MorrowindDataProviderScript: Script = preload("res://src/core/world/morrowind/morrowind_data_provider.gd")
const MorrowindHydrologyProviderScript: Script = preload("res://src/core/world/morrowind/morrowind_hydrology_provider.gd")
const MorrowindTransitionProviderScript: Script = preload("res://src/core/world/morrowind/morrowind_transition_provider.gd")
const MorrowindImpostorCandidatesScript: Script = preload("res://src/core/world/morrowind/morrowind_impostor_candidates.gd")


func _init() -> void:
	source_id = &"morrowind"
	display_name = "Morrowind"
	coordinate_mapper = MorrowindCoordinateMapperScript.new()
	object_source = MorrowindWorldObjectSourceScript.new()
	object_spawn_adapter = MorrowindObjectSpawnAdapterScript.new()
	object_spawn_adapter.configure(object_source)
	transition_provider = MorrowindTransitionProviderScript.new()
	transition_provider.configure(object_source)
	asset_provider = MorrowindAssetProviderScript.new()
	terrain_provider = MorrowindDataProviderScript.new()
	water_provider = MorrowindHydrologyProviderScript.new()
	water_provider.configure(terrain_provider, coordinate_mapper)
	impostor_candidates = MorrowindImpostorCandidatesScript.new()
