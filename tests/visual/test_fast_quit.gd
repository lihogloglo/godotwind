## Fast Quit Test — Verifies that quit happens near-instantly
##
## Tests both quit paths:
##   1. Escape menu Quit button (simulated via _do_fast_quit pattern)
##   2. Alt+F4 / window close (NOTIFICATION_WM_CLOSE_REQUEST)
##
## Also creates heavy dummy nodes to simulate the thousands of cell children
## that cause the slow quit in the main scene.
##
## Usage: Launch this scene, press Q to quit via fast path, ESC for menu quit.
##        Watch the console for timing output — quit should be <100ms.
extends Node3D

const DUMMY_NODE_COUNT := 5000  # Simulate loaded cell children
const DUMMY_MESH_INSTANCES := 500  # RS instances to test GPU cleanup

var _dummy_container: Node3D = null
var _rs_instances: Array[RID] = []
var _quit_timer_start: int = 0
var _label: Label = null


func _ready() -> void:
	get_tree().set_auto_accept_quit(false)

	# Create UI
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_label = Label.new()
	_label.text = "Fast Quit Test\n\nQ = Fast quit (tests _do_fast_quit path)\nAlt+F4 = Window close (tests NOTIFICATION_WM_CLOSE_REQUEST)\nESC = Quit via menu button pattern\n\nCreating %d dummy nodes + %d RS instances..." % [DUMMY_NODE_COUNT, DUMMY_MESH_INSTANCES]
	_label.position = Vector2(20, 20)
	_label.add_theme_font_size_override("font_size", 18)
	canvas.add_child(_label)

	# Create heavy dummy subtree (simulates loaded cells)
	_dummy_container = Node3D.new()
	_dummy_container.name = "DummyCells"
	add_child(_dummy_container)

	var t0 := Time.get_ticks_msec()
	for i in DUMMY_NODE_COUNT:
		var node := Node3D.new()
		node.name = "Cell_%d" % i
		_dummy_container.add_child(node)

	# Create RS instances (simulates StaticObjectRenderer)
	var scenario := get_world_3d().scenario
	for i in DUMMY_MESH_INSTANCES:
		var rid := RenderingServer.instance_create()
		RenderingServer.instance_set_scenario(rid, scenario)
		_rs_instances.append(rid)

	var elapsed := Time.get_ticks_msec() - t0
	_label.text = "Fast Quit Test — Ready!\n\n%d dummy nodes + %d RS instances created in %d ms\n\nQ = Fast quit\nAlt+F4 = Window close\nESC = Menu-style quit\n\nAll paths should quit in <100ms." % [DUMMY_NODE_COUNT, DUMMY_MESH_INSTANCES, elapsed]
	Log.info("testing", "Fast Quit Test: %d nodes + %d RS instances ready" % [DUMMY_NODE_COUNT, DUMMY_MESH_INSTANCES])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_do_fast_quit("Alt+F4 / Window Close")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q:
			_do_fast_quit("Q key")
		elif event.keycode == KEY_ESCAPE:
			_do_fast_quit("ESC key (menu-style)")


func _do_fast_quit(source: String) -> void:
	_quit_timer_start = Time.get_ticks_msec()
	Log.info("testing", "=== FAST QUIT from %s ===" % source)

	# Set global quitting flag — same as world_explorer._do_fast_quit()
	Engine.set_meta("_quitting", true)

	# Free RS instances (simulates fast_cleanup)
	for rid: RID in _rs_instances:
		if rid.is_valid():
			RenderingServer.free_rid(rid)
	_rs_instances.clear()

	var elapsed := Time.get_ticks_msec() - _quit_timer_start
	Log.info("testing", "Fast cleanup took %d ms — calling quit()" % elapsed)

	get_tree().quit()


func _exit_tree() -> void:
	if Engine.has_meta("_quitting"):
		var elapsed := Time.get_ticks_msec() - _quit_timer_start
		Log.info("testing", "test_fast_quit._exit_tree SKIPPED (quitting flag set) — %d ms since quit started" % elapsed)
		return
	# Normal cleanup (would be slow with 5000 children)
	Log.info("testing", "test_fast_quit._exit_tree running FULL cleanup (no quitting flag)")
	for rid: RID in _rs_instances:
		if rid.is_valid():
			RenderingServer.free_rid(rid)
	_rs_instances.clear()
