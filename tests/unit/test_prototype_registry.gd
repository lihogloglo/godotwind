## Unit tests for PrototypeBatch + PrototypeRegistry (Phase 3 step 1 skeleton).
##
## Covers:
##   - Slot acquire / release / freelist round-trip
##   - Capacity growth on exhaustion
##   - Registry batch dedup (same mesh+material returns same batch)
##   - Registry multi-sub-mesh instance (one instance, N slots across N batches)
##   - remove_instance releases all slots and is idempotent
##
## Notes:
## - Uses PrototypeBatchScript / PrototypeRegistryScript Script consts as type
##   annotations instead of the class_name symbols. class_name resolution from
##   test files happens after test-suite scanning in gdUnit4's current path.
extends GdUnitTestSuite

const PrototypeBatchScript := preload("res://src/core/world/prototype_batch.gd")
const PrototypeRegistryScript := preload("res://src/core/world/prototype_registry.gd")


var _scenario: RID
var _owned_rids: Array[RID] = []


func before_test() -> void:
	_scenario = RenderingServer.scenario_create()
	_owned_rids.clear()
	_owned_rids.append(_scenario)


func after_test() -> void:
	## Tear down any RS RIDs we created to keep the test harness clean.
	for rid: RID in _owned_rids:
		if rid.is_valid():
			RenderingServer.free_rid(rid)
	_owned_rids.clear()


func _make_mesh() -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = 1.0
	m.height = 2.0
	return m


## Build a batch and return it. Tracks its RS instance for cleanup.
func _build_batch(mesh: Mesh = null, material: Material = null, cap: int = 4) -> RefCounted:
	var m: Mesh = mesh if mesh != null else _make_mesh()
	var b: RefCounted = PrototypeBatchScript.new(m, material, _scenario, cap)
	_owned_rids.append(b.rs_instance)
	return b


#region PrototypeBatch tests

func test_batch_init_capacity() -> void:
	var b := _build_batch(null, null, 4)
	var stats: Dictionary = b.get_stats()
	assert_int(stats["capacity"]).is_equal(4)
	assert_int(stats["live"]).is_equal(0)
	assert_int(stats["free"]).is_equal(4)
	b.cleanup()


func test_batch_acquire_and_release() -> void:
	var b := _build_batch(null, null, 4)

	var s0: int = b.acquire_slot()
	var s1: int = b.acquire_slot()
	assert_int(s0).is_not_equal(s1)
	assert_int((b.get_stats() as Dictionary)["live"]).is_equal(2)
	assert_int((b.get_stats() as Dictionary)["free"]).is_equal(2)

	b.release_slot(s0)
	assert_int((b.get_stats() as Dictionary)["live"]).is_equal(1)
	assert_int((b.get_stats() as Dictionary)["free"]).is_equal(3)

	b.release_slot(s1)
	assert_int((b.get_stats() as Dictionary)["live"]).is_equal(0)
	assert_int((b.get_stats() as Dictionary)["free"]).is_equal(4)
	b.cleanup()


func test_batch_freelist_reuses_slot() -> void:
	var b := _build_batch(null, null, 4)
	var s: int = b.acquire_slot()
	b.release_slot(s)
	var s2: int = b.acquire_slot()
	## Freelist is LIFO, so the just-released slot should come back first.
	assert_int(s2).is_equal(s)
	b.cleanup()


func test_batch_grows_beyond_initial_capacity() -> void:
	var b := _build_batch(null, null, 2)
	var slots: Array[int] = []
	for _i in 5:
		slots.append(b.acquire_slot())
	var stats: Dictionary = b.get_stats()
	assert_int(stats["capacity"]).is_greater_equal(5)
	assert_int(stats["live"]).is_equal(5)

	## All slot indices are distinct.
	for i in slots.size():
		for j in range(i + 1, slots.size()):
			assert_int(slots[i]).is_not_equal(slots[j])
	b.cleanup()

#endregion


#region PrototypeRegistry tests

func test_registry_get_or_create_batch_dedupes() -> void:
	var registry: RefCounted = PrototypeRegistryScript.new(_scenario)
	var mesh := _make_mesh()
	var b1: RefCounted = registry.get_or_create_batch(mesh, null)
	var b2: RefCounted = registry.get_or_create_batch(mesh, null)
	## Same (mesh, material=null) key — registry must return the cached batch
	## rather than spawning a second one.
	assert_int(registry.get_batch_count()).is_equal(1)
	assert_int(b1.get_instance_id()).is_equal(b2.get_instance_id())
	_owned_rids.append(b1.rs_instance)
	registry.cleanup()


func test_registry_different_materials_different_batches() -> void:
	var registry: RefCounted = PrototypeRegistryScript.new(_scenario)
	var mesh := _make_mesh()
	var mat_a := StandardMaterial3D.new()
	var mat_b := StandardMaterial3D.new()
	var b1: RefCounted = registry.get_or_create_batch(mesh, mat_a)
	var b2: RefCounted = registry.get_or_create_batch(mesh, mat_b)
	assert_int(b1.get_instance_id()).is_not_equal(b2.get_instance_id())
	assert_int(registry.get_batch_count()).is_equal(2)
	_owned_rids.append(b1.rs_instance)
	_owned_rids.append(b2.rs_instance)
	registry.cleanup()


func test_registry_add_instance_single_sub_mesh() -> void:
	var registry: RefCounted = PrototypeRegistryScript.new(_scenario)
	var mesh := _make_mesh()
	var sub_meshes: Array = [{
		"mesh": mesh,
		"material": null,
		"local_transform": Transform3D.IDENTITY,
	}]
	var world_xform := Transform3D(Basis.IDENTITY, Vector3(10, 0, 20))
	registry.add_instance(42, sub_meshes, world_xform, 1.0, 0.3)

	assert_bool(registry.has_instance(42)).is_true()
	var slots: Array = registry.get_instance_slots(42)
	assert_int(slots.size()).is_equal(1)
	assert_int(registry.get_total_live_slots()).is_equal(1)

	_owned_rids.append((slots[0] as RefCounted).batch.rs_instance)
	registry.cleanup()


func test_registry_add_instance_multi_sub_mesh_buildings() -> void:
	var registry: RefCounted = PrototypeRegistryScript.new(_scenario)
	## Simulate a 3-sub-mesh building (e.g. a small canton piece).
	var sub_meshes: Array = [
		{"mesh": _make_mesh(), "material": null, "local_transform": Transform3D.IDENTITY},
		{"mesh": _make_mesh(), "material": null, "local_transform": Transform3D(Basis.IDENTITY, Vector3(0, 5, 0))},
		{"mesh": _make_mesh(), "material": null, "local_transform": Transform3D(Basis.IDENTITY, Vector3(0, 10, 0))},
	]
	registry.add_instance(7, sub_meshes, Transform3D.IDENTITY, 0.0, 0.3)

	var slots: Array = registry.get_instance_slots(7)
	assert_int(slots.size()).is_equal(3)
	assert_int(registry.get_batch_count()).is_equal(3)
	assert_int(registry.get_total_live_slots()).is_equal(3)

	for entry_v: Variant in slots:
		_owned_rids.append((entry_v as RefCounted).batch.rs_instance)
	registry.cleanup()


func test_registry_remove_instance_releases_all_slots() -> void:
	var registry: RefCounted = PrototypeRegistryScript.new(_scenario)
	var sub_meshes: Array = [
		{"mesh": _make_mesh(), "material": null, "local_transform": Transform3D.IDENTITY},
		{"mesh": _make_mesh(), "material": null, "local_transform": Transform3D.IDENTITY},
	]
	registry.add_instance(99, sub_meshes, Transform3D.IDENTITY, 0.0, 0.3)
	assert_int(registry.get_total_live_slots()).is_equal(2)

	var removed: bool = registry.remove_instance(99)
	assert_bool(removed).is_true()
	assert_int(registry.get_total_live_slots()).is_equal(0)
	assert_bool(registry.has_instance(99)).is_false()

	## Idempotent — removing again is a no-op returning false.
	assert_bool(registry.remove_instance(99)).is_false()

	## Free the batches' RS instances for test harness hygiene.
	for b_v: Variant in registry.iter_batches():
		_owned_rids.append((b_v as RefCounted).rs_instance)
	registry.cleanup()


func test_registry_batch_key_stable_for_same_rids() -> void:
	var mesh := _make_mesh()
	var k1: int = PrototypeRegistryScript.batch_key(mesh.get_rid(), RID())
	var k2: int = PrototypeRegistryScript.batch_key(mesh.get_rid(), RID())
	assert_int(k1).is_equal(k2)

#endregion
