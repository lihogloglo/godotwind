## Wireframe + collision-shape debug view commands for the developer console.
##
## Two console commands:
##   wireframe [on|off]   — toggle viewport-wide wireframe rendering
##   collisions [on|off]  — toggle per-CollisionShape3D wireframe overlay
##
## Wireframe path is the canonical engine API — `Viewport.DEBUG_DRAW_WIREFRAME`
## backed by `RenderingServer.set_debug_generate_wireframes(true)` (must be
## called once at startup BEFORE the first mesh creates, otherwise pre-existing
## meshes have no wireframe index buffer and look broken). World_explorer wires
## the startup call via `enable_wireframe_generation()` in `_ready`. Permanent
## flip — the VRAM cost is the index buffer doubling for affected meshes,
## negligible vs the rest of the budget for a dev tool.
##
## Collision path uses `Shape3D.get_debug_mesh()` (the same ArrayMesh source
## the editor's "Visible Collision Shapes" gizmo uses). Visualizers are added
## as children of the CollisionShape3D node — when the shape's cell streams
## out, Godot auto-frees the child. No registry, no `is_instance_valid` guard,
## no sweep-on-toggle. Toggle ON = walk tree, add visualizer to every shape
## that doesn't have one. Toggle OFF = walk tree, queue_free every visualizer.
##
## NOTE on `get_tree().debug_collisions_hint`: setting this hint at runtime
## does NOT cause existing CollisionShape3D nodes to create debug meshes —
## the hint is only checked at `CollisionShape3D._ready`. Hand-rolled walk +
## `get_debug_mesh()` is the canonical mid-game-toggleable pattern (matches
## the editor's own implementation path).
##
## Streaming integration: world_explorer calls `on_cell_loaded()` from its
## `_on_native_cell_loaded` hook so freshly streamed cells get visualizers
## while the toggle is ON.
##
## Usage:
## [codeblock]
## DebugViewCommands.enable_wireframe_generation()  # call ONCE at startup
## var dv := DebugViewCommands.new(viewport, world_root)
## dv.register_commands(console)
## # later, on cell stream-in:
## dv.on_cell_loaded(cell_node)
## [/codeblock]
class_name DebugViewCommands
extends RefCounted

const _VIS_CHILD_NAME := &"_DebugCollisionVis"

var _viewport: Viewport = null
var _world_root: Node = null

var _wireframe_on: bool = false
var _collisions_on: bool = false
var _cached_debug_material: StandardMaterial3D = null


func _init(viewport: Viewport, world_root: Node) -> void:
	_viewport = viewport
	_world_root = world_root


## Call ONCE at startup, before any mesh is created. Required for the
## wireframe toggle to work — the debug index buffer is generated at mesh
## creation time, so meshes that load before this flag is set will have no
## wireframe geometry to display.
static func enable_wireframe_generation() -> void:
	RenderingServer.set_debug_generate_wireframes(true)


func register_commands(console: Console) -> void:
	console.register_command(
		"wireframe",
		_cmd_wireframe,
		"Toggle viewport wireframe view. Pass 'on'/'off' or omit to flip.",
		"debug",
		PackedStringArray(),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on/off (omit to flip)", false)] as Array[CommandRegistry.ParameterInfo]
	)
	console.register_command(
		"collisions",
		_cmd_collisions,
		"Toggle collision shape visualization (green wireframe overlay). Pass 'on'/'off' or omit to flip.",
		"debug",
		PackedStringArray(),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on/off (omit to flip)", false)] as Array[CommandRegistry.ParameterInfo]
	)


## Hook called by world_explorer._on_native_cell_loaded so freshly streamed
## cells get collision visualizers while the toggle is ON.
func on_cell_loaded(cell_node: Node) -> void:
	if _collisions_on and is_instance_valid(cell_node):
		_generate_collision_vis_recursive(cell_node)


func _cmd_wireframe(args: Dictionary) -> String:
	_wireframe_on = _resolve_state(args, _wireframe_on)
	if not _viewport:
		return "wireframe: no viewport bound"
	_viewport.debug_draw = (
		Viewport.DEBUG_DRAW_WIREFRAME if _wireframe_on else Viewport.DEBUG_DRAW_DISABLED
	)
	return "wireframe = %s" % ("ON" if _wireframe_on else "off")


func _cmd_collisions(args: Dictionary) -> String:
	_collisions_on = _resolve_state(args, _collisions_on)
	if not _world_root:
		return "collisions: no world root bound"
	if _collisions_on:
		var added := _generate_collision_vis_recursive(_world_root)
		return "collisions = ON (%d shape visualizers added)" % added
	var removed := _clear_collision_vis_recursive(_world_root)
	return "collisions = off (%d visualizers removed)" % removed


static func _resolve_state(args: Dictionary, current: bool) -> bool:
	if not args.has("state"):
		return not current
	var raw: String = String(args["state"]).to_lower().strip_edges()
	if raw in ["on", "true", "1", "yes"]:
		return true
	if raw in ["off", "false", "0", "no"]:
		return false
	# Unknown token — treat as flip
	return not current


func _generate_collision_vis_recursive(node: Node) -> int:
	var added: int = 0
	if node is CollisionShape3D:
		var cs := node as CollisionShape3D
		if cs.shape and not cs.has_node(NodePath(_VIS_CHILD_NAME)):
			var mesh := cs.shape.get_debug_mesh()
			if mesh:
				var mi := MeshInstance3D.new()
				mi.name = _VIS_CHILD_NAME
				mi.mesh = mesh
				mi.material_override = _debug_material()
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
				cs.add_child(mi)
				added += 1
	for child in node.get_children():
		added += _generate_collision_vis_recursive(child)
	return added


func _clear_collision_vis_recursive(node: Node) -> int:
	var removed: int = 0
	if node is CollisionShape3D:
		var cs := node as CollisionShape3D
		var path := NodePath(_VIS_CHILD_NAME)
		if cs.has_node(path):
			cs.get_node(path).queue_free()
			removed += 1
	for child in node.get_children():
		removed += _clear_collision_vis_recursive(child)
	return removed


func _debug_material() -> StandardMaterial3D:
	if _cached_debug_material:
		return _cached_debug_material
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.2, 1.0, 0.4, 1.0)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cached_debug_material = m
	return m
