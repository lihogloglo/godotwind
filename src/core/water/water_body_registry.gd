class_name WaterBodyRegistry
extends RefCounted

const ACTIVE_COVERAGE_EPSILON := 0.001

var _bodies: Array[RefCounted] = []
var _providers: Array[RefCounted] = []
var _bounds_reject_count: int = 0
var _coverage_sample_count: int = 0


func register_body(body: RefCounted) -> Error:
	if body == null:
		return ERR_INVALID_PARAMETER
	unregister_body_id(body.body_id)
	_bodies.append(body)
	_sort_sources()
	return OK


func unregister_body(body: RefCounted) -> void:
	if body == null:
		return
	var index := _bodies.find(body)
	if index >= 0:
		_bodies.remove_at(index)


func unregister_body_id(body_id: StringName) -> void:
	for i in range(_bodies.size() - 1, -1, -1):
		if _bodies[i].body_id == body_id:
			_bodies.remove_at(i)


func register_provider(provider: RefCounted) -> Error:
	if provider == null:
		return ERR_INVALID_PARAMETER
	unregister_provider(provider)
	_providers.append(provider)
	_sort_sources()
	return OK


func unregister_provider(provider: RefCounted) -> void:
	var index := _providers.find(provider)
	if index >= 0:
		_providers.remove_at(index)


func clear() -> void:
	_bodies.clear()
	_providers.clear()
	_bounds_reject_count = 0
	_coverage_sample_count = 0


func has_sources() -> bool:
	return not _bodies.is_empty() or not _providers.is_empty()


func get_body_count() -> int:
	return _bodies.size()


func get_provider_count() -> int:
	return _providers.size()


func get_stats() -> Dictionary:
	return {
		"body_count": _bodies.size(),
		"provider_count": _providers.size(),
		"coverage_sample_count": _coverage_sample_count,
		"bounds_reject_count": _bounds_reject_count,
	}


func get_best_candidate(world_pos: Vector3) -> Dictionary:
	var best: Dictionary = {}

	for body: RefCounted in _bodies:
		if _source_bounds_rejects_xz(body, world_pos):
			_bounds_reject_count += 1
			continue
		var coverage: float = 0.0
		if body.has_method("sample_coverage"):
			_coverage_sample_count += 1
			coverage = clampf(float(body.call("sample_coverage", world_pos)), 0.0, 1.0)
		if coverage <= ACTIVE_COVERAGE_EPSILON:
			continue
		var body_id := _get_source_body_id(body)
		best = _choose_better(best, {
			"source_kind": &"body",
			"source": body,
			"coverage": coverage,
			"priority": _get_source_priority(body),
			"body_id": _sample_source_body_id(body, world_pos, body_id),
		})

	for provider: RefCounted in _providers:
		if _source_bounds_rejects_xz(provider, world_pos):
			_bounds_reject_count += 1
			continue
		if not provider.has_method("sample_coverage"):
			continue
		_coverage_sample_count += 1
		var coverage: float = clampf(float(provider.call("sample_coverage", world_pos)), 0.0, 1.0)
		if coverage <= ACTIVE_COVERAGE_EPSILON:
			continue
		var provider_priority := _get_source_priority(provider, 100)
		var body_id := WaterSurfaceState.WATER_BODY_NONE
		if provider.has_method("sample_water_body_id"):
			var id_result: Variant = provider.call("sample_water_body_id", world_pos, WaterSurfaceState.WATER_BODY_NONE)
			if id_result is StringName:
				body_id = id_result
			elif id_result is String:
				body_id = StringName(id_result)
		best = _choose_better(best, {
			"source_kind": &"provider",
			"source": provider,
			"coverage": coverage,
			"priority": provider_priority,
			"body_id": body_id,
		})

	return best


func sample_coverage(world_pos: Vector3, fallback: float = 0.0) -> float:
	var candidate := get_best_candidate(world_pos)
	if candidate.is_empty():
		return fallback
	return float(candidate.get("coverage", fallback))


func sample_height(world_pos: Vector3, fallback: float = NAN) -> float:
	var candidate := get_best_candidate(world_pos)
	if candidate.is_empty():
		return fallback
	var source: Variant = candidate["source"]
	if candidate["source_kind"] == &"body":
		return float(source.call("sample_height", world_pos, fallback))
	if source is RefCounted and source.has_method("sample_height"):
		return float(source.call("sample_height", world_pos, fallback))
	return fallback


func sample_normal(world_pos: Vector3, fallback: Vector3 = Vector3.UP) -> Vector3:
	var candidate := get_best_candidate(world_pos)
	if candidate.is_empty():
		return fallback
	var source: Variant = candidate["source"]
	if candidate["source_kind"] == &"body":
		var result: Variant = source.call("sample_normal", world_pos, fallback)
		if result is Vector3:
			return result
		return fallback
	if source is RefCounted and source.has_method("sample_normal"):
		var result: Variant = source.call("sample_normal", world_pos, fallback)
		if result is Vector3:
			return result
	return fallback


func sample_gradient(world_pos: Vector3, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	var candidate := get_best_candidate(world_pos)
	if candidate.is_empty():
		return fallback
	var source: Variant = candidate["source"]
	if candidate["source_kind"] == &"body":
		var result: Variant = source.call("sample_gradient", world_pos, fallback)
		if result is Vector2:
			return result
		return fallback
	if source is RefCounted and source.has_method("sample_gradient"):
		var result: Variant = source.call("sample_gradient", world_pos, fallback)
		if result is Vector2:
			return result
	return fallback


func sample_velocity(world_pos: Vector3, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	var candidate := get_best_candidate(world_pos)
	if candidate.is_empty():
		return fallback
	var source: Variant = candidate["source"]
	if candidate["source_kind"] == &"body":
		var result: Variant = source.call("sample_velocity", world_pos, fallback)
		if result is Vector3:
			return result
		return fallback
	if source is RefCounted and source.has_method("sample_velocity"):
		var result: Variant = source.call("sample_velocity", world_pos, fallback)
		if result is Vector3:
			return result
	return fallback


func sample_water_body_id(world_pos: Vector3, fallback: StringName = WaterSurfaceState.WATER_BODY_NONE) -> StringName:
	var candidate := get_best_candidate(world_pos)
	if candidate.is_empty():
		return fallback
	var body_id: Variant = candidate.get("body_id", fallback)
	if body_id is StringName:
		return body_id
	if body_id is String:
		return StringName(body_id)
	return fallback


func sample_surface_query(world_pos: Vector3) -> Dictionary:
	var candidate := get_best_candidate(world_pos)
	if candidate.is_empty():
		return {}
	var source: Variant = candidate["source"]
	var height := NAN
	var normal := Vector3.UP
	var gradient := Vector2.ZERO
	var velocity := Vector3.ZERO
	if source is RefCounted:
		if source.has_method("sample_height"):
			height = float(source.call("sample_height", world_pos, NAN))
		if source.has_method("sample_normal"):
			var normal_v: Variant = source.call("sample_normal", world_pos, Vector3.UP)
			if normal_v is Vector3:
				normal = normal_v.normalized()
		if source.has_method("sample_gradient"):
			var gradient_v: Variant = source.call("sample_gradient", world_pos, Vector2.ZERO)
			if gradient_v is Vector2:
				gradient = gradient_v
		if source.has_method("sample_velocity"):
			var velocity_v: Variant = source.call("sample_velocity", world_pos, Vector3.ZERO)
			if velocity_v is Vector3:
				velocity = velocity_v
	return {
		"height": height,
		"normal": normal,
		"gradient": gradient,
		"velocity": velocity,
		"coverage": float(candidate.get("coverage", 0.0)),
		"body_gate": WaterSurfaceState.coverage_to_body_gate_static(float(candidate.get("coverage", 0.0))),
		"depth": height - world_pos.y if not is_nan(height) else -INF,
		"displacement": Vector3.ZERO,
		"water_body_id": candidate.get("body_id", WaterSurfaceState.WATER_BODY_NONE),
		"has_water_body": true,
		"coverage_source": &"water_body_registry",
	}


func _choose_better(current: Dictionary, challenger: Dictionary) -> Dictionary:
	if current.is_empty():
		return challenger
	var current_priority := int(current.get("priority", 0))
	var challenger_priority := int(challenger.get("priority", 0))
	if challenger_priority > current_priority:
		return challenger
	if challenger_priority < current_priority:
		return current
	var current_coverage := float(current.get("coverage", 0.0))
	var challenger_coverage := float(challenger.get("coverage", 0.0))
	return challenger if challenger_coverage > current_coverage else current


func _sort_sources() -> void:
	_bodies.sort_custom(func(a: RefCounted, b: RefCounted) -> bool:
		return _get_source_priority(a) > _get_source_priority(b)
	)
	_providers.sort_custom(func(a: RefCounted, b: RefCounted) -> bool:
		var pa := _get_source_priority(a, 100)
		var pb := _get_source_priority(b, 100)
		return pa > pb
	)


func _source_bounds_rejects_xz(source: RefCounted, world_pos: Vector3) -> bool:
	var bounds_valid_v: Variant = source.get("bounds_valid")
	if bounds_valid_v == null or not bool(bounds_valid_v):
		return false
	var bounds_v: Variant = source.get("bounds")
	if not bounds_v is AABB:
		return false
	var bounds := bounds_v as AABB
	return world_pos.x < bounds.position.x \
		or world_pos.x > bounds.position.x + bounds.size.x \
		or world_pos.z < bounds.position.z \
		or world_pos.z > bounds.position.z + bounds.size.z


func _get_source_priority(source: RefCounted, fallback: int = 0) -> int:
	var value: Variant = source.get("priority")
	if value == null:
		return fallback
	return int(value)


func _get_source_body_id(source: RefCounted) -> StringName:
	var value: Variant = source.get("body_id")
	if value is StringName:
		return value
	if value is String:
		return StringName(value)
	return WaterSurfaceState.WATER_BODY_NONE


func _sample_source_body_id(source: RefCounted, world_pos: Vector3, fallback: StringName) -> StringName:
	if not source.has_method("sample_water_body_id"):
		return fallback
	var value: Variant = source.call("sample_water_body_id", world_pos, fallback)
	if value is StringName:
		return value
	if value is String:
		return StringName(value)
	return fallback
