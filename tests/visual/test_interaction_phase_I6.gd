## Phase I.6 — carried-object streaming safety (plumbing test)
##
## Validates the I.6 contract from `docs/INTERACTION_SYSTEM.md` §10:
##   - `NativeStreamingManager` exposes `register_persistent_node` /
##     `unregister_persistent_node` / `find_grid_for_node` API
##   - `OrphanedCarriedItems` Node3D exists as a child of streaming
##     manager (NOT a separate autoload per spec §9)
##   - On cell unload, persistent nodes get reparented to the orphan
##     container with global transform preserved
##   - Auto-cleanup via `tree_exiting` signal — frees in registry
##     don't leak entries
##
## This test does NOT spawn a real cell stream — too heavy. It uses a
## fake cell Node3D + fake held body Node3D + manually invokes the
## `_evacuate_persistent_nodes_from_cell` helper to verify the logic
## without booting the full streaming pipeline.
##
## Live integration with carry_controller is deferred per @roaster
## guidance — vibration verdict ships first, then carry plumbing.
##
## Run: godot --path . res://tests/visual/test_interaction_phase_I6.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
extends Node

const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")


func _ready() -> void:
	await _run_self_tests()
	_build_ui()


# ----------------------------------------------------------------------------
# Self-tests
# ----------------------------------------------------------------------------

func _run_self_tests() -> void:
	_test_orphan_container_exists()
	_test_register_unregister_api()
	_test_evacuate_persistent_node()
	_test_auto_cleanup_on_free()
	await _test_rehome_on_cell_load()
	await _test_orphan_expiry_by_distance()
	await _test_orphan_expiry_by_age()
	Log.info("interaction", "[self-test] I.6 streaming plumbing + Phase 2 — PASS")


# Test 1 — orphan container is created in _ready
func _test_orphan_container_exists() -> void:
	var sm := NativeStreamingManagerScript.new()
	add_child(sm)
	# _ready fires synchronously after add_child for nodes added at runtime.
	# The streaming manager's _ready has heavy initialization (cell manager,
	# impostor renderer, etc.) — we accept the cost for the test scope.
	var orphan: Node = sm.get_node_or_null("OrphanedCarriedItems")
	assert(orphan != null, "OrphanedCarriedItems node not found")
	assert(orphan is Node3D, "OrphanedCarriedItems should be a Node3D")
	sm.queue_free()
	await get_tree().process_frame


# Test 2 — register / unregister API
func _test_register_unregister_api() -> void:
	var sm := NativeStreamingManagerScript.new()
	add_child(sm)
	var fake_body := Node3D.new()
	fake_body.name = "FakeHeldBody"
	add_child(fake_body)

	# Initially not registered
	assert(sm._persistent_nodes.size() == 0,
		"persistent_nodes should start empty, got %d" % sm._persistent_nodes.size())

	# Register
	sm.register_persistent_node(fake_body, Vector2i(3, -7))
	assert(sm._persistent_nodes.size() == 1,
		"persistent_nodes should have 1 entry after register, got %d" % sm._persistent_nodes.size())
	# Phase 2 — value is now a PersistentNodeEntry struct with
	# original_grid + timestamps rather than a raw Vector2i.
	var entry = sm._persistent_nodes[fake_body]
	assert(entry != null, "entry null after register")
	assert(entry.original_grid == Vector2i(3, -7),
		"grid mismatch on register")
	assert(entry.created_ms > 0, "created_ms not set on register")

	# Unregister
	sm.unregister_persistent_node(fake_body)
	assert(sm._persistent_nodes.size() == 0,
		"persistent_nodes should be empty after unregister, got %d" % sm._persistent_nodes.size())

	# Idempotent unregister
	sm.unregister_persistent_node(fake_body)
	assert(sm._persistent_nodes.size() == 0, "double unregister should be safe")

	fake_body.queue_free()
	sm.queue_free()
	await get_tree().process_frame


# Test 3 — evacuate persistent node from a fake cell
func _test_evacuate_persistent_node() -> void:
	var sm := NativeStreamingManagerScript.new()
	add_child(sm)
	# Build a fake cell containing a fake held body.
	var fake_cell := Node3D.new()
	fake_cell.name = "FakeCell_3_-7"
	fake_cell.position = Vector3(351, 0, -819)  # roughly cell (3,-7) world pos
	add_child(fake_cell)
	var fake_body := Node3D.new()
	fake_body.name = "FakeHeldBody"
	fake_cell.add_child(fake_body)
	fake_body.global_position = Vector3(355, 5, -820)
	var pre_world_pos: Vector3 = fake_body.global_position

	# Register the body as persistent for cell (3,-7)
	sm.register_persistent_node(fake_body, Vector2i(3, -7))

	# Manually invoke the evacuation helper (the unload path's hook)
	sm._evacuate_persistent_nodes_from_cell(fake_cell, Vector2i(3, -7))

	# Body should now be a child of the orphan container, NOT the cell.
	var orphan := sm.get_node("OrphanedCarriedItems")
	assert(fake_body.get_parent() == orphan,
		"fake_body parent should be OrphanedCarriedItems, got %s" %
		(fake_body.get_parent().name if fake_body.get_parent() else "null"))

	# Global position should be preserved (reparent with keep_global=true).
	var post_world_pos: Vector3 = fake_body.global_position
	assert(pre_world_pos.distance_to(post_world_pos) < 0.001,
		"global position not preserved: %s → %s" % [pre_world_pos, post_world_pos])

	# Registry entry should still exist (re-keyed but not removed).
	assert(sm._persistent_nodes.has(fake_body),
		"persistent_nodes lost the body on evacuation")

	fake_body.queue_free()
	fake_cell.queue_free()
	sm.queue_free()
	await get_tree().process_frame


# Test 4 — explicit unregister + lazy stale-entry pruning
# (auto-cleanup on free was rejected because Godot's `tree_exiting`
# also fires on `reparent`, which is exactly what evacuation does;
# the auto-clean would wipe entries mid-evacuation)
func _test_auto_cleanup_on_free() -> void:
	var sm := NativeStreamingManagerScript.new()
	add_child(sm)
	var fake_body := Node3D.new()
	add_child(fake_body)
	sm.register_persistent_node(fake_body, Vector2i(0, 0))
	assert(sm._persistent_nodes.size() == 1, "register failed")

	# Caller MUST unregister explicitly. Test that path:
	sm.unregister_persistent_node(fake_body)
	assert(sm._persistent_nodes.size() == 0, "explicit unregister failed")

	# Stale entry case: register, free without unregister, evacuate
	# walks the dict and skips the dead entry via is_instance_valid.
	# (The dead entry stays in the dict — that's intentional. Lazy
	# pruning happens at next register or evacuate that touches it.)
	sm.register_persistent_node(fake_body, Vector2i(0, 0))
	fake_body.queue_free()
	await get_tree().process_frame
	# Entry still present (no auto-clean) but pointing at a freed node.
	assert(sm._persistent_nodes.size() == 1,
		"stale entry should remain until lazy prune")
	# Calling evacuate on a fake cell should walk the dict, hit the
	# dead body via is_instance_valid, and not crash.
	var fake_cell := Node3D.new()
	add_child(fake_cell)
	sm._evacuate_persistent_nodes_from_cell(fake_cell, Vector2i(0, 0))
	# (No assertion on the count — the dead entry isn't pruned by the
	# walk, only skipped. Lazy pruning is intentional.)
	fake_cell.queue_free()

	sm.queue_free()
	await get_tree().process_frame


# ----------------------------------------------------------------------------
# Phase 2 tests (2026-04-09)
# ----------------------------------------------------------------------------

# Test 5 — re-home on cell load. Sequence: register body in cell A,
# evacuate (cell A unloads), then call _rehome_persistent_nodes_for_cell
# with a fresh fake cell A' at the same grid coord. Body should end up
# parented under the new cell node with global transform preserved.
func _test_rehome_on_cell_load() -> void:
	var sm := NativeStreamingManagerScript.new()
	add_child(sm)

	var cell_a := Node3D.new()
	cell_a.name = "CellA"
	cell_a.position = Vector3(351, 0, -819)
	add_child(cell_a)

	var body := Node3D.new()
	body.name = "PersistentBody"
	cell_a.add_child(body)
	body.global_position = Vector3(355, 5, -820)
	var captured_world_pos: Vector3 = body.global_position

	sm.register_persistent_node(body, Vector2i(3, -7))
	sm._evacuate_persistent_nodes_from_cell(cell_a, Vector2i(3, -7))
	var orphan := sm.get_node("OrphanedCarriedItems")
	assert(body.get_parent() == orphan, "body not evacuated to orphan container")

	# Simulate cell A reloading with a fresh node at the same grid.
	var cell_a_reloaded := Node3D.new()
	cell_a_reloaded.name = "CellA_reloaded"
	cell_a_reloaded.position = Vector3(351, 0, -819)
	add_child(cell_a_reloaded)

	sm._rehome_persistent_nodes_for_cell(cell_a_reloaded, Vector2i(3, -7))

	assert(body.get_parent() == cell_a_reloaded,
		"body not re-homed into reloaded cell, parent=%s" %
		(body.get_parent().name if body.get_parent() else "null"))
	# Global transform should be preserved through the reparent (within
	# a small epsilon for the walk-back ground snap, which is a no-op
	# here because there's no physics environment for the raycast).
	assert(body.global_position.distance_to(captured_world_pos) < 0.1,
		"global position lost through re-home: %s → %s" %
		[captured_world_pos, body.global_position])

	body.queue_free()
	cell_a.queue_free()
	cell_a_reloaded.queue_free()
	sm.queue_free()
	await get_tree().process_frame


# Test 6 — bound policy by Chebyshev distance. Register body in cell A,
# evacuate, move the camera 9 cells away, run the prune tick, assert the
# body is queued for deletion.
func _test_orphan_expiry_by_distance() -> void:
	var sm := NativeStreamingManagerScript.new()
	add_child(sm)

	var cell_a := Node3D.new()
	cell_a.name = "CellA"
	add_child(cell_a)
	var body := Node3D.new()
	body.name = "OrphanBody"
	cell_a.add_child(body)
	body.global_position = Vector3(0, 0, 0)

	sm.register_persistent_node(body, Vector2i(0, 0))
	sm._evacuate_persistent_nodes_from_cell(cell_a, Vector2i(0, 0))

	# Simulate the camera walking 9 cells away (Chebyshev = 9 > 8).
	sm._camera_cell = Vector2i(9, 0)
	sm._prune_expired_orphans()

	# The body should now be queued for deletion and its entry erased.
	assert(not sm._persistent_nodes.has(body),
		"expired orphan should have been removed from registry")
	assert(body.is_queued_for_deletion() or not is_instance_valid(body),
		"expired orphan should be queue_freed")

	cell_a.queue_free()
	sm.queue_free()
	await get_tree().process_frame


# Test 7 — bound policy by age. Register body, evacuate, rewind the
# entry's `created_ms` by > 5 minutes, run the prune, assert expiry.
func _test_orphan_expiry_by_age() -> void:
	var sm := NativeStreamingManagerScript.new()
	add_child(sm)

	var cell_a := Node3D.new()
	cell_a.name = "CellA"
	add_child(cell_a)
	var body := Node3D.new()
	body.name = "AgedOrphan"
	cell_a.add_child(body)

	sm.register_persistent_node(body, Vector2i(0, 0))
	sm._evacuate_persistent_nodes_from_cell(cell_a, Vector2i(0, 0))

	# Rewind the entry's creation time by 6 minutes (> ORPHAN_EXPIRY_MS).
	var entry = sm._persistent_nodes[body]
	entry.created_ms -= 6 * 60 * 1000

	# Keep the camera on the same cell so only age triggers expiry.
	sm._camera_cell = Vector2i(0, 0)
	sm._prune_expired_orphans()

	assert(not sm._persistent_nodes.has(body),
		"aged orphan should have been removed from registry")
	assert(body.is_queued_for_deletion() or not is_instance_valid(body),
		"aged orphan should be queue_freed")

	cell_a.queue_free()
	sm.queue_free()
	await get_tree().process_frame


# ----------------------------------------------------------------------------
# UI — minimal status display
# ----------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var label := Label.new()
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.offset_left = -300
	label.offset_top = -100
	label.offset_right = 300
	label.offset_bottom = 100
	label.add_theme_font_size_override("font_size", 18)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.text = "I.6 streaming plumbing self-tests\n\nCheck console for [self-test] PASS line.\n\nPlumbing only — live carry integration\ndeferred until vibration ships per\n@roaster guidance."
	layer.add_child(label)
