class_name MorrowindNativeBridge
extends RefCounted

const NativeBridgeScript := preload("res://src/core/native_bridge.gd")

var _bridge: NativeBridge = null


func _init() -> void:
	_bridge = NativeBridgeScript.new()


func create_hydrology_atlas_builder() -> RefCounted:
	if _bridge == null:
		return null
	return _bridge.create_native_service(&"CreateMorrowindHydrologyAtlasBuilder")
