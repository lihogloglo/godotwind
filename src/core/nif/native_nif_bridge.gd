class_name NativeNIFBridge
extends RefCounted

const NativeBridgeScript := preload("res://src/core/native_bridge.gd")

var _bridge: NativeBridge = null


func _init() -> void:
	_bridge = NativeBridgeScript.new()


func has_native_nif() -> bool:
	return _bridge != null and _bridge.has_native_factory_method(&"CreateNIFReader")


func create_nif_reader() -> RefCounted:
	if not has_native_nif():
		return null
	return _bridge.create_native_service(&"CreateNIFReader")


func create_nif_converter() -> RefCounted:
	if not has_native_nif():
		return null
	return _bridge.create_native_service(&"CreateNIFConverter")


func parse_nif_buffer(data: PackedByteArray, path_hint: String = "") -> RefCounted:
	if not has_native_nif():
		return null
	return _bridge.call_native_factory(&"ParseNIFBuffer", [data, path_hint]) as RefCounted


@warning_ignore("unsafe_method_access")
func convert_nif_geometry(reader: RefCounted, data_index: int) -> Dictionary:
	if not has_native_nif() or reader == null:
		return {}

	var converter: RefCounted = create_nif_converter()
	if converter == null:
		return {}

	var record: Object = reader.call("GetRecord", data_index) as Object
	if record == null:
		return {}

	var result: Object = null
	var record_type: String = record.get("RecordType") if record.has_method("get") else ""
	if record_type == "NiTriShapeData":
		result = converter.call("ConvertTriShapeData", reader, data_index)
	elif record_type == "NiTriStripsData":
		result = converter.call("ConvertTriStripsData", reader, data_index)
	else:
		push_warning("NativeNIFBridge: Unknown geometry type at index %d" % data_index)
		return {}

	if result == null or not result.call("get_Success"):
		var error_msg: String = result.call("get_Error") if result else "null result"
		push_error("NativeNIFBridge: NIF conversion failed: %s" % error_msg)
		return {}

	return {
		"success": true,
		"vertices": result.call("get_Vertices"),
		"normals": result.call("get_Normals"),
		"uvs": result.call("get_UVs"),
		"colors": result.call("get_Colors"),
		"indices": result.call("get_Indices"),
		"center": result.call("get_Center"),
		"radius": result.call("get_Radius"),
		"vertex_count": result.call("get_VertexCount"),
		"triangle_count": result.call("get_TriangleCount"),
		"godot_arrays": result.call("ToGodotArrays"),
	}


func create_mesh_from_result(result: RefCounted) -> ArrayMesh:
	if result == null:
		return null
	return result.call("ToArrayMesh")


@warning_ignore("unsafe_method_access")
func batch_convert_geometries(reader: RefCounted, data_indices: PackedInt32Array) -> Array:
	if not has_native_nif() or reader == null:
		return []

	var converter: RefCounted = create_nif_converter()
	if converter == null:
		return []

	var results: Array = converter.call("BatchConvertShapes", reader, data_indices) as Array
	if results == null or results.is_empty():
		return []

	var output: Array = []
	for result: Object in results:
		if result != null and result.call("get_Success"):
			output.append({
				"success": true,
				"mesh": result.call("ToArrayMesh"),
				"vertex_count": result.call("get_VertexCount"),
				"triangle_count": result.call("get_TriangleCount"),
			})
		else:
			output.append({"success": false})

	return output


func simplify_mesh(vertices: PackedVector3Array, indices: PackedInt32Array, target_ratio: float) -> PackedInt32Array:
	if not has_native_nif():
		return indices

	var converter: RefCounted = create_nif_converter()
	if converter == null:
		return indices

	var result: Variant = converter.call("SimplifyMesh", vertices, indices, target_ratio)
	if result == null:
		return indices

	return result


@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
func convert_nif_to_scene(data: PackedByteArray, path_hint: String = "") -> Dictionary:
	if not has_native_nif():
		return {"success": false, "error": "Native NIF processing not available"}

	var conversion_result: Object = _bridge.call_native_factory(&"ConvertNIFToScene", [data, path_hint]) as Object
	if conversion_result == null:
		return {"success": false, "error": "ConvertNIFToScene returned null"}

	return _scene_result_to_dictionary(conversion_result)


@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
func convert_reader_to_scene(reader: RefCounted, path_hint: String = "") -> Dictionary:
	if not has_native_nif() or reader == null:
		return {"success": false, "error": "Native NIF processing not available or null reader"}

	var conversion_result: Object = _bridge.call_native_factory(&"ConvertReaderToScene", [reader, path_hint]) as Object
	if conversion_result == null:
		return {"success": false, "error": "ConvertReaderToScene returned null"}

	return _scene_result_to_dictionary(conversion_result)


@warning_ignore("unsafe_property_access")
func _scene_result_to_dictionary(conversion_result: Object) -> Dictionary:
	var success: bool = conversion_result.get("Success")
	if not success:
		var error: String = conversion_result.get("Error")
		return {"success": false, "error": error}

	var texture_paths: Array[String] = []
	var tex_paths_obj: Variant = conversion_result.get("TexturePaths")
	if tex_paths_obj != null and tex_paths_obj is Array:
		for path: Variant in tex_paths_obj:
			if path is String:
				texture_paths.append(path as String)

	return {
		"success": true,
		"error": "",
		"root": conversion_result.get("RootNode") as Node3D,
		"mesh_count": conversion_result.get("MeshCount"),
		"total_vertices": conversion_result.get("TotalVertices"),
		"total_triangles": conversion_result.get("TotalTriangles"),
		"texture_paths": texture_paths,
	}
