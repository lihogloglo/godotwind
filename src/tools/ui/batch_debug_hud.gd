## BatchDebugHUD - Debug visualization for MidTierBatchPool
##
## Shows real-time batch pool statistics and LOD band boundary rings.
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

	var batch_pool: Node = _streaming_manager.get("_batch_pool")
	if not batch_pool:
		_stats_label.text = "[color=gray]Batch pool not initialized[/color]"
		return

	var stats: Dictionary = batch_pool.get_stats()
	var promoted: Dictionary = _streaming_manager.get("_promoted_objects")
	var promoted_count: int = promoted.size() if promoted else 0

	# Build BBCode text
	var text := "[b][color=#7799ff]MID-Tier Batch Pool[/color][/b]\n"
	text += "[color=#888]━━━━━━━━━━━━━━━━━━━━[/color]\n"

	# Summary
	var mesh_types: int = stats.get("mesh_types", 0)
	var batches: int = stats.get("batches", 0)
	var total_objects: int = stats.get("total_objects", 0)
	var visible_objects: int = stats.get("visible_objects", 0)
	var rebuilds: int = stats.get("rebuilds", 0)

	text += "[b]Mesh types:[/b] %d\n" % mesh_types
	text += "[b]Batches:[/b] %d (= draw calls)\n" % batches
	text += "[b]Objects:[/b] %d total, %d visible\n" % [total_objects, visible_objects]
	text += "[b]Promoted:[/b] %d (MID→NEAR)\n" % promoted_count
	text += "[b]Rebuilds:[/b] %d\n" % rebuilds

	# GPU draw call estimate
	var engine_draws := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	text += "[b]Engine draws:[/b] %d\n" % engine_draws

	# Per-band breakdown
	var details: Dictionary = stats.get("batch_details", {})
	if not details.is_empty():
		text += "\n[b][color=#aabbdd]Per-LOD Band:[/color][/b]\n"

		for lod: int in [1, 2, 3]:
			var band_label: String = BAND_LABELS.get(lod, "LOD%d" % lod)
			var band_objects := 0
			var band_batches := 0
			var band_capacity := 0

			for key: String in details:
				if key.ends_with("_lod%d" % lod):
					var d: Dictionary = details[key]
					band_objects += d.get("objects", 0)
					band_batches += 1
					band_capacity += d.get("capacity", 0)

			var color := "white"
			match lod:
				1: color = "#44ff44"  # Green
				2: color = "#ffcc44"  # Yellow
				3: color = "#ff6644"  # Orange

			text += "[color=%s]%s[/color]: %d obj in %d batches (cap: %d)\n" % [
				color, band_label, band_objects, band_batches, band_capacity
			]

	# Top batches by size
	if not details.is_empty():
		text += "\n[b][color=#aabbdd]Top Batches:[/color][/b]\n"
		var sorted_keys: Array = details.keys()
		sorted_keys.sort_custom(func(a: String, b: String) -> bool:
			return details[a].get("objects", 0) > details[b].get("objects", 0)
		)
		for i in mini(sorted_keys.size(), 5):
			var key: String = sorted_keys[i]
			var d: Dictionary = details[key]
			var obj_count: int = d.get("objects", 0)
			if obj_count == 0:
				break
			# Shorten the key for display
			var short_key := key.get_file() if "/" in key or "\\" in key else key
			if short_key.length() > 30:
				short_key = "..." + short_key.right(27)
			text += "[color=#888]%s[/color]: %d\n" % [short_key, obj_count]

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
