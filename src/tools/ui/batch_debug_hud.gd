## BatchDebugHUD - Debug visualization for MID-tier static renderer
##
## Shows real-time RS instance statistics and LOD band boundary rings.
## Toggle with console command `mid_debug` or programmatically.
##
## Visualization:
##   - HUD panel (upper-right): batch count, objects per LOD band, draw calls
##   - 3D rings at LOD boundaries: 150m (green), 250m (yellow), 375m (orange), 500m (red)
##   - Color key matches LOD_COLORS in DebugOverlay
##
## Usage:
##   var hud := BatchDebugHUD.new()
##   add_child(hud)
##   hud.set_streaming_manager(native_streaming_manager)
class_name BatchDebugHUD
extends CanvasLayer

const DU := preload("res://src/core/world/distance_utils.gd")

#region State

var _streaming_manager: Node = null
var _camera: Camera3D = null

## 3D ring container (added to the scene tree root, not the CanvasLayer)
var _ring_container: Node3D = null

## HUD elements
var _panel: PanelContainer
var _stats_label: RichTextLabel

## Update timer
var _update_timer: float = 0.0
const UPDATE_INTERVAL: float = 0.25  # 4 Hz

## Ring colors for LOD boundaries
const RING_COLORS: Dictionary = {
	150: Color(0.2, 1.0, 0.2, 0.7),    # NEAR→LOD1 boundary (green)
	250: Color(1.0, 1.0, 0.2, 0.7),    # LOD1→LOD2 boundary (yellow)
	375: Color(1.0, 0.6, 0.2, 0.7),    # LOD2→LOD3 boundary (orange)
	500: Color(1.0, 0.3, 0.2, 0.7),    # LOD3→FAR boundary (red)
}

## Band labels for display
const BAND_LABELS: Dictionary = {
	1: "LOD1 (150-250m)",
	2: "LOD2 (250-375m)",
	3: "LOD3 (375-500m)",
}

#endregion


#region Initialization

func _ready() -> void:
	layer = 100  # On top of everything
	_build_hud()
	_build_rings()
	visible = false  # Start hidden


func _exit_tree() -> void:
	if _ring_container and is_instance_valid(_ring_container):
		_ring_container.queue_free()


func set_streaming_manager(mgr: Node) -> void:
	_streaming_manager = mgr


func set_camera(cam: Camera3D) -> void:
	_camera = cam

#endregion


#region HUD Construction

func _build_hud() -> void:
	# Semi-transparent panel in upper-right
	_panel = PanelContainer.new()
	_panel.name = "BatchStatsPanel"

	# Style: dark semi-transparent background
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.1, 0.85)
	style.border_color = Color(0.3, 0.5, 0.8, 0.6)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	_panel.add_theme_stylebox_override("panel", style)

	# Anchor to top-right
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -320
	_panel.offset_right = -10
	_panel.offset_top = 10
	_panel.offset_bottom = 300

	# Rich text label for stats
	_stats_label = RichTextLabel.new()
	_stats_label.name = "StatsLabel"
	_stats_label.bbcode_enabled = true
	_stats_label.fit_content = true
	_stats_label.scroll_active = false
	_stats_label.custom_minimum_size = Vector2(300, 0)

	# Font size
	_stats_label.add_theme_font_size_override("normal_font_size", 13)
	_stats_label.add_theme_font_size_override("bold_font_size", 14)

	_panel.add_child(_stats_label)
	add_child(_panel)

#endregion


#region 3D Ring Construction

func _build_rings() -> void:
	_ring_container = Node3D.new()
	_ring_container.name = "BatchDebugRings"

	for distance: int in RING_COLORS:
		var color: Color = RING_COLORS[distance]
		var ring := _create_ring_mesh(float(distance), color, 2.0)
		ring.name = "Ring_%dm" % distance

		# Add a label at the ring
		var label := Label3D.new()
		label.text = "%dm" % distance
		label.font_size = 48
		label.modulate = color
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.position = Vector3(float(distance), 8.0, 0.0)
		ring.add_child(label)

		_ring_container.add_child(ring)


func _create_ring_mesh(radius: float, color: Color, width: float) -> MeshInstance3D:
	var segments := 64
	var im := ImmediateMesh.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = im

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = mat

	# Draw ring as line strip (inner and outer circles connected)
	var inner_r := radius - width * 0.5
	var outer_r := radius + width * 0.5

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in segments + 1:
		var angle := TAU * float(i) / float(segments)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		im.surface_add_vertex(dir * inner_r + Vector3(0, 0.5, 0))
		im.surface_add_vertex(dir * outer_r + Vector3(0, 0.5, 0))
	im.surface_end()

	return mesh_instance

#endregion


#region Update

func _process(delta: float) -> void:
	if not visible:
		# Keep rings synced with visibility
		if _ring_container and _ring_container.visible:
			_ring_container.visible = false
		return

	# Ensure rings are parented to the scene (not the CanvasLayer)
	if _ring_container and not _ring_container.is_inside_tree():
		var root := get_tree().current_scene
		if root:
			root.add_child(_ring_container)

	# Show/hide rings with HUD
	if _ring_container:
		_ring_container.visible = true

	# Auto-find camera
	if not _camera:
		_camera = get_viewport().get_camera_3d()

	# Update ring position to follow camera (XZ only)
	if _camera and _ring_container:
		var cam_pos := _camera.global_position
		_ring_container.global_position = Vector3(cam_pos.x, 0.0, cam_pos.z)

	# Throttled stats update
	_update_timer += delta
	if _update_timer >= UPDATE_INTERVAL:
		_update_timer = 0.0
		_update_stats()


func _update_stats() -> void:
	if not _streaming_manager:
		_stats_label.text = "[color=gray]No streaming manager connected[/color]"
		return

	var static_renderer = _streaming_manager.get("_static_renderer")
	if not static_renderer:
		_stats_label.text = "[color=gray]Static renderer not initialized[/color]"
		return

	var stats: Dictionary = static_renderer.get_stats()
	var promoted: Dictionary = _streaming_manager.get("_promoted_objects")
	var promoted_count: int = promoted.size() if promoted else 0

	# Build BBCode text
	var text := "[b][color=#7799ff]MID-Tier Static Renderer[/color][/b]\n"
	text += "[color=#888]━━━━━━━━━━━━━━━━━━━━[/color]\n"

	# Summary
	var mesh_types: int = stats.get("mesh_types", 0)
	var total_instances: int = stats.get("total_instances", 0)
	var visible_instances: int = stats.get("visible_instances", 0)
	var lod_instances: int = stats.get("lod_instances", 0)

	text += "[b]Mesh types:[/b] %d\n" % mesh_types
	text += "[b]Instances:[/b] %d total, %d visible\n" % [total_instances, visible_instances]
	text += "[b]LOD RIDs:[/b] %d (RS auto-batched)\n" % lod_instances
	text += "[b]Promoted:[/b] %d (MID→NEAR)\n" % promoted_count

	# GPU draw call estimate
	var engine_draws := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	text += "[b]Engine draws:[/b] %d\n" % engine_draws

	# Per mesh type breakdown (top 5 by instance count)
	var type_names: Array[String] = static_renderer.get_registered_types()
	if not type_names.is_empty():
		text += "\n[b][color=#aabbdd]Top Mesh Types:[/color][/b]\n"

		var type_counts: Array[Dictionary] = []
		for tn: String in type_names:
			var type_stats: Dictionary = static_renderer.get_mesh_type_stats(tn)
			type_counts.append(type_stats)
		type_counts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("instance_count", 0) > b.get("instance_count", 0)
		)

		for i in mini(type_counts.size(), 5):
			var ts: Dictionary = type_counts[i]
			var count: int = ts.get("instance_count", 0)
			if count == 0:
				break
			var name: String = ts.get("name", "?")
			var has_lod: bool = ts.get("has_lod", false)
			var short_name := name.get_file() if "/" in name or "\\" in name else name
			if short_name.length() > 30:
				short_name = "..." + short_name.right(27)
			var lod_tag := "[color=#44ff44]LOD[/color]" if has_lod else "[color=#888]no LOD[/color]"
			text += "[color=#ccc]%s[/color]: %d %s\n" % [short_name, count, lod_tag]

	_stats_label.text = text

#endregion


#region Public API

## Toggle visibility
func toggle() -> void:
	visible = not visible
	Log.info("debug", "Batch debug HUD: %s" % ("ON" if visible else "OFF"))


## Get whether visible
func is_active() -> bool:
	return visible

#endregion
