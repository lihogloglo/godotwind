class_name WorldSpaceHandle
extends RefCounted

const TYPE_UNKNOWN: StringName = &"unknown"
const TYPE_EXTERIOR: StringName = &"exterior"
const TYPE_INTERIOR: StringName = &"interior"

var space_type: StringName = TYPE_UNKNOWN
var key: String = ""
var display_name: String = ""


static func exterior(key_value: String, display_value: String = "") -> WorldSpaceHandle:
	var handle := WorldSpaceHandle.new()
	handle.space_type = TYPE_EXTERIOR
	handle.key = key_value
	handle.display_name = display_value if not display_value.is_empty() else key_value
	return handle


static func exterior_grid(grid: Vector2i) -> WorldSpaceHandle:
	return exterior("%d,%d" % [grid.x, grid.y])


static func interior(key_value: String, display_value: String = "") -> WorldSpaceHandle:
	var handle := WorldSpaceHandle.new()
	handle.space_type = TYPE_INTERIOR
	handle.key = key_value
	handle.display_name = display_value if not display_value.is_empty() else key_value
	return handle


func is_interior() -> bool:
	return space_type == TYPE_INTERIOR


func is_exterior() -> bool:
	return space_type == TYPE_EXTERIOR

