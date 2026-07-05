extends Node

## CHUNK tier offline baker (Phase 2 revised, 2026-07-05).
## Plan: docs/plans/distant_rendering_recovery_2026_07.md.
##
## Bakes 2×2-cell merged + simplified chunk proxies for the 400-1200m ring —
## the MGE XE / OpenMW pattern: merged low-poly REAL geometry, min-size gate,
## LOD chain at bake time, one RS instance per chunk at runtime.
##
## Reuses the battle-tested pieces of the (deprecated) runtime HLOD:
## `ObjectPagingKernel.merge_refs` (C# material-grouped merge) and
## `ObjectPagingKernel.generate_lods` (ImporterMesh/meshoptimizer chain).
## Offline-only — no runtime generation (project rule).
##
## Launch (full worldspace):
##   godot --path . res://src/tools/prebaking/chunk_proxy_bake_runner.tscn
## Test region (inclusive cell bounds):
##   ... -- --chunk-bake-region=-4,-12,2,-6
## Auto-quits: exit 0 = success, 1 = failure.

@warning_ignore("untyped_declaration", "unsafe_method_access")

const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")
const WorldObjectSourceScript := preload("res://src/core/world/morrowind/morrowind_world_object_source.gd")
const PagingKernel := preload("res://src/core/world/object_paging_kernel.gd")
const DU := preload("res://src/core/world/distance_utils.gd")

## Chunk edge in cells (2×2 to start; measure before adding adaptive sizes).
const CHUNK_CELLS := 2

## Min-size gate: OpenMW's `object paging min size` ratio (0.01 = radius must
## be ≥ 1% of viewing distance) evaluated at the ring's NEAR edge. At
## CHUNK_START=400m this keeps objects with world radius ≥ 4m — the MGE XE
## "skip smaller meshes" rule. Provenance: openmw.readthedocs.io Terrain
## Settings (verified 2026-07-05 in the distant-rendering audit).
const MIN_SIZE_RATIO := 0.01

var _model_submesh_cache: Dictionary = {}  # model_path -> Array of sub-mesh dicts
var _model_radius_cache: Dictionary = {}   # model_path -> float (prototype-space radius)

## Shared material library (bake v2). Baked model .res files embed their
## textures as sub-resources, so saving merged chunks re-embedded every
## texture into every chunk (~5.5 MB/chunk, ~90% of it raw duplicate
## ImageTextures — diagnosed 2026-07-05). Materials are deduped by
## albedo-image hash into standalone .res files (textures GPU-compressed via
## PortableCompressedTexture2D S3TC — desktop target per 4.6 docs); chunks
## then reference them EXTERNALLY. Dedup runs BEFORE the merge so the
## kernel's material grouping collapses same-texture surfaces across models
## (also relieves the 64-surface cap).
var _material_library: Dictionary = {}  # dedup key -> shared Material (with resource_path)
var _materials_dir: String = ""
var _material_seq: int = 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Chunk bake: loading game data...")
	var loading := LoadingScreenScript.new()
	add_child(loading)
	var ok: bool = await loading.load_game_data()
	loading.queue_free()
	if not ok:
		push_error("Chunk bake failed: game data did not load")
		get_tree().quit(1)
		return
	print("Chunk bake: game data loaded")

	var esm: Node = get_node_or_null("/root/ESMManager")
	var settings: Node = get_node_or_null("/root/SettingsManager")
	if esm == null or settings == null:
		push_error("Chunk bake failed: autoloads unavailable")
		get_tree().quit(1)
		return

	var out_dir: String = settings.call("get_cache_base_path").path_join("chunks")
	var mkdir_err := DirAccess.make_dir_recursive_absolute(out_dir)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		push_error("Chunk bake failed: cannot create %s" % out_dir)
		get_tree().quit(1)
		return
	_materials_dir = out_dir.path_join("materials")
	DirAccess.make_dir_recursive_absolute(_materials_dir)

	# Optional region filter for test bakes.
	var region := Rect2i(-1000000, -1000000, 2000000, 2000000)
	for arg in Array(OS.get_cmdline_user_args()) + Array(OS.get_cmdline_args()):
		var s := str(arg)
		if s.begins_with("--chunk-bake-region="):
			var p := s.get_slice("=", 1).split(",")
			if p.size() == 4:
				var x0 := int(p[0])
				var y0 := int(p[1])
				region = Rect2i(x0, y0, int(p[2]) - x0 + 1, int(p[3]) - y0 + 1)

	var source := WorldObjectSourceScript.new()

	# Group exterior cells into chunks (floor-divide grid by CHUNK_CELLS).
	var chunks: Dictionary = {}  # Vector2i chunk key -> Array[Vector2i] cells
	for key_variant in (esm.get("exterior_cells") as Dictionary).keys():
		var parts: PackedStringArray = str(key_variant).split(",")
		if parts.size() != 2:
			continue
		var grid := Vector2i(int(parts[0]), int(parts[1]))
		if not region.has_point(grid):
			continue
		var chunk_key := Vector2i(floori(float(grid.x) / CHUNK_CELLS), floori(float(grid.y) / CHUNK_CELLS))
		if chunk_key not in chunks:
			chunks[chunk_key] = [] as Array[Vector2i]
		(chunks[chunk_key] as Array).append(grid)

	var min_radius := MIN_SIZE_RATIO * DU.CHUNK_START
	var start_ms := Time.get_ticks_msec()
	var index := {}  # "cx,cy" -> {path, aabb fields, refs, surfaces}
	var baked := 0
	var empty := 0
	var failed := 0
	var total_bytes := 0
	var total_refs := 0
	var total_verts := 0
	var chunk_keys: Array = chunks.keys()

	for ci in chunk_keys.size():
		var chunk_key: Vector2i = chunk_keys[ci]
		print("Chunk bake: starting chunk %d/%d %s (materials=%d, models=%d)" % [
			ci + 1, chunk_keys.size(), chunk_key, _material_library.size(), _model_submesh_cache.size()])
		var chunk_origin: Vector3 = DU.cell_to_world_origin(Vector2i(chunk_key.x * CHUNK_CELLS, chunk_key.y * CHUNK_CELLS))
		var inputs: Array = []

		for grid: Vector2i in chunks[chunk_key]:
			var manifest: RefCounted = source.get_cell_manifest(grid)
			if manifest == null:
				continue
			for record in (manifest.objects as Array):
				if not record.static_batch_allowed or record.model_path.is_empty():
					continue
				var sub_meshes: Array = _get_model_submeshes(record.model_path)
				if sub_meshes.is_empty():
					continue
				var radius: float = _model_radius_cache.get(record.model_path.to_lower(), 0.0)
				var scale_max: float = maxf(record.scale_scalar, 0.01)
				if radius * scale_max < min_radius:
					continue
				var input := PagingKernel.RefInput.new()
				input.ref_transform = record.transform
				input.sub_meshes = _to_submesh_inputs(sub_meshes)
				input.source_object_id = record.object_id
				input.surface_count = sub_meshes.size()
				inputs.append(input)

		if inputs.is_empty():
			empty += 1
			source.clear_cache()
			continue

		var merged: ArrayMesh = PagingKernel.merge_refs(inputs, chunk_origin, 1, true)
		if merged == null:
			empty += 1
			source.clear_cache()
			continue
		var final_mesh: ArrayMesh = _finalize_with_lods(merged)

		var out_path := out_dir.path_join("chunk_%d_%d.res" % [chunk_key.x, chunk_key.y])
		var save_err := ResourceSaver.save(final_mesh, out_path, ResourceSaver.FLAG_COMPRESS)
		if save_err != OK:
			push_error("Chunk bake failed to save %s: %s" % [out_path, error_string(save_err)])
			failed += 1
		else:
			baked += 1
			total_refs += inputs.size()
			total_bytes += FileAccess.get_file_as_bytes(out_path).size()
			var aabb := final_mesh.get_aabb()
			var stats: Dictionary = PagingKernel.collect_mesh_stats(final_mesh)
			total_verts += int(stats.get("vertex_count", 0))
			index["%d,%d" % [chunk_key.x, chunk_key.y]] = {
				"refs": inputs.size(),
				"surfaces": final_mesh.get_surface_count(),
				"vertices": int(stats.get("vertex_count", 0)),
				"indices": int(stats.get("index_count", 0)),
				"aabb_pos": [aabb.position.x, aabb.position.y, aabb.position.z],
				"aabb_size": [aabb.size.x, aabb.size.y, aabb.size.z],
			}

		# Keep memory bounded: manifests are per-chunk disposable; the model
		# sub-mesh cache persists (models repeat across chunks).
		source.clear_cache()
		if (ci + 1) % 16 == 0:
			print("Chunk bake: %d/%d (%d baked, %.1f MB)" % [ci + 1, chunk_keys.size(), baked, total_bytes / 1048576.0])
			await get_tree().process_frame

	var index_file := FileAccess.open(out_dir.path_join("chunk_index.json"), FileAccess.WRITE)
	if index_file != null:
		index_file.store_string(JSON.stringify({
			"version": 1,
			"chunk_cells": CHUNK_CELLS,
			"chunk_start": DU.CHUNK_START,
			"chunk_end": DU.CHUNK_END,
			"min_size_ratio": MIN_SIZE_RATIO,
			"chunks": index,
		}, "\t"))

	var elapsed := (Time.get_ticks_msec() - start_ms) / 1000.0
	print("Chunk bake complete: %d baked, %d empty, %d failed | %d refs, %d verts, %.1f MB, %.1f s, %d unique models, %d shared materials | out=%s" % [
		baked, empty, failed, total_refs, total_verts, total_bytes / 1048576.0, elapsed,
		_model_submesh_cache.size(), _material_library.size(), out_dir])
	get_tree().quit(0 if failed == 0 else 1)


## Baker-local finalize: LOD chain + compressed vertex attributes.
## ARRAY_FLAG_COMPRESS_ATTRIBUTES (verified against 4.6 docs): positions pack
## to RGBA16UNORM scaled in-shader (~3.6mm quantization across a 234m chunk —
## invisible at the 400m+ band), normal+tangent pack together, UVs go
## half-float. The flag REQUIRES tangents alongside normals, so tangents are
## kept (near-free packed). UV2 is dropped — unused at ring distance.
## The shared ObjectPagingKernel.generate_lods stays untouched (flags=0) for
## runtime-HLOD parity; this variant is bake-only.
func _finalize_with_lods(mesh: ArrayMesh) -> ArrayMesh:
	if mesh.get_surface_count() == 0:
		return mesh
	var importer := ImporterMesh.new()
	var added := 0
	for si in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(si)
		if arrays.is_empty():
			continue
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if verts == null or not (verts is PackedVector3Array) or (verts as PackedVector3Array).is_empty():
			continue
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices == null or not (indices is PackedInt32Array) or (indices as PackedInt32Array).is_empty():
			var vert_count: int = (verts as PackedVector3Array).size()
			var identity := PackedInt32Array()
			identity.resize(vert_count)
			for vi in vert_count:
				identity[vi] = vi
			arrays[Mesh.ARRAY_INDEX] = identity
		arrays[Mesh.ARRAY_TEX_UV2] = null
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			mesh.surface_get_material(si), "", Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
		added += 1
	if added == 0:
		return mesh
	importer.generate_lods(PagingKernel.LOD_NORMAL_MERGE_ANGLE, PagingKernel.LOD_SCREEN_COVERAGE, [])
	var out := importer.get_mesh()
	if out != null and out.get_surface_count() > 0:
		out.set_meta("has_lod_chain", true)
		return out
	return mesh


## Load a baked model .res once and extract its sub-meshes:
## [{mesh: ArrayMesh, local_transform, material_override, surface_materials}].
## Cached per model — models repeat across many chunks.
func _get_model_submeshes(model_path: String) -> Array:
	var key := model_path.to_lower()
	if key in _model_submesh_cache:
		return _model_submesh_cache[key]

	var result: Array = []
	var radius := 0.0
	var settings: Node = get_node_or_null("/root/SettingsManager")
	var models_dir: String = settings.call("get_cache_base_path").path_join("models")
	var safe_name := key.replace("/", "\\").replace("\\", "_").replace(":", "_").replace(".", "_")
	var scene_path := models_dir.path_join(safe_name + ".res")
	if FileAccess.file_exists(scene_path):
		var packed := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
		if packed != null:
			var proto := packed.instantiate() as Node3D
			if proto != null:
				var combined := AABB()
				var has_any := false
				var stack: Array = [[proto, Transform3D.IDENTITY]]
				while not stack.is_empty():
					var entry: Array = stack.pop_back()
					var node: Node = entry[0]
					var parent_xf: Transform3D = entry[1]
					var local_xf := parent_xf
					if node is Node3D:
						local_xf = parent_xf * (node as Node3D).transform
					if node is MeshInstance3D:
						var mi := node as MeshInstance3D
						var array_mesh := mi.mesh as ArrayMesh
						if array_mesh != null:
							# Resolve the EFFECTIVE material per surface with the
							# kernel's precedence (override → surface override →
							# mesh default), remap through the shared library, and
							# store it in the surface slot — so the merge groups
							# by deduped materials and mesh-embedded materials
							# never leak into the chunk save.
							var surface_materials: Array[Material] = []
							for si in array_mesh.get_surface_count():
								var eff: Material = mi.material_override
								if eff == null:
									eff = mi.get_surface_override_material(si)
								if eff == null:
									eff = array_mesh.surface_get_material(si)
								surface_materials.append(_get_shared_material(eff))
							result.append({
								"mesh": array_mesh,
								"local_transform": local_xf,
								"material_override": null,
								"surface_materials": surface_materials,
							})
							var mesh_aabb := local_xf * array_mesh.get_aabb()
							combined = combined.merge(mesh_aabb) if has_any else mesh_aabb
							has_any = true
					for child in node.get_children():
						stack.append([child, local_xf])
				if has_any:
					radius = combined.size.length() * 0.5
				proto.free()

	_model_submesh_cache[key] = result
	_model_radius_cache[key] = radius
	return result


## Dedup a source material into the shared library. Returns a material with
## a real resource_path (saved standalone), so chunk saves reference it
## externally instead of embedding textures. Null-safe (null → null: the
## kernel assigns its gray proxy material to null surfaces).
func _get_shared_material(source: Material) -> Material:
	if source == null:
		return null
	var std := source as BaseMaterial3D
	if std == null:
		# ShaderMaterial etc. — pass through untouched (rare in baked models).
		return source

	var albedo: Texture2D = std.albedo_texture
	var key: String
	if albedo != null:
		var src_img := albedo.get_image()
		if src_img == null:
			return source
		key = "t%d_%dx%d_%d_%d" % [
			hash(src_img.get_data()), src_img.get_width(), src_img.get_height(),
			std.transparency, std.cull_mode]
	else:
		key = "c%s_%d_%d" % [std.albedo_color.to_html(), std.transparency, std.cull_mode]

	if key in _material_library:
		return _material_library[key]

	var shared := std.duplicate() as BaseMaterial3D
	var t0 := Time.get_ticks_msec()
	if albedo != null:
		var img := albedo.get_image()
		if not img.has_mipmaps():
			# Mipmaps matter at ring distance (shimmer without them). Compressed
			# formats can't generate mipmaps in-place — do it pre-compression.
			img = img.duplicate()
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			img.generate_mipmaps()
		var pct := PortableCompressedTexture2D.new()
		# MUST be set BEFORE create_from_image: outside the editor the
		# compressed buffer is discarded after GPU upload, and ResourceSaver
		# then writes an EMPTY texture (renders as the magenta checker).
		# Verified against the 4.6 class doc, 2026-07-05.
		pct.keep_compressed_buffer = true
		pct.create_from_image(img, PortableCompressedTexture2D.COMPRESSION_MODE_S3TC)
		shared.albedo_texture = pct
	var mat_path := _materials_dir.path_join("mat_%04d.res" % _material_seq)
	_material_seq += 1
	var err := ResourceSaver.save(shared, mat_path)
	if err == OK:
		shared.take_over_path(mat_path)
	else:
		push_warning("Chunk bake: material save failed (%s) — will embed" % error_string(err))
	var mat_ms := Time.get_ticks_msec() - t0
	if mat_ms > 250:
		print("Chunk bake: SLOW material %s (%d ms, tex=%s)" % [mat_path.get_file(), mat_ms,
			"%dx%d" % [albedo.get_width(), albedo.get_height()] if albedo != null else "none"])
	_material_library[key] = shared
	return shared


func _to_submesh_inputs(sub_meshes: Array) -> Array:
	var out: Array = []
	for sm: Dictionary in sub_meshes:
		var input := PagingKernel.SubMeshInput.new()
		input.mesh = sm["mesh"]
		input.local_transform = sm["local_transform"]
		input.material_override = sm["material_override"]
		var mats: Array[Material] = []
		mats.assign(sm["surface_materials"])
		input.surface_materials = mats
		out.append(input)
	return out
