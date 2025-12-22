## MeshSimplifierV2 - Improved QEM mesh decimation with proper heap
##
## Performance improvements over v1:
## - Uses binary heap for O(log n) priority queue operations
## - Better memory management
## - More accurate optimal vertex calculation
## - Boundary edge preservation option
class_name MeshSimplifierV2
extends RefCounted

## Minimum triangles to attempt simplification
const MIN_TRIANGLES_FOR_SIMPLIFICATION := 12

## Whether to preserve boundary edges (prevents holes at mesh edges)
var preserve_boundaries: bool = true

## Penalty multiplier for boundary edges
var boundary_penalty: float = 100.0


## Binary heap for efficient priority queue
class BinaryHeap:
	var _data: Array = []  # Array of { cost: float, edge_key: String }
	var _positions: Dictionary = {}  # edge_key -> index in _data

	func is_empty() -> bool:
		return _data.is_empty()

	func size() -> int:
		return _data.size()

	func push(edge_key: String, cost: float) -> void:
		var entry := {"cost": cost, "edge_key": edge_key}
		_data.append(entry)
		var idx := _data.size() - 1
		_positions[edge_key] = idx
		_bubble_up(idx)

	func pop() -> Dictionary:
		if _data.is_empty():
			return {}

		var result: Dictionary = _data[0]
		_positions.erase(result.edge_key)

		if _data.size() > 1:
			_data[0] = _data.back()
			_data.pop_back()
			if not _data.is_empty():
				_positions[_data[0].edge_key] = 0
				_bubble_down(0)
		else:
			_data.pop_back()

		return result

	func update(edge_key: String, new_cost: float) -> void:
		if edge_key not in _positions:
			push(edge_key, new_cost)
			return

		var idx: int = _positions[edge_key]
		var old_cost: float = _data[idx].cost
		_data[idx].cost = new_cost

		if new_cost < old_cost:
			_bubble_up(idx)
		else:
			_bubble_down(idx)

	func remove(edge_key: String) -> void:
		if edge_key not in _positions:
			return

		var idx: int = _positions[edge_key]
		_positions.erase(edge_key)

		if idx == _data.size() - 1:
			_data.pop_back()
			return

		_data[idx] = _data.back()
		_data.pop_back()
		if idx < _data.size():
			_positions[_data[idx].edge_key] = idx
			_bubble_up(idx)
			_bubble_down(idx)

	func has_key(edge_key: String) -> bool:
		return edge_key in _positions

	func _bubble_up(idx: int) -> void:
		while idx > 0:
			var parent := (idx - 1) / 2
			if _data[parent].cost <= _data[idx].cost:
				break
			_swap(parent, idx)
			idx = parent

	func _bubble_down(idx: int) -> void:
		var size := _data.size()
		while true:
			var left := 2 * idx + 1
			var right := 2 * idx + 2
			var smallest := idx

			if left < size and _data[left].cost < _data[smallest].cost:
				smallest = left
			if right < size and _data[right].cost < _data[smallest].cost:
				smallest = right

			if smallest == idx:
				break

			_swap(idx, smallest)
			idx = smallest

	func _swap(a: int, b: int) -> void:
		var temp: Dictionary = _data[a]
		_data[a] = _data[b]
		_data[b] = temp
		_positions[_data[a].edge_key] = a
		_positions[_data[b].edge_key] = b


## Quadric matrix (4x4 symmetric, stored as 10 floats)
class Quadric:
	var a: float = 0.0  # xx
	var b: float = 0.0  # xy
	var c: float = 0.0  # xz
	var d: float = 0.0  # xw
	var e: float = 0.0  # yy
	var f: float = 0.0  # yz
	var g: float = 0.0  # yw
	var h: float = 0.0  # zz
	var i: float = 0.0  # zw
	var j: float = 0.0  # ww

	func add(other: Quadric) -> void:
		a += other.a; b += other.b; c += other.c; d += other.d
		e += other.e; f += other.f; g += other.g
		h += other.h; i += other.i; j += other.j

	func duplicate() -> Quadric:
		var q := Quadric.new()
		q.a = a; q.b = b; q.c = c; q.d = d; q.e = e
		q.f = f; q.g = g; q.h = h; q.i = i; q.j = j
		return q

	func evaluate(v: Vector3) -> float:
		return (a * v.x * v.x + 2.0 * b * v.x * v.y + 2.0 * c * v.x * v.z + 2.0 * d * v.x +
				e * v.y * v.y + 2.0 * f * v.y * v.z + 2.0 * g * v.y +
				h * v.z * v.z + 2.0 * i * v.z + j)

	## Try to find optimal vertex by solving linear system
	func find_optimal_vertex(fallback: Vector3) -> Vector3:
		# Build 3x3 matrix A from quadric
		# [a b c]   [x]   [-d]
		# [b e f] * [y] = [-g]
		# [c f h]   [z]   [-i]

		# Check determinant to see if invertible
		var det := a * (e * h - f * f) - b * (b * h - f * c) + c * (b * f - e * c)
		if absf(det) < 1e-10:
			return fallback

		# Compute inverse using Cramer's rule
		var inv_det := 1.0 / det

		var A11 := (e * h - f * f) * inv_det
		var A12 := (c * f - b * h) * inv_det
		var A13 := (b * f - c * e) * inv_det
		var A22 := (a * h - c * c) * inv_det
		var A23 := (b * c - a * f) * inv_det
		var A33 := (a * e - b * b) * inv_det

		var x := -d * A11 - g * A12 - i * A13
		var y := -d * A12 - g * A22 - i * A23
		var z := -d * A13 - g * A23 - i * A33

		var result := Vector3(x, y, z)

		# Sanity check - optimal should be better than fallback
		if evaluate(result) > evaluate(fallback) * 2.0:
			return fallback

		return result

	static func from_plane(normal: Vector3, point: Vector3) -> Quadric:
		var q := Quadric.new()
		var n := normal.normalized()
		var w := -n.dot(point)

		q.a = n.x * n.x; q.b = n.x * n.y; q.c = n.x * n.z; q.d = n.x * w
		q.e = n.y * n.y; q.f = n.y * n.z; q.g = n.y * w
		q.h = n.z * n.z; q.i = n.z * w; q.j = w * w

		return q


## Edge data
class EdgeData:
	var v1: int
	var v2: int
	var target: Vector3
	var cost: float
	var is_boundary: bool = false


## Simplify mesh arrays to target ratio
func simplify(arrays: Array, target_ratio: float) -> Array:
	if arrays.size() < Mesh.ARRAY_MAX:
		return arrays

	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	if vertices.is_empty() or indices.is_empty():
		return arrays

	var num_triangles := indices.size() / 3
	if num_triangles < MIN_TRIANGLES_FOR_SIMPLIFICATION:
		return arrays

	var target_triangles := maxi(int(num_triangles * target_ratio), 4)

	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] else PackedVector3Array()
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else PackedVector2Array()
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] else PackedColorArray()

	return _simplify_mesh(vertices, indices, normals, uvs, colors, target_triangles)


## Aggressive simplification (95% reduction)
func simplify_aggressive(arrays: Array) -> Array:
	return simplify(arrays, 0.05)


## Internal simplification
func _simplify_mesh(
	vertices: PackedVector3Array,
	indices: PackedInt32Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	target_triangles: int
) -> Array:
	var num_vertices := vertices.size()
	var num_triangles := indices.size() / 3

	# Build quadrics from triangle planes
	var quadrics: Array[Quadric] = []
	quadrics.resize(num_vertices)
	for i in range(num_vertices):
		quadrics[i] = Quadric.new()

	for t in range(num_triangles):
		var i0 := indices[t * 3]
		var i1 := indices[t * 3 + 1]
		var i2 := indices[t * 3 + 2]

		var v0 := vertices[i0]
		var v1 := vertices[i1]
		var v2 := vertices[i2]

		var edge1 := v1 - v0
		var edge2 := v2 - v0
		var normal := edge1.cross(edge2)

		if normal.length_squared() < 1e-10:
			continue

		var q := Quadric.from_plane(normal, v0)
		quadrics[i0].add(q)
		quadrics[i1].add(q)
		quadrics[i2].add(q)

	# Build edge set and identify boundaries
	var edges: Dictionary = {}  # edge_key -> EdgeData
	var edge_count: Dictionary = {}  # edge_key -> count (for boundary detection)
	var vertex_edges: Array[Array] = []
	vertex_edges.resize(num_vertices)
	for i in range(num_vertices):
		vertex_edges[i] = []

	for t in range(num_triangles):
		var i0 := indices[t * 3]
		var i1 := indices[t * 3 + 1]
		var i2 := indices[t * 3 + 2]

		_count_edge(edge_count, i0, i1)
		_count_edge(edge_count, i1, i2)
		_count_edge(edge_count, i2, i0)

	# Create edges with boundary info
	for t in range(num_triangles):
		var i0 := indices[t * 3]
		var i1 := indices[t * 3 + 1]
		var i2 := indices[t * 3 + 2]

		_add_edge(edges, vertex_edges, edge_count, i0, i1, vertices, quadrics)
		_add_edge(edges, vertex_edges, edge_count, i1, i2, vertices, quadrics)
		_add_edge(edges, vertex_edges, edge_count, i2, i0, vertices, quadrics)

	# Build priority queue
	var heap := BinaryHeap.new()
	for key in edges:
		var edge: EdgeData = edges[key]
		heap.push(key, edge.cost)

	# Vertex mapping for collapsed vertices
	var vertex_map: PackedInt32Array = []
	vertex_map.resize(num_vertices)
	for i in range(num_vertices):
		vertex_map[i] = i

	# Active triangles
	var active_triangles: Array[bool] = []
	active_triangles.resize(num_triangles)
	for i in range(num_triangles):
		active_triangles[i] = true

	var current_triangles := num_triangles

	# Collapse edges
	while current_triangles > target_triangles and not heap.is_empty():
		var entry := heap.pop()
		if entry.is_empty():
			break

		var edge_key: String = entry.edge_key
		if edge_key not in edges:
			continue

		var edge: EdgeData = edges[edge_key]
		var v1 := _get_root_vertex(vertex_map, edge.v1)
		var v2 := _get_root_vertex(vertex_map, edge.v2)

		if v1 == v2:
			continue  # Already collapsed

		# Collapse v2 into v1
		vertices[v1] = edge.target

		# Interpolate attributes
		if not uvs.is_empty() and v1 < uvs.size() and v2 < uvs.size():
			uvs[v1] = (uvs[v1] + uvs[v2]) * 0.5
		if not colors.is_empty() and v1 < colors.size() and v2 < colors.size():
			colors[v1] = (colors[v1] + colors[v2]) * 0.5

		# Update quadric
		quadrics[v1].add(quadrics[v2])

		# Map v2 to v1
		vertex_map[v2] = v1

		# Update triangles
		var triangles_removed := 0
		for t in range(num_triangles):
			if not active_triangles[t]:
				continue

			var ti0 := _get_root_vertex(vertex_map, indices[t * 3])
			var ti1 := _get_root_vertex(vertex_map, indices[t * 3 + 1])
			var ti2 := _get_root_vertex(vertex_map, indices[t * 3 + 2])

			indices[t * 3] = ti0
			indices[t * 3 + 1] = ti1
			indices[t * 3 + 2] = ti2

			if ti0 == ti1 or ti1 == ti2 or ti2 == ti0:
				active_triangles[t] = false
				triangles_removed += 1

		current_triangles -= triangles_removed

		# Remove edges involving v2
		for edge_key_v2 in vertex_edges[v2]:
			heap.remove(edge_key_v2)
			edges.erase(edge_key_v2)

		# Update edges involving v1
		for edge_key_v1 in vertex_edges[v1]:
			if edge_key_v1 not in edges:
				continue
			var e: EdgeData = edges[edge_key_v1]
			var ev1 := _get_root_vertex(vertex_map, e.v1)
			var ev2 := _get_root_vertex(vertex_map, e.v2)
			if ev1 != ev2:
				_compute_edge_cost(e, ev1, ev2, vertices, quadrics)
				heap.update(edge_key_v1, e.cost)

	# Build output
	return _build_output_arrays(vertices, indices, normals, uvs, colors, vertex_map, active_triangles)


func _count_edge(edge_count: Dictionary, v1: int, v2: int) -> void:
	if v1 > v2:
		var tmp := v1; v1 = v2; v2 = tmp
	var key := "%d_%d" % [v1, v2]
	edge_count[key] = edge_count.get(key, 0) + 1


func _add_edge(
	edges: Dictionary,
	vertex_edges: Array[Array],
	edge_count: Dictionary,
	v1: int,
	v2: int,
	vertices: PackedVector3Array,
	quadrics: Array[Quadric]
) -> void:
	if v1 > v2:
		var tmp := v1; v1 = v2; v2 = tmp

	var key := "%d_%d" % [v1, v2]
	if edges.has(key):
		return

	var edge := EdgeData.new()
	edge.v1 = v1
	edge.v2 = v2
	edge.is_boundary = edge_count.get(key, 0) == 1

	_compute_edge_cost(edge, v1, v2, vertices, quadrics)

	edges[key] = edge
	vertex_edges[v1].append(key)
	vertex_edges[v2].append(key)


func _compute_edge_cost(
	edge: EdgeData,
	v1: int,
	v2: int,
	vertices: PackedVector3Array,
	quadrics: Array[Quadric]
) -> void:
	var p1 := vertices[v1]
	var p2 := vertices[v2]
	var q := quadrics[v1].duplicate()
	q.add(quadrics[v2])

	# Try optimal vertex first
	var midpoint := (p1 + p2) * 0.5
	var optimal := q.find_optimal_vertex(midpoint)

	# Evaluate candidates and pick best
	var candidates := [p1, p2, midpoint, optimal]
	var best_cost := INF
	var best_point := midpoint

	for point in candidates:
		var cost := q.evaluate(point)
		if cost < best_cost:
			best_cost = cost
			best_point = point

	edge.target = best_point
	edge.cost = best_cost

	# Apply boundary penalty
	if edge.is_boundary and preserve_boundaries:
		edge.cost *= boundary_penalty

	edge.v1 = v1
	edge.v2 = v2


func _get_root_vertex(vertex_map: PackedInt32Array, v: int) -> int:
	while vertex_map[v] != v:
		v = vertex_map[v]
	return v


func _build_output_arrays(
	vertices: PackedVector3Array,
	indices: PackedInt32Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	vertex_map: PackedInt32Array,
	active_triangles: Array[bool]
) -> Array:
	var used_vertices: Dictionary = {}
	var new_indices: PackedInt32Array = []

	var num_triangles := active_triangles.size()
	for t in range(num_triangles):
		if not active_triangles[t]:
			continue

		var i0 := _get_root_vertex(vertex_map, indices[t * 3])
		var i1 := _get_root_vertex(vertex_map, indices[t * 3 + 1])
		var i2 := _get_root_vertex(vertex_map, indices[t * 3 + 2])

		if i0 == i1 or i1 == i2 or i2 == i0:
			continue

		used_vertices[i0] = true
		used_vertices[i1] = true
		used_vertices[i2] = true

		new_indices.append(i0)
		new_indices.append(i1)
		new_indices.append(i2)

	if new_indices.is_empty():
		return []

	# Build compact arrays
	var vertex_remap: Dictionary = {}
	var new_vertices: PackedVector3Array = []
	var new_normals: PackedVector3Array = []
	var new_uvs: PackedVector2Array = []
	var new_colors: PackedColorArray = []

	var new_idx := 0
	for old_idx in used_vertices:
		vertex_remap[old_idx] = new_idx
		new_vertices.append(vertices[old_idx])

		if not normals.is_empty() and old_idx < normals.size():
			new_normals.append(normals[old_idx])
		if not uvs.is_empty() and old_idx < uvs.size():
			new_uvs.append(uvs[old_idx])
		if not colors.is_empty() and old_idx < colors.size():
			new_colors.append(colors[old_idx])

		new_idx += 1

	# Remap indices
	var final_indices: PackedInt32Array = []
	for i in range(new_indices.size()):
		final_indices.append(vertex_remap[new_indices[i]])

	# Recalculate normals
	if not new_normals.is_empty():
		new_normals = _recalculate_normals(new_vertices, final_indices)

	# Build output
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = new_vertices
	arrays[Mesh.ARRAY_INDEX] = final_indices

	if not new_normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = new_normals
	if not new_uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = new_uvs
	if not new_colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = new_colors

	return arrays


func _recalculate_normals(vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals: PackedVector3Array = []
	normals.resize(vertices.size())

	for i in range(normals.size()):
		normals[i] = Vector3.ZERO

	var num_triangles := indices.size() / 3
	for t in range(num_triangles):
		var i0 := indices[t * 3]
		var i1 := indices[t * 3 + 1]
		var i2 := indices[t * 3 + 2]

		var v0 := vertices[i0]
		var v1 := vertices[i1]
		var v2 := vertices[i2]

		var edge1 := v1 - v0
		var edge2 := v2 - v0
		var face_normal := edge1.cross(edge2)

		normals[i0] += face_normal
		normals[i1] += face_normal
		normals[i2] += face_normal

	for i in range(normals.size()):
		if normals[i].length_squared() > 1e-10:
			normals[i] = normals[i].normalized()
		else:
			normals[i] = Vector3.UP

	return normals
