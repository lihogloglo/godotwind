class_name MorrowindWorldSource
extends "res://src/core/world/world_source.gd"

const MorrowindCoordinateMapperScript: Script = preload("res://src/core/world/morrowind/morrowind_coordinate_mapper.gd")
const MorrowindWorldObjectSourceScript: Script = preload("res://src/core/world/morrowind/morrowind_world_object_source.gd")
const MorrowindObjectSpawnAdapterScript := preload("res://src/core/world/morrowind/morrowind_object_spawn_adapter.gd")
const MorrowindAssetProviderScript: Script = preload("res://src/core/world/morrowind/morrowind_asset_provider.gd")
const MorrowindDataProviderScript: Script = preload("res://src/core/world/morrowind/morrowind_data_provider.gd")


func _init() -> void:
	source_id = &"morrowind"
	display_name = "Morrowind"
	coordinate_mapper = MorrowindCoordinateMapperScript.new()
	object_source = MorrowindWorldObjectSourceScript.new()
	object_spawn_adapter = MorrowindObjectSpawnAdapterScript.new()
	object_spawn_adapter.configure(object_source)
	asset_provider = MorrowindAssetProviderScript.new()
	terrain_provider = MorrowindDataProviderScript.new()
