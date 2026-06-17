## NativeBridge - source-neutral bridge to high-performance C# code.
##
## This module owns only C# availability and generic factory access. Importers
## and source adapters own parser/content-specific wrappers.

@warning_ignore("untyped_declaration")
@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
@warning_ignore("unsafe_cast")

class_name NativeBridge
extends RefCounted

const NATIVE_FACTORY_PATH := "res://src/native/NativeFactory.cs"

static var _factory: RefCounted = null
static var _checked: bool = false
static var _native_available: bool = false


func _init() -> void:
	_check_native_availability()


static func _check_native_availability() -> void:
	if _checked:
		return
	_checked = true

	if not ResourceLoader.exists(NATIVE_FACTORY_PATH):
		Log.info("bridge", "Native factory not found at %s" % NATIVE_FACTORY_PATH)
		return

	var factory_script: Resource = load(NATIVE_FACTORY_PATH)
	if factory_script == null:
		Log.info("bridge", "Failed to load native factory script")
		return

	_factory = factory_script.call("new") as RefCounted
	if _factory == null:
		Log.info("bridge", "Failed to instantiate native factory")
		return

	if not _factory.call("IsAvailable"):
		Log.info("bridge", "Native factory reported not available")
		_factory = null
		return

	_native_available = true
	var version: String = _factory.call("GetVersion")
	Log.info("bridge", "Native C# code available (version %s)" % version)


static func is_csharp_available() -> bool:
	_check_native_availability()
	return _native_available


func is_native_available() -> bool:
	return _native_available


func has_native_factory_method(method_name: StringName) -> bool:
	return _native_available and _factory != null and _factory.has_method(method_name)


func create_native_service(factory_method: StringName) -> RefCounted:
	if not has_native_factory_method(factory_method):
		return null
	return _factory.call(factory_method) as RefCounted


func call_native_factory(factory_method: StringName, args: Array = []) -> Variant:
	if not has_native_factory_method(factory_method):
		return null
	return _factory.callv(factory_method, args)


func has_native_terrain() -> bool:
	return _native_available


func create_terrain_generator() -> RefCounted:
	return create_native_service(&"CreateTerrainGenerator")


func has_native_binary_reader() -> bool:
	return _native_available


func create_binary_reader() -> RefCounted:
	return create_native_service(&"CreateBinaryReader")


func generate_heightmap(heights: PackedFloat32Array) -> Image:
	var generator: RefCounted = create_terrain_generator()
	if generator == null:
		return null

	var height_array: Array[float] = []
	height_array.resize(heights.size())
	for i in range(heights.size()):
		height_array[i] = heights[i]

	return generator.call("GenerateHeightmap", height_array)


func generate_color_map(colors: PackedByteArray) -> Image:
	var generator: RefCounted = create_terrain_generator()
	if generator == null:
		return null
	return generator.call("GenerateColorMap", colors)


func generate_control_map(texture_indices: PackedInt32Array, _slot_mapper: Callable = Callable()) -> Image:
	var generator: RefCounted = create_terrain_generator()
	if generator == null:
		return null

	var tex_array: Array[int] = []
	tex_array.resize(texture_indices.size())
	for i in range(texture_indices.size()):
		tex_array[i] = texture_indices[i]

	return generator.call("GenerateControlMap", tex_array)


func create_shore_mask_baker() -> RefCounted:
	return create_native_service(&"CreateShoreMaskBaker")


func create_river_mesh_builder() -> RefCounted:
	return create_native_service(&"CreateRiverMeshBuilder")


func get_performance_info() -> Dictionary:
	return {
		"native_available": _native_available,
		"factory_loaded": _factory != null,
		"terrain_generator": has_native_terrain(),
		"binary_reader": has_native_binary_reader(),
	}
