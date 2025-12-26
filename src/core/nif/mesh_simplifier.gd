## MeshSimplifier - Quadric Error Metrics based mesh decimation
##
## Simplifies meshes by iteratively collapsing edges with lowest error cost.
## Preserves UV coordinates and vertex colors through interpolation.
##
## Usage:
##   var simplifier := MeshSimplifier.new()
##   var simplified_arrays := simplifier.simplify(original_arrays, 0.5)  # 50% triangles
class_name MeshSimplifier
extends RefCounted


## Minimum triangles to attempt simplification (skip very simple meshes)
const MIN_TRIANGLES_FOR_SIMPLIFICATION := 12

## Quadric matrix (4x4 symmetric) stored as 10 floats
## Represents the sum of squared distances to planes
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
		a += other.a
		b += other.b
		c += other.c
		d += other.d
		e += other.e
		f += other.f
		g += other.g
		h += other.h
		i += other.i
		j += other.j

	func duplicate() -> Quadric:
		var q := Quadric.new()
		q.a = a; q.b = b; q.c = c; q.d = d; q.e = e
		q.f = f; q.g = g; q.h = h; q.i = i; q.j = j
		return q

	## Evaluate quadric error at point v
	func evaluate(v: Vector3) -> float:
		return (a * v.x * v.x + 2.0 * b * v.x * v.y + 2.0 * c * v.x * v.z + 2.0 * d * v.x +
				e * v.y * v.y + 2.0 * f * v.y * v.z + 2.0 * g * v.y +
				h * v.z * v.z + 2.0 * i * v.z + j)

	## Create quadric from plane equation ax + by + cz + d = 0
	static func from_plane(normal: Vector3, point: Vector3) -> Quadric:
		var q := Quadric.new()
		var n := normal.normalized()
		var w := -n.dot(point)

		q.a = n.x * n.x
		q.b = n.x * n.y
		q.c = n.x * n.z
		q.d = n.x * w
		q.e = n.y * n.y
		q.f = n.y * n.z
		q.g = n.y * w
		q.h = n.z * n.z
		q.i = n.z * w
		q.j = w * w

		return q


## Edge collapse candidate
class EdgeCollapse:
	var v1: int  # First vertex index
	var v2: int  # Second vertex index
	var target: Vector3  # Optimal collapse point
	var cost: float  # Error cost
	var valid: bool = true

	func _init(vertex1: int, vertex2: int) -> void:
		v1 = vertex1
		v2 = vertex2


## Simplify mesh arrays to target triangle ratio
## Returns new arrays with simplified geometry, or original if simplification fails
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

	var target_triangles := int(num_triangles * target_ratio)
	target_triangles = maxi(target_triangles, 4)  # Keep at least 4 triangles

	# Get optional attributes
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] else PackedVector3Array()
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else PackedVector2Array()
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] else PackedColorArray()

	# Run simplification
	var result := _simplify_mesh(vertices, indices, normals, uvs, colors, target_triangles)

	if result.is_empty():
		return arrays

	return result


## Aggressive simplification for distant rendering (95% polygon reduction)
## Used by MID tier (500m-2km) for merged static meshes.
## Strips most detail while preserving overall silhouette.
## Returns simplified arrays, or original if mesh is already very simple.
func simplify_aggressive(arrays: Array) -> Array:
	return simplify(arrays, 0.05)  # 5% of original = 95% reduction


## Simplify to specific vertex count (useful for impostor LODs)
## Returns simplified arrays, or original if target cannot be achieved
func simplify_to_vertex_count(arrays: Array, max_vertices: int) -> Array:
	if arrays.size() < Mesh.ARRAY_MAX:
		return arrays

	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if vertices.size() <= max_vertices:
		return arrays  # Already under limit

	# Calculate ratio to achieve target vertex count
	var ratio := float(max_vertices) / float(vertices.size())
	return simplify(arrays, ratio)


## Internal simplification algorithm
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

	# Build vertex quadrics from incident triangles
	var quadrics: Array[Quadric] = []
	quadrics.resize(num_vertices)
	for i in range(num_vertices):
		quadrics[i] = Quadric.new()

	# Compute quadrics from triangle planes
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

		if normal.length_squared() < 0.0000001:
			continue

		var q := Quadric.from_plane(normal, v0)
		quadrics[i0].add(q)
		quadrics[i1].add(q)
		quadrics[i2].add(q)

	# Build edge set and collapse candidates
	var edges: Dictionary = {}  # "v1_v2" -> EdgeCollapse
	var vertex_edges: Array[Array] = []  # vertex_index -> [edge_keys]
	vertex_edges.resize(num_vertices)
	for i in range(num_vertices):
		vertex_edges[i] = []

	for t in range(num_triangles):
		var i0 := indices[t * 3]
		var i1 := indices[t * 3 + 1]
		var i2 := indices[t * 3 + 2]

		_add_edge(edges, vertex_edges, i0, i1, vertices, quadrics)
		_add_edge(edges, vertex_edges, i1, i2, vertices, quadrics)
		_add_edge(edges, vertex_edges, i2, i0, vertices, quadrics)

	# Track which vertices are collapsed (maps to replacement vertex)
	var vertex_map: PackedInt32Array = []
	vertex_map.resize(num_vertices)
	for i in range(num_vertices):
		vertex_map[i] = i

	# Track active triangles
	var active_triangles: Array[bool] = []
	active_triangles.resize(num_triangles)
	for i in range(num_triangles):
		active_triangles[i] = true

	var current_triangles := num_triangles

	# Create priority queue (simple sorted array for now)
	var collapse_queue: Array[EdgeCollapse] = []
	for key: int in edges:
		collapse_queue.append(edges[key])
	collapse_queue.sort_custom(func(a: Variant, b: Variant) -> bool: return a.cost < b.cost)

	# Iteratively collapse edges
	while current_triangles > target_triangles and not collapse_queue.is_empty():
		# Find lowest cost valid collapse
		var collapse: EdgeCollapse = null
		while not collapse_queue.is_empty():
			var candidate: EdgeCollapse = collapse_queue.pop_front()
			if candidate.valid:
				# Check vertices still exist
				var rv1 := _get_root_vertex(vertex_map, candidate.v1)
				var rv2 := _get_root_vertex(vertex_map, candidate.v2)
				if rv1 != rv2:
					collapse = candidate
					collapse.v1 = rv1
					collapse.v2 = rv2
					break

		if not collapse:
			break

		# Perform collapse: merge v2 into v1
		var v1 := collapse.v1
		var v2 := collapse.v2

		# Update vertex position to optimal point
		vertices[v1] = collapse.target

		# Interpolate attributes
		if not uvs.is_empty():
			uvs[v1] = (uvs[v1] + uvs[v2]) * 0.5
		if not colors.is_empty():
			colors[v1] = (colors[v1] + colors[v2]) * 0.5

		# Update quadric
		quadrics[v1].add(quadrics[v2])

		# Map v2 to v1
		vertex_map[v2] = v1

		# Update triangles and count removed
		var triangles_removed := 0
		for t in range(num_triangles):
			if not active_triangles[t]:
				continue

			var i0 := _get_root_vertex(vertex_map, indices[t * 3])
			var i1 := _get_root_vertex(vertex_map, indices[t * 3 + 1])
			var i2 := _get_root_vertex(vertex_map, indices[t * 3 + 2])

			# Update indices
			indices[t * 3] = i0
			indices[t * 3 + 1] = i1
			indices[t * 3 + 2] = i2

			# Check for degenerate triangle
			if i0 == i1 or i1 == i2 or i2 == i0:
				active_triangles[t] = false
				triangles_removed += 1

		current_triangles -= triangles_removed

		# Invalidate edges involving v2 and update edges involving v1
		for key: int in vertex_edges[v2]:
			if edges.has(key):
				edges[key].valid = false

		# Recompute costs for edges involving v1
		for key: int in vertex_edges[v1]:
			if edges.has(key) and edges[key].valid:
				var edge: EdgeCollapse = edges[key]
				var ev1 := _get_root_vertex(vertex_map, edge.v1)
				var ev2 := _get_root_vertex(vertex_map, edge.v2)
				if ev1 != ev2:
					_compute_edge_cost(edge, ev1, ev2, vertices, quadrics)
					# Re-add to queue with new cost
					collapse_queue.append(edge)

		# Resort queue periodically
		if collapse_queue.size() > 100:
			collapse_queue.sort_custom(func(a: Variant, b: Variant) -> bool: return a.cost < b.cost)

	# Build output arrays
	return _build_output_arrays(vertices, indices, normals, uvs, colors, vertex_map, active_triangles)


## Create integer key for edge (faster than string formatting)
## Uses Cantor pairing function for unique key from two ordered integers
func _make_edge_key(v1: int, v2: int) -> int:
	# Ensure v1 <= v2 for consistent key
	if v1 > v2:
		var tmp := v1
		v1 = v2
		v2 = tmp
	# Cantor pairing: maps (v1, v2) to unique integer
	# For meshes < 65536 vertices, simple bit packing works too
	return (v1 << 20) | v2  # Supports up to ~1M vertices each


## Add edge to edge set
func _add_edge(
	edges: Dictionary,
	vertex_edges: Array[Array],
	v1: int,
	v2: int,
	vertices: PackedVector3Array,
	quadrics: Array[Quadric]
) -> void:
	if v1 > v2:
		var tmp := v1
		v1 = v2
		v2 = tmp

	var key := _make_edge_key(v1, v2)
	if edges.has(key):
		return

	var edge := EdgeCollapse.new(v1, v2)
	_compute_edge_cost(edge, v1, v2, vertices, quadrics)

	edges[key] = edge
	vertex_edges[v1].append(key)
	vertex_edges[v2].append(key)


## Compute optimal collapse point and cost for an edge
func _compute_edge_cost(
	edge: EdgeCollapse,
	v1: int,
	v2: int,
	vertices: PackedVector3Array,
	quadrics: Array[Quadric]
) -> void:
	var p1 := vertices[v1]
	var p2 := vertices[v2]
	var q1 := quadrics[v1]
	var q2 := quadrics[v2]

	# Combined quadric
	var q := q1.duplicate()
	q.add(q2)

	# Try to find optimal point by solving the linear system
	# For simplicity, we test midpoint and endpoints and pick best
	var midpoint: Vector3 = (p1 + p2) * 0.5
	var candidates: Array[Vector3] = [p1, p2, midpoint]

	var best_cost := INF
	var best_point: Vector3 = midpoint

	for point: Vector3 in candidates:
		var cost := q.evaluate(point)
		if cost < best_cost:
			best_cost = cost
			best_point = point

	edge.target = best_point
	edge.cost = best_cost
	edge.v1 = v1
	edge.v2 = v2


## Get root vertex following collapse chain
func _get_root_vertex(vertex_map: PackedInt32Array, v: int) -> int:
	while vertex_map[v] != v:
		v = vertex_map[v]
	return v


## Build output arrays after simplification
func _build_output_arrays(
	vertices: PackedVector3Array,
	indices: PackedInt32Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	vertex_map: PackedInt32Array,
	active_triangles: Array[bool]
) -> Array:
	# Collect unique vertices and build remapping
	var used_vertices: Dictionary = {}
	var new_indices: PackedInt32Array = []

	var num_triangles := active_triangles.size()
	for t in range(num_triangles):
		if not active_triangles[t]:
			continue

		var i0 := _get_root_vertex(vertex_map, indices[t * 3])
		var i1 := _get_root_vertex(vertex_map, indices[t * 3 + 1])
		var i2 := _get_root_vertex(vertex_map, indices[t * 3 + 2])

		# Skip degenerate
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

	# Build compact vertex arrays
	var vertex_remap: Dictionary = {}
	var new_vertices: PackedVector3Array = []
	var new_normals: PackedVector3Array = []
	var new_uvs: PackedVector2Array = []
	var new_colors: PackedColorArray = []

	var new_idx := 0
	for old_idx: Variant in used_vertices:
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
		var remapped_idx: int = vertex_remap[new_indices[i]]
		final_indices.append(remapped_idx)

	# Recalculate normals if we had them
	if not new_normals.is_empty():
		new_normals = _recalculate_normals(new_vertices, final_indices)

	# Build output arrays
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


## Recalculate smooth normals from geometry
func _recalculate_normals(vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals: PackedVector3Array = []
	normals.resize(vertices.size())

	# Initialize to zero
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO

	# Accumulate face normals
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

		# Weight by triangle area (face_normal length is 2x area)
		normals[i0] += face_normal
		normals[i1] += face_normal
		normals[i2] += face_normal

	# Normalize
	for i in range(normals.size()):
		if normals[i].length_squared() > 0.0000001:
			normals[i] = normals[i].normalized()
		else:
			normals[i] = Vector3.UP

	return normals
