class_name WorldObjectRecord
extends RefCounted

enum Category {
	STATIC,
	DOOR,
	CONTAINER,
	ACTIVATOR,
	LIGHT,
	NPC,
	CREATURE,
	OTHER,
}

const CAP_GAMEPLAY := 1 << 0
const CAP_STATIC_VISUAL := 1 << 1
const CAP_COLLISION := 1 << 2
const CAP_HLOD := 1 << 3
const CAP_IMPOSTOR := 1 << 4
const CAP_DISTANT_LIGHT := 1 << 5

var object_id: StringName = &""
var source_ref_id: StringName = &""
var source_key: String = ""
var cell_grid: Vector2i = Vector2i.ZERO
var transform: Transform3D = Transform3D.IDENTITY
var model_path: String = ""
var category: int = Category.OTHER
var capability_flags: int = 0
var scale_scalar: float = 1.0
var light_color: Color = Color.WHITE
var light_radius: float = 0.0
var light_flags: int = 0
var legacy_ref: Variant = null
var legacy_base_record: Variant = null
var legacy_type_name: String = ""


func has_capability(flag: int) -> bool:
	return (capability_flags & flag) != 0


func bucket_key() -> String:
	return "%d,%d:%s" % [cell_grid.x, cell_grid.y, static_payload_key(model_path)]


static func static_payload_key(path: String) -> String:
	return path.to_lower().replace("/", "\\")


static func make_object_id(cell_grid: Vector2i, source_ref_id: String, legacy_ref_num: int) -> StringName:
	return StringName("%d,%d:%s:%d" % [cell_grid.x, cell_grid.y, source_ref_id.to_lower(), legacy_ref_num])
