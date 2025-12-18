## NIF Reader - Reads NetImmerse/Gamebryo model files (Morrowind format)
## Ported from OpenMW components/nif/niffile.cpp
class_name NIFReader
extends RefCounted

# Preload definitions
const Defs := preload("res://src/core/nif/nif_defs.gd")

# File state
var _buffer: PackedByteArray
var _pos: int = 0
var _version: int = 0
var _num_records: int = 0
var _parse_failed: bool = false  # Set when unrecoverable error encountered
var _source_path: String = ""  # Source file path (for error messages)

# Parsed data
var records: Array = []  # Array of NIFRecord objects
var roots: Array[int] = []  # Root record indices

# Debug mode - set to true to print parsing info
var debug_mode: bool = false

## Get NIF version
func get_version() -> int:
	return _version

## Get version as string
func get_version_string() -> String:
	return Defs.version_to_string(_version)

## Get number of records
func get_num_records() -> int:
	return _num_records

## Get root record indices
func get_roots() -> Array[int]:
	return roots

## Get a record by index
func get_record(index: int) -> Defs.NIFRecord:
	if index < 0 or index >= records.size():
		return null
	return records[index]

## Load NIF from file path
func load_file(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("NIFReader: Failed to open file: %s" % path)
		return FileAccess.get_open_error()

	_buffer = file.get_buffer(file.get_length())
	file.close()

	if _buffer.size() == 0:
		push_error("NIFReader: Empty file: %s" % path)
		return ERR_FILE_CORRUPT

	return _parse()

## Load NIF from buffer (e.g., from BSA)
## path_hint is optional but helps identify the file in error messages
func load_buffer(data: PackedByteArray, path_hint: String = "") -> Error:
	if data.size() == 0:
		push_error("NIFReader: Empty buffer")
		return ERR_INVALID_DATA

	_buffer = data
	_source_path = path_hint
	return _parse()

## Main parse function
func _parse() -> Error:
	_pos = 0
	_parse_failed = false
	records.clear()
	roots.clear()

	# Read header string (until newline)
	var header := _read_line()
	if not header.begins_with("NetImmerse File Format") and not header.begins_with("Gamebryo File Format"):
		push_error("NIFReader: Invalid NIF header: %s" % header)
		return ERR_FILE_UNRECOGNIZED

	# Parse version from header
	_version = Defs.parse_version_string(header)
	if _version == 0:
		push_error("NIFReader: Failed to parse version from header")
		return ERR_FILE_CORRUPT

	# For Morrowind NIFs, version is also stored as uint32 after header
	if _version == Defs.VER_MW:
		var stored_version := _read_u32()
		if stored_version != _version:
			push_warning("NIFReader: Header version mismatch (header=%s, stored=0x%08X)" %
				[Defs.version_to_string(_version), stored_version])

	# Read number of records
	_num_records = _read_u32()
	if _num_records == 0:
		push_warning("NIFReader: No records in file")
		return OK

	# Pre-allocate records array
	records.resize(_num_records)

	# Read each record
	for i in range(_num_records):
		# Safety check: if we've gone past the buffer, stop parsing
		if _pos >= _buffer.size():
			push_error("NIFReader: Unexpected end of buffer at record %d (pos=%d, size=%d)" % [i, _pos, _buffer.size()])
			return ERR_FILE_CORRUPT

		var record := _read_record(i)
		if record == null:
			# Don't spam errors - _read_record already logged the specific failure
			if not _parse_failed:
				push_error("NIFReader: Failed to read record %d" % i)
			return ERR_FILE_CORRUPT
		records[i] = record

	# Read root indices (number of roots + indices)
	if _version == Defs.VER_MW:
		# Morrowind: roots come after all records
		if debug_mode:
			print("  Reading roots at pos=%d, buffer_size=%d" % [_pos, _buffer.size()])
		var num_roots := _read_u32()
		if debug_mode:
			print("  num_roots=%d" % num_roots)
		for i in range(num_roots):
			var root_idx := _read_s32()
			if debug_mode:
				print("  root[%d]=%d" % [i, root_idx])
			roots.append(root_idx)

	return OK

## Read a single record
func _read_record(index: int) -> Defs.NIFRecord:
	var start_pos := _pos

	# For Morrowind, record type is a length-prefixed string
	var record_type := _read_string()

	if debug_mode:
		print("  [%d] pos=%d type='%s'" % [index, start_pos, record_type])

	var record: Defs.NIFRecord = null

	# Create appropriate record type based on string
	match record_type:
		# Nodes
		Defs.RT_NI_NODE, Defs.RT_ROOT_COLLISION_NODE, Defs.RT_NI_BILLBOARD_NODE, \
		Defs.RT_AVOID_NODE, Defs.RT_NI_BS_ANIMATION_NODE, Defs.RT_NI_BS_PARTICLE_NODE, \
		Defs.RT_NI_COLLISION_SWITCH, Defs.RT_NI_SORT_ADJUST_NODE:
			record = _read_ni_node(record_type)
		Defs.RT_NI_SWITCH_NODE, Defs.RT_NI_FLT_ANIMATION_NODE:
			record = _read_ni_switch_node()
		Defs.RT_NI_LOD_NODE:
			record = _read_ni_lod_node()

		# Geometry
		Defs.RT_NI_TRI_SHAPE:
			record = _read_ni_tri_shape()
		Defs.RT_NI_TRI_STRIPS:
			record = _read_ni_tri_strips()
		Defs.RT_NI_LINES:
			record = _read_ni_lines()
		Defs.RT_NI_TRI_SHAPE_DATA:
			record = _read_ni_tri_shape_data()
		Defs.RT_NI_TRI_STRIPS_DATA:
			record = _read_ni_tri_strips_data()
		Defs.RT_NI_LINES_DATA:
			record = _read_ni_lines_data()

		# Particles
		Defs.RT_NI_AUTO_NORMAL_PARTICLES, Defs.RT_NI_ROTATE_PARTICLES, Defs.RT_NI_PARTICLES:
			record = _read_ni_particles()
		Defs.RT_NI_AUTO_NORMAL_PARTICLES_DATA, Defs.RT_NI_PARTICLES_DATA:
			record = _read_ni_particles_data()
		Defs.RT_NI_ROTATE_PARTICLES_DATA:
			record = _read_ni_rotating_particles_data()

		# Properties
		Defs.RT_NI_TEXTURING_PROPERTY:
			record = _read_ni_texturing_property()
		Defs.RT_NI_MATERIAL_PROPERTY:
			record = _read_ni_material_property()
		Defs.RT_NI_ALPHA_PROPERTY:
			record = _read_ni_alpha_property()
		Defs.RT_NI_VERTEX_COLOR_PROPERTY:
			record = _read_ni_vertex_color_property()
		Defs.RT_NI_ZBUFFER_PROPERTY:
			record = _read_ni_zbuffer_property()
		Defs.RT_NI_SPECULAR_PROPERTY:
			record = _read_ni_specular_property()
		Defs.RT_NI_WIREFRAME_PROPERTY:
			record = _read_ni_wireframe_property()
		Defs.RT_NI_STENCIL_PROPERTY:
			record = _read_ni_stencil_property()
		Defs.RT_NI_DITHER_PROPERTY:
			record = _read_ni_dither_property()
		Defs.RT_NI_FOG_PROPERTY:
			record = _read_ni_fog_property()
		Defs.RT_NI_SHADE_PROPERTY:
			record = _read_ni_shade_property()

		# Textures
		Defs.RT_NI_SOURCE_TEXTURE:
			record = _read_ni_source_texture()
		Defs.RT_NI_PIXEL_DATA:
			record = _read_ni_pixel_data()
		Defs.RT_NI_PALETTE:
			record = _read_ni_palette()

		# Extra Data
		Defs.RT_NI_STRING_EXTRA_DATA:
			record = _read_ni_string_extra_data()
		Defs.RT_NI_TEXT_KEY_EXTRA_DATA:
			record = _read_ni_text_key_extra_data()
		Defs.RT_NI_EXTRA_DATA, Defs.RT_NI_BINARY_EXTRA_DATA, Defs.RT_NI_BOOLEAN_EXTRA_DATA, \
		Defs.RT_NI_COLOR_EXTRA_DATA, Defs.RT_NI_FLOAT_EXTRA_DATA, Defs.RT_NI_FLOATS_EXTRA_DATA, \
		Defs.RT_NI_INTEGER_EXTRA_DATA, Defs.RT_NI_INTEGERS_EXTRA_DATA, \
		Defs.RT_NI_VECTOR_EXTRA_DATA, Defs.RT_NI_STRINGS_EXTRA_DATA:
			record = _read_ni_extra_data()
		Defs.RT_NI_VERT_WEIGHTS_EXTRA_DATA:
			record = _read_ni_vert_weights_extra_data()

		# Controllers
		Defs.RT_NI_KEYFRAME_CONTROLLER:
			record = _read_ni_keyframe_controller()
		Defs.RT_NI_VIS_CONTROLLER:
			record = _read_ni_vis_controller()
		Defs.RT_NI_UV_CONTROLLER:
			record = _read_ni_uv_controller()
		Defs.RT_NI_ALPHA_CONTROLLER:
			record = _read_ni_alpha_controller()
		Defs.RT_NI_MATERIAL_COLOR_CONTROLLER:
			record = _read_ni_material_color_controller()
		Defs.RT_NI_FLIP_CONTROLLER:
			record = _read_ni_flip_controller()
		Defs.RT_NI_GEOM_MORPHER_CONTROLLER:
			record = _read_ni_geom_morpher_controller()
		Defs.RT_NI_PATH_CONTROLLER:
			record = _read_ni_path_controller()
		Defs.RT_NI_LOOK_AT_CONTROLLER:
			record = _read_ni_look_at_controller()
		Defs.RT_NI_ROLL_CONTROLLER:
			record = _read_ni_roll_controller()
		Defs.RT_NI_PARTICLE_SYSTEM_CONTROLLER, Defs.RT_NI_BSP_ARRAY_CONTROLLER:
			record = _read_ni_particle_system_controller()
		Defs.RT_NI_LIGHT_COLOR_CONTROLLER:
			record = _read_ni_light_color_controller()

		# Controller Data
		Defs.RT_NI_KEYFRAME_DATA:
			record = _read_ni_keyframe_data()
		Defs.RT_NI_VIS_DATA:
			record = _read_ni_vis_data()
		Defs.RT_NI_UV_DATA:
			record = _read_ni_uv_data()
		Defs.RT_NI_FLOAT_DATA:
			record = _read_ni_float_data()
		Defs.RT_NI_COLOR_DATA:
			record = _read_ni_color_data()
		Defs.RT_NI_POS_DATA:
			record = _read_ni_pos_data()
		Defs.RT_NI_MORPH_DATA:
			record = _read_ni_morph_data()

		# Lights
		Defs.RT_NI_AMBIENT_LIGHT, Defs.RT_NI_DIRECTIONAL_LIGHT:
			record = _read_ni_light()
		Defs.RT_NI_POINT_LIGHT:
			record = _read_ni_point_light()
		Defs.RT_NI_SPOT_LIGHT:
			record = _read_ni_spot_light()

		# Camera
		Defs.RT_NI_CAMERA:
			record = _read_ni_camera()

		# Effects
		Defs.RT_NI_TEXTURE_EFFECT:
			record = _read_ni_texture_effect()

		# Skinning
		Defs.RT_NI_SKIN_INSTANCE:
			record = _read_ni_skin_instance()
		Defs.RT_NI_SKIN_DATA:
			record = _read_ni_skin_data()
		Defs.RT_NI_SKIN_PARTITION:
			record = _read_ni_skin_partition()

		# Particle Modifiers (these are embedded in controller, but can appear as separate records)
		Defs.RT_NI_GRAVITY:
			record = _read_ni_gravity()
		Defs.RT_NI_PARTICLE_GROW_FADE:
			record = _read_ni_particle_grow_fade()
		Defs.RT_NI_PARTICLE_COLOR_MODIFIER:
			record = _read_ni_particle_color_modifier()
		Defs.RT_NI_PARTICLE_ROTATION:
			record = _read_ni_particle_rotation()
		Defs.RT_NI_PLANAR_COLLIDER:
			record = _read_ni_planar_collider()
		Defs.RT_NI_SPHERICAL_COLLIDER:
			record = _read_ni_spherical_collider()
		Defs.RT_NI_PARTICLE_BOMB:
			record = _read_ni_particle_bomb()

		# LOD Data
		Defs.RT_NI_RANGE_LOD_DATA:
			record = _read_ni_range_lod_data()
		Defs.RT_NI_SCREEN_LOD_DATA:
			record = _read_ni_screen_lod_data()

		# Accumulators (just skip for now)
		Defs.RT_NI_ALPHA_ACCUMULATOR, Defs.RT_NI_CLUSTER_ACCUMULATOR:
			record = _read_ni_accumulator()

		# Sequence helper
		Defs.RT_NI_SEQUENCE_STREAM_HELPER:
			record = _read_ni_sequence_stream_helper()

		_:
			# Unknown record type - try to handle gracefully
			if record_type.ends_with("ExtraData"):
				# All ExtraData types in Morrowind have the same header structure:
				# next_extra_data_index (s32) + bytes_remaining (u32) + data
				# We can safely skip them using the bytes_remaining field
				push_warning("NIFReader: Unknown ExtraData type '%s' at index %d (skipping)" % [record_type, index])
				record = _read_ni_extra_data()
			else:
				# Truly unknown type - we cannot safely skip without knowing structure
				# Log once and abort to prevent cascading errors
				var path_info := " in '%s'" % _source_path if not _source_path.is_empty() else ""
				push_error("NIFReader: Unknown record type '%s' at index %d%s - aborting" % [record_type, index, path_info])
				_parse_failed = true
				return null  # This will cause _parse() to return ERR_FILE_CORRUPT

	if record:
		record.record_type = record_type
		record.record_index = index

	return record

# =============================================================================
# NODE READERS
# =============================================================================

## Read NiNode (and derived types)
func _read_ni_node(_record_type: String) -> Defs.NiNode:
	var node := Defs.NiNode.new()
	_read_ni_av_object(node)

	# Children
	var num_children := _read_u32()
	for i in range(num_children):
		node.children_indices.append(_read_s32())

	# Effects (Morrowind only)
	var num_effects := _read_u32()
	for i in range(num_effects):
		node.effects_indices.append(_read_s32())

	return node

## Read NiSwitchNode
func _read_ni_switch_node() -> Defs.NiSwitchNode:
	var node := Defs.NiSwitchNode.new()
	_read_ni_av_object(node)

	# Children
	var num_children := _read_u32()
	for i in range(num_children):
		node.children_indices.append(_read_s32())

	# Effects
	var num_effects := _read_u32()
	for i in range(num_effects):
		node.effects_indices.append(_read_s32())

	# Switch specific
	node.initial_index = _read_u32()

	return node

## Read NiLODNode
func _read_ni_lod_node() -> Defs.NiLODNode:
	var node := Defs.NiLODNode.new()
	_read_ni_av_object(node)

	# Children
	var num_children := _read_u32()
	for i in range(num_children):
		node.children_indices.append(_read_s32())

	# Effects
	var num_effects := _read_u32()
	for i in range(num_effects):
		node.effects_indices.append(_read_s32())

	# LOD center
	node.lod_center = _read_vector3()

	# LOD levels
	var num_levels := _read_u32()
	for i in range(num_levels):
		node.lod_levels.append({
			"min_range": _read_float(),
			"max_range": _read_float()
		})

	return node

# =============================================================================
# GEOMETRY READERS
# =============================================================================

## Read NiTriShape
func _read_ni_tri_shape() -> Defs.NiTriShape:
	var shape := Defs.NiTriShape.new()
	_read_ni_geometry(shape)
	return shape

## Read NiTriStrips
func _read_ni_tri_strips() -> Defs.NiTriStrips:
	var strips := Defs.NiTriStrips.new()
	_read_ni_geometry(strips)
	return strips

## Read NiLines
func _read_ni_lines() -> Defs.NiLines:
	var lines := Defs.NiLines.new()
	_read_ni_geometry(lines)
	return lines

## Read NiParticles
func _read_ni_particles() -> Defs.NiParticles:
	var particles := Defs.NiParticles.new()
	_read_ni_geometry(particles)
	return particles

## Read NiGeometry fields (shared by NiTriShape, NiTriStrips, NiParticles)
func _read_ni_geometry(geom: Defs.NiGeometry) -> void:
	_read_ni_av_object(geom)
	geom.data_index = _read_s32()
	geom.skin_index = _read_s32()

## Read NiAVObject fields (shared by NiNode, NiGeometry)
func _read_ni_av_object(obj: Defs.NiAVObject) -> void:
	_read_ni_object_net(obj)

	obj.flags = _read_u16()

	# Transform
	obj.transform = Defs.NIFTransform.new()
	obj.transform.translation = _read_vector3()
	obj.transform.rotation = _read_matrix3()
	obj.transform.scale = _read_float()

	# Velocity (Morrowind version <= 4.2.2.0)
	obj.velocity = _read_vector3()

	# Properties
	var num_properties := _read_u32()
	for i in range(num_properties):
		obj.property_indices.append(_read_s32())

	# Bounding volume (Morrowind version <= 4.2.2.0)
	# Bool is read as int32 for versions < 4.1.0.0
	obj.has_bounding_volume = _read_u32() != 0
	if obj.has_bounding_volume:
		obj.bounding_volume = _read_bounding_volume(obj)

## Read NiObjectNET fields
func _read_ni_object_net(obj: Defs.NiObjectNET) -> void:
	obj.name = _read_string()
	obj.extra_data_index = _read_s32()
	obj.controller_index = _read_s32()

## Read NiTriShapeData
func _read_ni_tri_shape_data() -> Defs.NiTriShapeData:
	var data := Defs.NiTriShapeData.new()
	var start_pos := _pos
	_read_ni_geometry_data(data)
	if debug_mode:
		print("    After geometry_data: pos=%d (read %d bytes), verts=%d, normals=%d, colors=%d, uvs=%d" % [
			_pos, _pos - start_pos, data.vertices.size(), data.normals.size(),
			data.colors.size(), data.uv_sets.size()])

	# Triangle count
	data.num_triangles = _read_u16()
	if debug_mode:
		print("    pos before num_indices=%d, next 8 bytes: %s" % [_pos, _buffer.slice(_pos, mini(_pos + 8, _buffer.size())).hex_encode()])

	# Triangle indices - this is the TRIANGLE POINT COUNT (num_triangles * 3)
	var num_indices := _read_u32()
	if debug_mode:
		print("    num_triangles=%d, num_indices=%d (expected ~%d)" % [data.num_triangles, num_indices, data.num_triangles * 3])
	data.triangles.resize(num_indices)
	for i in range(num_indices):
		data.triangles[i] = _read_u16()

	# Match groups (skip for now)
	var num_match_groups := _read_u16()
	if debug_mode:
		print("    num_match_groups=%d, final pos=%d" % [num_match_groups, _pos])
	for i in range(num_match_groups):
		var group_size := _read_u16()
		_skip(group_size * 2)  # Skip indices

	return data

## Read NiTriStripsData
func _read_ni_tri_strips_data() -> Defs.NiTriStripsData:
	var data := Defs.NiTriStripsData.new()
	_read_ni_geometry_data(data)

	# Number of triangles (total)
	data.num_triangles = _read_u16()

	# Strips
	var num_strips := _read_u16()
	data.strips.resize(num_strips)

	# Strip lengths
	var strip_lengths: Array[int] = []
	strip_lengths.resize(num_strips)
	for i in range(num_strips):
		strip_lengths[i] = _read_u16()

	# For Morrowind (version <= VER_OB_OLD), strips are always present
	# The has_points flag only exists in newer versions
	# Morrowind unconditionally reads all strips
	for i in range(num_strips):
		var strip := PackedInt32Array()
		strip.resize(strip_lengths[i])
		for j in range(strip_lengths[i]):
			strip[j] = _read_u16()
		data.strips[i] = strip

	return data

## Read NiParticlesData
func _read_ni_particles_data() -> Defs.NiParticlesData:
	var data := Defs.NiParticlesData.new()
	_read_ni_geometry_data(data)

	# Particle specific data
	data.num_particles = _read_u16()
	data.particle_radius = _read_float()
	data.num_active = _read_u16()
	data.has_sizes = _read_bool()  # Bool is 4 bytes for Morrowind
	if data.has_sizes:
		data.sizes.resize(data.num_vertices)
		for i in range(data.num_vertices):
			data.sizes[i] = _read_float()

	return data


## Read NiRotatingParticlesData - has additional rotation data
func _read_ni_rotating_particles_data() -> Defs.NiParticlesData:
	var data := Defs.NiParticlesData.new()
	_read_ni_geometry_data(data)

	# Base particle data (same as NiParticlesData)
	data.num_particles = _read_u16()
	data.particle_radius = _read_float()
	data.num_active = _read_u16()
	data.has_sizes = _read_bool()  # Bool is 4 bytes for Morrowind
	if data.has_sizes:
		data.sizes.resize(data.num_vertices)
		for i in range(data.num_vertices):
			data.sizes[i] = _read_float()

	# NiRotatingParticlesData specific: rotations array
	# For Morrowind (version <= 4.2.2.0), read has_rotations bool and rotation array
	var has_rotations := _read_bool()  # Bool is 4 bytes for Morrowind
	if has_rotations:
		# Skip rotation quaternions (16 bytes each = 4 floats)
		# We don't use these for Godot particles, but must read them to stay in sync
		_skip(data.num_vertices * 16)

	return data


## Read NiLinesData
func _read_ni_lines_data() -> Defs.NiLinesData:
	var data := Defs.NiLinesData.new()
	_read_ni_geometry_data(data)

	# Line connectivity flags - one byte per vertex
	# If flag & 1, there's a line from vertex i to vertex i+1
	var flags := PackedByteArray()
	flags.resize(data.num_vertices)
	for i in range(data.num_vertices):
		flags[i] = _read_u8()

	# Build line indices from connectivity flags
	var lines := PackedInt32Array()
	for i in range(data.num_vertices - 1):
		if flags[i] & 1:
			lines.append(i)
			lines.append(i + 1)

	# Check for wrap-around (last vertex connects to first)
	if data.num_vertices > 0 and (flags[data.num_vertices - 1] & 1):
		lines.append(data.num_vertices - 1)
		lines.append(0)

	data.lines = lines
	return data

## Read NiGeometryData fields
func _read_ni_geometry_data(data: Defs.NiGeometryData) -> void:
	var geom_start := _pos
	# Vertex count
	data.num_vertices = _read_u16()
	if debug_mode:
		print("      num_vertices=%d" % data.num_vertices)

	# Has vertices flag (bool - 4 bytes in Morrowind!)
	var has_vertices := _read_bool()
	if has_vertices:
		data.vertices.resize(data.num_vertices)
		for i in range(data.num_vertices):
			data.vertices[i] = _read_vector3()
	if debug_mode:
		print("      after vertices (has=%s): pos=%d" % [has_vertices, _pos])

	# Has normals flag (bool - 4 bytes in Morrowind!)
	var has_normals := _read_bool()
	if debug_mode and has_normals:
		# Show first normal to verify it looks valid
		var peek_pos := _pos
		var n0 := Vector3(_buffer.decode_float(peek_pos), _buffer.decode_float(peek_pos+4), _buffer.decode_float(peek_pos+8))
		print("      first normal preview: %s" % n0)
	if has_normals:
		data.normals.resize(data.num_vertices)
		for i in range(data.num_vertices):
			data.normals[i] = _read_vector3()
	if debug_mode:
		print("      after normals (has=%s): pos=%d" % [has_normals, _pos])

	# Bounding sphere
	data.center = _read_vector3()
	data.radius = _read_float()
	if debug_mode:
		print("      after bsphere: pos=%d (center=%s, radius=%s)" % [_pos, data.center, data.radius])

	# Has vertex colors flag (bool - 4 bytes in Morrowind!)
	var has_colors := _read_bool()
	if has_colors:
		data.colors.resize(data.num_vertices)
		for i in range(data.num_vertices):
			data.colors[i] = _read_color4()
	if debug_mode:
		print("      after colors (has=%s): pos=%d" % [has_colors, _pos])

	# UV sets - in Morrowind (4.0.0.2), data_flags IS the number of UV sets
	# The format is: data_flags (u16), then has_uv (bool), then UV data
	data.data_flags = _read_u16()
	var num_uv_sets := data.data_flags  # For Morrowind, the whole value is numUVs
	if debug_mode:
		print("      data_flags/num_uv_sets=%d" % num_uv_sets)

	# Has UV flag (bool - 4 bytes in Morrowind!) - if false, no UVs regardless of num_uv_sets
	var has_uv := _read_bool()
	if debug_mode:
		print("      has_uv=%s, pos before UV read=%d" % [has_uv, _pos])
	if not has_uv:
		num_uv_sets = 0

	if num_uv_sets > 0:
		data.uv_sets.resize(num_uv_sets)
		for uv_idx in range(num_uv_sets):
			var uvs := PackedVector2Array()
			uvs.resize(data.num_vertices)
			for i in range(data.num_vertices):
				var u := _read_float()
				var v := _read_float()
				# Flip V coordinate (DirectX to OpenGL convention)
				uvs[i] = Vector2(u, 1.0 - v)
			data.uv_sets[uv_idx] = uvs
	if debug_mode:
		print("      after UVs: pos=%d, total geom bytes=%d" % [_pos, _pos - geom_start])

# =============================================================================
# PROPERTY READERS
# =============================================================================

## Read NiTexturingProperty
func _read_ni_texturing_property() -> Defs.NiTexturingProperty:
	var prop := Defs.NiTexturingProperty.new()
	_read_ni_object_net(prop)

	# Flags (Morrowind version - always present for version <= VER_OB_OLD)
	prop.flags = _read_u16()

	# Apply mode (Morrowind version <= 20.1.0.1)
	prop.apply_mode = _read_u32()

	# Texture count
	var tex_count := _read_u32()

	for i in range(tex_count):
		var tex := Defs.TextureDesc.new()
		# NOTE: For Morrowind (version < 4.1.0.0), bools are read as int32!
		tex.has_texture = _read_u32() != 0
		if tex.has_texture:
			tex.source_index = _read_s32()
			tex.clamp_mode = _read_u32()
			tex.filter_mode = _read_u32()
			tex.uv_set = _read_u32()

			# PS2 filtering settings (Morrowind version <= 10.4.0.1)
			_skip(4)

			# Unknown 2 bytes (Morrowind version <= 4.1.0.12)
			_skip(2)

			# Special handling for bump texture (index 5)
			if i == 5:
				prop.env_map_luma_bias = Vector2(_read_float(), _read_float())
				prop.bump_map_matrix[0] = _read_float()
				prop.bump_map_matrix[1] = _read_float()
				prop.bump_map_matrix[2] = _read_float()
				prop.bump_map_matrix[3] = _read_float()

		prop.textures.append(tex)

	return prop

## Read NiMaterialProperty
func _read_ni_material_property() -> Defs.NiMaterialProperty:
	var prop := Defs.NiMaterialProperty.new()
	_read_ni_object_net(prop)

	# Flags (Morrowind)
	prop.flags = _read_u16()

	prop.ambient = _read_color3()
	prop.diffuse = _read_color3()
	prop.specular = _read_color3()
	prop.emissive = _read_color3()
	prop.glossiness = _read_float()
	prop.alpha = _read_float()

	return prop

## Read NiAlphaProperty
func _read_ni_alpha_property() -> Defs.NiAlphaProperty:
	var prop := Defs.NiAlphaProperty.new()
	_read_ni_object_net(prop)

	prop.alpha_flags = _read_u16()
	prop.threshold = _read_u8()

	return prop

## Read NiVertexColorProperty
func _read_ni_vertex_color_property() -> Defs.NiVertexColorProperty:
	var prop := Defs.NiVertexColorProperty.new()
	_read_ni_object_net(prop)

	prop.flags = _read_u16()
	prop.vertex_mode = _read_u32()
	prop.lighting_mode = _read_u32()

	return prop

## Read NiZBufferProperty
func _read_ni_zbuffer_property() -> Defs.NiZBufferProperty:
	var prop := Defs.NiZBufferProperty.new()
	_read_ni_object_net(prop)

	prop.zbuf_flags = _read_u16()

	return prop

## Read NiSpecularProperty
func _read_ni_specular_property() -> Defs.NiSpecularProperty:
	var prop := Defs.NiSpecularProperty.new()
	_read_ni_object_net(prop)

	prop.enabled = (_read_u16() & 1) != 0

	return prop

## Read NiWireframeProperty
func _read_ni_wireframe_property() -> Defs.NiWireframeProperty:
	var prop := Defs.NiWireframeProperty.new()
	_read_ni_object_net(prop)

	prop.enabled = (_read_u16() & 1) != 0

	return prop

## Read NiStencilProperty
func _read_ni_stencil_property() -> Defs.NiStencilProperty:
	var prop := Defs.NiStencilProperty.new()
	_read_ni_object_net(prop)

	# Morrowind version
	prop.flags = _read_u16()
	prop.enabled = _read_u8() != 0  # Explicit uint8, not version-dependent bool
	prop.test_function = _read_u32()
	prop.stencil_ref = _read_u32()
	prop.stencil_mask = _read_u32()
	prop.fail_action = _read_u32()
	prop.z_fail_action = _read_u32()
	prop.pass_action = _read_u32()
	prop.draw_mode = _read_u32()

	return prop

## Read NiDitherProperty
func _read_ni_dither_property() -> Defs.NiDitherProperty:
	var prop := Defs.NiDitherProperty.new()
	_read_ni_object_net(prop)

	prop.flags = _read_u16()

	return prop

## Read NiFogProperty
func _read_ni_fog_property() -> Defs.NiFogProperty:
	var prop := Defs.NiFogProperty.new()
	_read_ni_object_net(prop)

	prop.flags = _read_u16()
	prop.fog_depth = _read_float()
	prop.fog_color = _read_color3()

	return prop

## Read NiShadeProperty
func _read_ni_shade_property() -> Defs.NiShadeProperty:
	var prop := Defs.NiShadeProperty.new()
	_read_ni_object_net(prop)

	prop.flags = _read_u16()

	return prop

## Read NiSourceTexture
func _read_ni_source_texture() -> Defs.NiSourceTexture:
	var tex := Defs.NiSourceTexture.new()
	_read_ni_object_net(tex)

	tex.is_external = _read_u8() != 0  # Explicit byte field, not version-dependent bool
	if tex.is_external:
		tex.filename = _read_string()
	else:
		# Internal texture data index
		tex.internal_data_index = _read_s32()

	tex.pixel_layout = _read_u32()
	tex.use_mipmaps = _read_u32()
	tex.alpha_format = _read_u32()

	# Is static flag
	tex.is_static = _read_u8() != 0  # Explicit byte field, not version-dependent bool

	return tex

## Read NiPixelData - internal texture data
func _read_ni_pixel_data() -> Defs.NiPixelData:
	var pixel_data := Defs.NiPixelData.new()

	# Read pixel format (Morrowind uses old format)
	pixel_data.pixel_format = Defs.NiPixelFormat.new()
	pixel_data.pixel_format.format = _read_u32()

	# Morrowind format (version <= 10.4.0.1)
	# Read color masks (4 uint32)
	pixel_data.pixel_format.color_masks[0] = _read_u32()
	pixel_data.pixel_format.color_masks[1] = _read_u32()
	pixel_data.pixel_format.color_masks[2] = _read_u32()
	pixel_data.pixel_format.color_masks[3] = _read_u32()
	pixel_data.pixel_format.bits_per_pixel = _read_u32()
	pixel_data.pixel_format.compare_bits[0] = _read_u32()
	pixel_data.pixel_format.compare_bits[1] = _read_u32()

	# Palette reference
	pixel_data.palette_index = _read_s32()

	# Mipmaps
	var num_mipmaps := _read_u32()
	pixel_data.bytes_per_pixel = _read_u32()

	for i in range(num_mipmaps):
		var mipmap := {
			"width": _read_u32(),
			"height": _read_u32(),
			"offset": _read_u32()
		}
		pixel_data.mipmaps.append(mipmap)

	# num_faces only for version >= 10.4.0.2, Morrowind is 4.0.0.2
	# So we skip this and use default of 1

	# Read pixel data
	var num_pixels := _read_u32()
	pixel_data.pixel_data = _buffer.slice(_pos, _pos + num_pixels)
	_pos += num_pixels

	return pixel_data

## Read NiPalette - color palette for paletted textures
func _read_ni_palette() -> Defs.NiPalette:
	var palette := Defs.NiPalette.new()

	# Alpha flag
	var use_alpha := _read_u8()
	palette.has_alpha = use_alpha != 0

	# Number of entries
	var num_entries := _read_u32()

	# Always allocate 256 colors
	palette.colors.resize(256)

	# Alpha mask for non-alpha palettes (force opaque)
	@warning_ignore("unused_variable")
	var alpha_mask := 0x00 if palette.has_alpha else 0xFF

	# Read color entries
	for i in range(num_entries):
		var rgba := _read_u32()
		var r := (rgba & 0xFF) / 255.0
		var g := ((rgba >> 8) & 0xFF) / 255.0
		var b := ((rgba >> 16) & 0xFF) / 255.0
		var a := ((rgba >> 24) & 0xFF) / 255.0
		if not palette.has_alpha:
			a = 1.0  # Force opaque
		palette.colors[i] = Color(r, g, b, a)

	# Fill remaining entries with black
	for i in range(num_entries, 256):
		palette.colors[i] = Color(0, 0, 0, 1.0 if not palette.has_alpha else 0.0)

	return palette

# =============================================================================
# EXTRA DATA READERS
# =============================================================================

## Read NiStringExtraData
func _read_ni_string_extra_data() -> Defs.NiStringExtraData:
	var extra := Defs.NiStringExtraData.new()

	# Extra data header
	extra.next_extra_data_index = _read_s32()
	var _bytes_remaining := _read_u32()

	extra.string_data = _read_string()

	return extra

## Read NiTextKeyExtraData
func _read_ni_text_key_extra_data() -> Defs.NiTextKeyExtraData:
	var extra := Defs.NiTextKeyExtraData.new()

	# Extra data header
	extra.next_extra_data_index = _read_s32()
	var _bytes_remaining := _read_u32()

	# Text keys
	var num_keys := _read_u32()
	for i in range(num_keys):
		var time := _read_float()
		var value := _read_string()
		extra.keys.append({"time": time, "value": value})

	return extra

## Read NiExtraData (base)
func _read_ni_extra_data() -> Defs.NiExtraData:
	var extra := Defs.NiExtraData.new()

	extra.next_extra_data_index = _read_s32()
	extra.bytes_remaining = _read_u32()

	# Skip the data bytes
	_skip(extra.bytes_remaining)

	return extra

## Read NiVertWeightsExtraData
func _read_ni_vert_weights_extra_data() -> Defs.NiVertWeightsExtraData:
	var extra := Defs.NiVertWeightsExtraData.new()

	extra.next_extra_data_index = _read_s32()
	extra.num_bytes = _read_u32()
	extra.num_vertices = _read_u16()

	extra.weights.resize(extra.num_vertices)
	for i in range(extra.num_vertices):
		extra.weights[i] = _read_float()

	return extra

# =============================================================================
# CONTROLLER READERS
# =============================================================================

## Read base NiTimeController fields
func _read_ni_time_controller(ctrl: Defs.NiTimeController) -> void:
	ctrl.next_controller_index = _read_s32()
	ctrl.flags = _read_u16()
	ctrl.frequency = _read_float()
	ctrl.phase = _read_float()
	ctrl.start_time = _read_float()
	ctrl.stop_time = _read_float()
	ctrl.target_index = _read_s32()

## Read NiKeyframeController
func _read_ni_keyframe_controller() -> Defs.NiKeyframeController:
	var ctrl := Defs.NiKeyframeController.new()
	_read_ni_time_controller(ctrl)
	ctrl.data_index = _read_s32()
	return ctrl

## Read NiVisController
func _read_ni_vis_controller() -> Defs.NiVisController:
	var ctrl := Defs.NiVisController.new()
	_read_ni_time_controller(ctrl)
	ctrl.data_index = _read_s32()
	return ctrl

## Read NiUVController
func _read_ni_uv_controller() -> Defs.NiUVController:
	var ctrl := Defs.NiUVController.new()
	_read_ni_time_controller(ctrl)
	ctrl.uv_set = _read_u16()
	ctrl.data_index = _read_s32()
	return ctrl

## Read NiAlphaController
func _read_ni_alpha_controller() -> Defs.NiAlphaController:
	var ctrl := Defs.NiAlphaController.new()
	_read_ni_time_controller(ctrl)
	ctrl.data_index = _read_s32()
	return ctrl

## Read NiMaterialColorController
func _read_ni_material_color_controller() -> Defs.NiMaterialColorController:
	var ctrl := Defs.NiMaterialColorController.new()
	_read_ni_time_controller(ctrl)
	# Target color comes from flags in Morrowind
	ctrl.target_color = (ctrl.flags >> 4) & 3
	ctrl.data_index = _read_s32()
	return ctrl

## Read NiFlipController
func _read_ni_flip_controller() -> Defs.NiFlipController:
	var ctrl := Defs.NiFlipController.new()
	_read_ni_time_controller(ctrl)

	ctrl.texture_slot = _read_u32()
	var _time_start := _read_float()  # Morrowind specific
	ctrl.delta = _read_float()

	var num_sources := _read_u32()
	for i in range(num_sources):
		ctrl.source_indices.append(_read_s32())

	return ctrl

## Read NiGeomMorpherController
func _read_ni_geom_morpher_controller() -> Defs.NiGeomMorpherController:
	var ctrl := Defs.NiGeomMorpherController.new()
	_read_ni_time_controller(ctrl)
	ctrl.data_index = _read_s32()
	ctrl.always_update = _read_u8() != 0
	return ctrl

## Read NiPathController
func _read_ni_path_controller() -> Defs.NiPathController:
	var ctrl := Defs.NiPathController.new()
	_read_ni_time_controller(ctrl)

	# Path flags from controller flags in Morrowind
	ctrl.path_flags = (ctrl.flags >> 4)

	ctrl.bank_direction = _read_s32()
	ctrl.max_bank_angle = _read_float()
	ctrl.smoothing = _read_float()
	ctrl.follow_axis = _read_s16()
	ctrl.path_data_index = _read_s32()
	ctrl.percent_data_index = _read_s32()

	return ctrl

## Read NiLookAtController
func _read_ni_look_at_controller() -> Defs.NiLookAtController:
	var ctrl := Defs.NiLookAtController.new()
	_read_ni_time_controller(ctrl)
	ctrl.look_at_index = _read_s32()
	return ctrl

## Read NiRollController
func _read_ni_roll_controller() -> Defs.NiRollController:
	var ctrl := Defs.NiRollController.new()
	_read_ni_time_controller(ctrl)
	ctrl.data_index = _read_s32()
	return ctrl

## Read NiLightColorController
func _read_ni_light_color_controller() -> Defs.NiTimeController:
	var ctrl := Defs.NiTimeController.new()
	_read_ni_time_controller(ctrl)
	# Mode from flags in Morrowind
	var _mode := (ctrl.flags >> 4) & 1
	var _data_index := _read_s32()
	return ctrl

## Read NiParticleSystemController
func _read_ni_particle_system_controller() -> Defs.NiParticleSystemController:
	var ctrl := Defs.NiParticleSystemController.new()
	_read_ni_time_controller(ctrl)

	ctrl.speed = _read_float()
	ctrl.speed_variation = _read_float()
	ctrl.declination = _read_float()
	ctrl.declination_variation = _read_float()
	ctrl.planar_angle = _read_float()
	ctrl.planar_angle_variation = _read_float()
	ctrl.initial_normal = _read_vector3()
	ctrl.initial_color = _read_color4()
	ctrl.initial_size = _read_float()
	ctrl.emit_start_time = _read_float()
	ctrl.emit_stop_time = _read_float()

	var _reset_particle_system := _read_u8()
	ctrl.birth_rate = _read_float()
	ctrl.lifetime = _read_float()
	ctrl.lifetime_variation = _read_float()

	ctrl.emit_flags = _read_u16()
	ctrl.emitter_dimensions = _read_vector3()
	ctrl.emitter_index = _read_s32()

	# Spawn info
	var _num_spawn_generations := _read_u16()
	var _percentage_spawned := _read_float()
	var _spawn_multiplier := _read_u16()
	var _spawn_speed_chaos := _read_float()
	var _spawn_dir_chaos := _read_float()

	# Particles
	var num_particles := _read_u16()
	var _num_valid := _read_u16()

	for _i in range(num_particles):
		# Skip particle info
		_skip(4 * 3)  # velocity
		_skip(4 * 3)  # rotation axis (Morrowind version)
		_skip(4)      # age
		_skip(4)      # lifespan
		_skip(4)      # last update
		_skip(2)      # spawn generation
		_skip(2)      # code

	# Skip NiEmitterModifier link
	_skip(4)

	# Modifier and collider links
	var _modifier_index := _read_s32()
	var _collider_index := _read_s32()

	# Static target bound
	_skip(1)

	return ctrl

# =============================================================================
# CONTROLLER DATA READERS
# =============================================================================

## Read NiKeyframeData
func _read_ni_keyframe_data() -> Defs.NiKeyframeData:
	var data := Defs.NiKeyframeData.new()

	# Rotation keys
	var num_rot_keys := _read_u32()
	if num_rot_keys > 0:
		data.rotation_type = _read_u32()
		data.rotation_keys = _read_key_group(num_rot_keys, data.rotation_type, 4)

		# XYZ rotation keys - store separately for each axis
		if data.rotation_type == Defs.InterpolationType.XYZ:
			# X axis
			var num_x_keys := _read_u32()
			if num_x_keys > 0:
				var x_type := _read_u32()
				data.x_rotation_keys = _read_key_group(num_x_keys, x_type, 1)

			# Y axis
			var num_y_keys := _read_u32()
			if num_y_keys > 0:
				var y_type := _read_u32()
				data.y_rotation_keys = _read_key_group(num_y_keys, y_type, 1)

			# Z axis
			var num_z_keys := _read_u32()
			if num_z_keys > 0:
				var z_type := _read_u32()
				data.z_rotation_keys = _read_key_group(num_z_keys, z_type, 1)

	# Translation keys
	var num_trans_keys := _read_u32()
	if num_trans_keys > 0:
		data.translation_type = _read_u32()
		data.translation_keys = _read_key_group(num_trans_keys, data.translation_type, 3)

	# Scale keys
	var num_scale_keys := _read_u32()
	if num_scale_keys > 0:
		data.scale_type = _read_u32()
		data.scale_keys = _read_key_group(num_scale_keys, data.scale_type, 1)

	return data

## Read NiVisData
func _read_ni_vis_data() -> Defs.NiVisData:
	var data := Defs.NiVisData.new()

	var num_keys := _read_u32()
	for _i in range(num_keys):
		var time := _read_float()
		var visible := _read_u8() != 0
		data.keys.append({"time": time, "visible": visible})

	return data

## Read NiUVData
func _read_ni_uv_data() -> Defs.NiUVData:
	var data := Defs.NiUVData.new()

	# U translation
	data.u_translation_keys = _read_float_key_map()
	# V translation
	data.v_translation_keys = _read_float_key_map()
	# U scale
	data.u_scale_keys = _read_float_key_map()
	# V scale
	data.v_scale_keys = _read_float_key_map()

	return data

## Read NiFloatData
func _read_ni_float_data() -> Defs.NiFloatData:
	var data := Defs.NiFloatData.new()

	var num_keys := _read_u32()
	if num_keys > 0:
		data.key_type = _read_u32()
		data.keys = _read_key_group(num_keys, data.key_type, 1)

	return data

## Read NiColorData
func _read_ni_color_data() -> Defs.NiColorData:
	var data := Defs.NiColorData.new()

	var num_keys := _read_u32()
	if num_keys > 0:
		data.key_type = _read_u32()
		data.keys = _read_color_key_group(num_keys, data.key_type)

	return data


## Helper to read color animation key groups (separate from regular keys because colors are RGBA, not WXYZ quaternions)
func _read_color_key_group(num_keys: int, key_type: int) -> Array:
	var keys := []
	for _i in range(num_keys):
		var key := {}
		key["time"] = _read_float()
		key["value"] = _read_color4()

		# Additional data based on key type
		match key_type:
			Defs.InterpolationType.QUADRATIC:
				key["forward"] = _read_color4()
				key["backward"] = _read_color4()
			Defs.InterpolationType.TCB:
				key["tension"] = _read_float()
				key["continuity"] = _read_float()
				key["bias"] = _read_float()

		keys.append(key)

	return keys

## Read NiPosData
func _read_ni_pos_data() -> Defs.NiPosData:
	var data := Defs.NiPosData.new()

	var num_keys := _read_u32()
	if num_keys > 0:
		data.key_type = _read_u32()
		data.keys = _read_key_group(num_keys, data.key_type, 3)

	return data

## Read NiMorphData
func _read_ni_morph_data() -> Defs.NiMorphData:
	var data := Defs.NiMorphData.new()

	data.num_morphs = _read_u32()
	data.num_vertices = _read_u32()
	data.relative_targets = _read_u8()

	for _i in range(data.num_morphs):
		var morph := {}

		# Float keys for this morph
		# Note: For morph data, interpolation type is ALWAYS read (even if num_keys==0)
		# This differs from regular keyframes where type is only read if count > 0
		var num_keys := _read_u32()
		var key_type := _read_u32()  # Always read for morph keyframes
		morph["keys"] = _read_key_group(num_keys, key_type, 1) if num_keys > 0 else []

		# Vertex offsets
		var vertices := PackedVector3Array()
		vertices.resize(data.num_vertices)
		for j in range(data.num_vertices):
			vertices[j] = _read_vector3()
		morph["vertices"] = vertices

		data.morphs.append(morph)

	return data

## Helper to read a float key map
func _read_float_key_map() -> Array:
	var num_keys := _read_u32()
	if num_keys == 0:
		return []
	var key_type := _read_u32()
	return _read_key_group(num_keys, key_type, 1)

## Helper to read animation key groups
func _read_key_group(num_keys: int, key_type: int, value_size: int) -> Array:
	var keys := []
	for _i in range(num_keys):
		var key := {}
		key["time"] = _read_float()

		# Read value based on size
		match value_size:
			1:
				key["value"] = _read_float()
			3:
				key["value"] = _read_vector3()
			4:
				key["value"] = _read_quaternion()

		# Additional data based on key type
		match key_type:
			Defs.InterpolationType.QUADRATIC:
				match value_size:
					1:
						key["forward"] = _read_float()
						key["backward"] = _read_float()
					3:
						key["forward"] = _read_vector3()
						key["backward"] = _read_vector3()
					4:
						key["forward"] = _read_quaternion()
						key["backward"] = _read_quaternion()
			Defs.InterpolationType.TCB:
				key["tension"] = _read_float()
				key["continuity"] = _read_float()
				key["bias"] = _read_float()

		keys.append(key)

	return keys

# =============================================================================
# LIGHT READERS
# =============================================================================

## Read NiDynamicEffect fields (shared by lights and texture effects)
func _read_ni_dynamic_effect(obj: Defs.NiAVObject) -> void:
	_read_ni_av_object(obj)
	# Morrowind version reads affected nodes list
	var num_affected_nodes := _read_u32()
	_skip(num_affected_nodes * 4)  # Skip affected node indices

## Read NiLight (base) - NiAmbientLight, NiDirectionalLight
func _read_ni_light() -> Defs.NiLight:
	var light := Defs.NiLight.new()
	_read_ni_dynamic_effect(light)

	light.dimmer = _read_float()
	light.ambient_color = _read_color3()
	light.diffuse_color = _read_color3()
	light.specular_color = _read_color3()

	return light

## Read NiPointLight
func _read_ni_point_light() -> Defs.NiPointLight:
	var light := Defs.NiPointLight.new()
	_read_ni_dynamic_effect(light)

	light.dimmer = _read_float()
	light.ambient_color = _read_color3()
	light.diffuse_color = _read_color3()
	light.specular_color = _read_color3()

	light.constant_atten = _read_float()
	light.linear_atten = _read_float()
	light.quadratic_atten = _read_float()

	return light

## Read NiSpotLight
func _read_ni_spot_light() -> Defs.NiSpotLight:
	var light := Defs.NiSpotLight.new()
	_read_ni_dynamic_effect(light)

	light.dimmer = _read_float()
	light.ambient_color = _read_color3()
	light.diffuse_color = _read_color3()
	light.specular_color = _read_color3()

	light.constant_atten = _read_float()
	light.linear_atten = _read_float()
	light.quadratic_atten = _read_float()

	light.outer_spot_angle = _read_float()
	light.exponent = _read_float()

	return light

## Read NiCamera
func _read_ni_camera() -> Defs.NiCamera:
	var camera := Defs.NiCamera.new()
	_read_ni_av_object(camera)

	camera.frustum_left = _read_float()
	camera.frustum_right = _read_float()
	camera.frustum_top = _read_float()
	camera.frustum_bottom = _read_float()
	camera.frustum_near = _read_float()
	camera.frustum_far = _read_float()

	camera.viewport_left = _read_float()
	camera.viewport_right = _read_float()
	camera.viewport_top = _read_float()
	camera.viewport_bottom = _read_float()

	camera.lod_adjust = _read_float()

	# Scene pointer (unused)
	_skip(4)
	# Unused
	_skip(4)

	return camera

## Read NiTextureEffect - inherits from NiDynamicEffect
func _read_ni_texture_effect() -> Defs.NiTextureEffect:
	var effect := Defs.NiTextureEffect.new()
	_read_ni_dynamic_effect(effect)

	# NiTextureEffect fields
	effect.model_projection_matrix = _read_matrix3()
	effect.model_projection_translation = _read_vector3()
	effect.texture_filtering = _read_u32()
	effect.texture_clamping = _read_u32()
	effect.texture_type = _read_u32()
	effect.coord_gen_type = _read_u32()
	effect.source_texture_index = _read_s32()
	effect.clipping_plane_enable = _read_bool()  # Bool is 4 bytes for Morrowind
	effect.clipping_plane = Plane(_read_vector3(), _read_float())

	# PS2 specific (skip) - version <= 10.2.0.0
	_skip(4)

	# Unknown short - version <= 4.1.0.12 (includes Morrowind 4.0.0.2)
	_skip(2)

	return effect

# =============================================================================
# SKINNING READERS
# =============================================================================

## Read NiSkinInstance
func _read_ni_skin_instance() -> Defs.NiSkinInstance:
	var skin := Defs.NiSkinInstance.new()

	skin.data_index = _read_s32()
	skin.root_index = _read_s32()

	var num_bones := _read_u32()
	for _i in range(num_bones):
		skin.bone_indices.append(_read_s32())

	return skin

## Read NiSkinData
func _read_ni_skin_data() -> Defs.NiSkinData:
	var data := Defs.NiSkinData.new()

	# Skin transform
	data.skin_transform.rotation = _read_matrix3()
	data.skin_transform.translation = _read_vector3()
	data.skin_transform.scale = _read_float()

	var num_bones := _read_u32()

	# Morrowind version: read partition reference (version <= 10.1.0.0)
	# This is a ref to NiSkinPartition
	if _version == Defs.VER_MW:
		data.partition_index = _read_s32()
		# Note: hasVertexWeights is NOT read for Morrowind (version < 4.2.1.0)
		# It defaults to true

	for _i in range(num_bones):
		var bone := {}

		# Bone transform
		var bone_transform := Defs.NIFTransform.new()
		bone_transform.rotation = _read_matrix3()
		bone_transform.translation = _read_vector3()
		bone_transform.scale = _read_float()
		bone["transform"] = bone_transform

		# Bounding sphere
		bone["center"] = _read_vector3()
		bone["radius"] = _read_float()

		# Vertex weights
		var num_vertices := _read_u16()
		var weights := []
		for _j in range(num_vertices):
			weights.append({
				"vertex": _read_u16(),
				"weight": _read_float()
			})
		bone["weights"] = weights

		data.bones.append(bone)

	return data

## Read NiSkinPartition - optimized skin partition data
func _read_ni_skin_partition() -> Defs.NiSkinPartition:
	var partition := Defs.NiSkinPartition.new()

	var num_partitions := _read_u32()

	for _p in range(num_partitions):
		var part := {}

		var num_vertices := _read_u16()
		var num_triangles := _read_u16()
		var num_bones := _read_u16()
		var num_strips := _read_u16()
		var bones_per_vertex := _read_u16()

		# Bone indices for this partition
		var bones := PackedInt32Array()
		bones.resize(num_bones)
		for i in range(num_bones):
			bones[i] = _read_u16()
		part["bones"] = bones

		# For Morrowind (version 4.0.0.2), we don't have presence flags
		# All data is always present if counts are non-zero

		# Vertex map
		var vertex_map := PackedInt32Array()
		vertex_map.resize(num_vertices)
		for i in range(num_vertices):
			vertex_map[i] = _read_u16()
		part["vertex_map"] = vertex_map

		# Weights (bones_per_vertex floats per vertex)
		var weights := PackedFloat32Array()
		weights.resize(num_vertices * bones_per_vertex)
		for i in range(num_vertices * bones_per_vertex):
			weights[i] = _read_float()
		part["weights"] = weights

		# Strip lengths
		var strip_lengths := PackedInt32Array()
		strip_lengths.resize(num_strips)
		for i in range(num_strips):
			strip_lengths[i] = _read_u16()

		# Strips or triangles
		if num_strips > 0:
			var strips: Array[PackedInt32Array] = []
			for i in range(num_strips):
				var strip := PackedInt32Array()
				strip.resize(strip_lengths[i])
				for j in range(strip_lengths[i]):
					strip[j] = _read_u16()
				strips.append(strip)
			part["strips"] = strips
		else:
			# Direct triangle list
			var triangles := PackedInt32Array()
			triangles.resize(num_triangles * 3)
			for i in range(num_triangles * 3):
				triangles[i] = _read_u16()
			part["triangles"] = triangles

		# Bone indices per vertex (optional)
		var has_bone_indices := _read_u8()
		if has_bone_indices != 0:
			var bone_indices := PackedByteArray()
			bone_indices.resize(num_vertices * bones_per_vertex)
			for i in range(num_vertices * bones_per_vertex):
				bone_indices[i] = _read_u8()
			part["bone_indices"] = bone_indices

		part["num_vertices"] = num_vertices
		part["num_triangles"] = num_triangles
		part["num_bones"] = num_bones
		part["bones_per_vertex"] = bones_per_vertex

		partition.partitions.append(part)

	return partition

# =============================================================================
# PARTICLE MODIFIER READERS
# =============================================================================

## Read NiGravity
func _read_ni_gravity() -> Defs.NiGravity:
	var gravity := Defs.NiGravity.new()
	# NiParticleModifier base: next link + controller link (for Morrowind version >= 3.3.0.13)
	_skip(4)  # Next modifier link
	_skip(4)  # Controller link
	gravity.decay = _read_float()
	gravity.force = _read_float()
	gravity.gravity_type = _read_u32()
	gravity.position = _read_vector3()
	gravity.direction = _read_vector3()
	return gravity

## Read NiParticleGrowFade
func _read_ni_particle_grow_fade() -> Defs.NiParticleGrowFade:
	var gf := Defs.NiParticleGrowFade.new()
	# NiParticleModifier base: next link + controller link
	_skip(4)  # Next modifier link
	_skip(4)  # Controller link
	gf.grow_time = _read_float()
	gf.fade_time = _read_float()
	return gf

## Read NiParticleColorModifier
func _read_ni_particle_color_modifier() -> Defs.NiParticleColorModifier:
	var cm := Defs.NiParticleColorModifier.new()
	# NiParticleModifier base: next link + controller link
	_skip(4)  # Next modifier link
	_skip(4)  # Controller link
	cm.color_data_index = _read_s32()
	return cm

## Read NiParticleRotation
func _read_ni_particle_rotation() -> Defs.NiParticleRotation:
	var rot := Defs.NiParticleRotation.new()
	# NiParticleModifier base: next link + controller link
	_skip(4)  # Next modifier link
	_skip(4)  # Controller link
	rot.random_initial_axis = _read_u8() != 0  # Explicit uint8, not version-dependent bool
	rot.initial_axis = _read_vector3()
	rot.rotation_speed = _read_float()
	return rot

## Read NiPlanarCollider
func _read_ni_planar_collider() -> Defs.NiPlanarCollider:
	var col := Defs.NiPlanarCollider.new()
	# NiParticleModifier base: next link + controller link
	_skip(4)  # Next modifier link
	_skip(4)  # Controller link
	# NiParticleCollider fields
	col.bounce = _read_float()
	# Note: spawn/die flags only exist for version >= 4.2.0.2, Morrowind is 4.0.0.2
	# so we do NOT read them
	# NiPlanarCollider specific fields
	_skip(8)   # Extents (Vec2f - half-width, half-height)
	_skip(12)  # Position (Vec3f)
	_skip(12)  # X axis vector (Vec3f)
	_skip(12)  # Y axis vector (Vec3f)
	col.plane_normal = _read_vector3()
	col.plane_distance = _read_float()
	return col

## Read NiSphericalCollider
func _read_ni_spherical_collider() -> Defs.NiSphericalCollider:
	var col := Defs.NiSphericalCollider.new()
	# NiParticleModifier base: next link + controller link
	_skip(4)  # Next modifier link
	_skip(4)  # Controller link
	# NiParticleCollider fields
	col.bounce = _read_float()
	# Note: spawn/die flags only exist for version >= 4.2.0.2, Morrowind is 4.0.0.2
	# so we do NOT read them
	# NiSphericalCollider specific fields
	col.radius = _read_float()
	col.center = _read_vector3()
	return col

## Read NiParticleBomb
func _read_ni_particle_bomb() -> Defs.NiParticleBomb:
	var bomb := Defs.NiParticleBomb.new()
	# NiParticleModifier base: next link + controller link
	_skip(4)  # Next modifier link
	_skip(4)  # Controller link
	bomb.decay = _read_float()
	bomb.duration = _read_float()
	bomb.delta_v = _read_float()
	bomb.start_time = _read_float()
	bomb.decay_type = _read_u32()
	bomb.symmetry_type = _read_u32()
	bomb.position = _read_vector3()
	bomb.direction = _read_vector3()
	return bomb

# =============================================================================
# OTHER READERS
# =============================================================================

## Read NiRangeLODData
func _read_ni_range_lod_data() -> Defs.NiRangeLODData:
	var data := Defs.NiRangeLODData.new()

	data.lod_center = _read_vector3()

	var num_levels := _read_u32()
	for _i in range(num_levels):
		data.lod_levels.append({
			"min_range": _read_float(),
			"max_range": _read_float()
		})

	return data

## Read NiScreenLODData
func _read_ni_screen_lod_data() -> Defs.NiScreenLODData:
	var data := Defs.NiScreenLODData.new()

	data.bound_center = _read_vector3()
	data.bound_radius = _read_float()
	data.world_center = _read_vector3()
	data.world_radius = _read_float()

	var num_proportions := _read_u32()
	data.proportions.resize(num_proportions)
	for i in range(num_proportions):
		data.proportions[i] = _read_float()

	return data

## Read NiAlphaAccumulator/NiClusterAccumulator
## These inherit from Record (not NiObjectNET) and have no data - empty read
func _read_ni_accumulator() -> Defs.NIFRecord:
	var record := Defs.NIFRecord.new()
	# NiAccumulator::read() is empty in OpenMW - no data to read
	return record

## Read NiSequenceStreamHelper - inherits from NiObjectNET
func _read_ni_sequence_stream_helper() -> Defs.NiObjectNET:
	var record := Defs.NiObjectNET.new()
	_read_ni_object_net(record)
	return record

# =============================================================================
# BOUNDING VOLUME READER
# =============================================================================

## Read a BoundingVolume structure and return it
## Morrowind uses different bounding volume types for collision
func _read_bounding_volume(obj: Defs.NiAVObject) -> Defs.BoundingVolume:
	var bv := Defs.BoundingVolume.new()
	bv.type = _read_u32()

	match bv.type:
		Defs.BV_BASE:
			# No additional data
			pass

		Defs.BV_SPHERE:
			var sphere := Defs.BoundingSphere.new()
			sphere.center = _read_vector3()
			sphere.radius = _read_float()
			bv.sphere = sphere
			# Also set on obj for backward compatibility
			obj.bounding_sphere.center = sphere.center
			obj.bounding_sphere.radius = sphere.radius

		Defs.BV_BOX:
			var box := Defs.BoundingBox.new()
			box.center = _read_vector3()
			box.axes = _read_matrix3()
			box.extents = _read_vector3()
			bv.box = box

		Defs.BV_CAPSULE:
			var capsule := Defs.BoundingCapsule.new()
			capsule.center = _read_vector3()
			capsule.axis = _read_vector3()
			capsule.extent = _read_float()
			capsule.radius = _read_float()
			bv.capsule = capsule

		Defs.BV_LOZENGE:
			var lozenge := Defs.BoundingLozenge.new()
			lozenge.radius = _read_float()
			lozenge.extent0 = _read_float()
			lozenge.extent1 = _read_float()
			lozenge.center = _read_vector3()
			lozenge.axis0 = _read_vector3()
			lozenge.axis1 = _read_vector3()
			bv.lozenge = lozenge

		Defs.BV_UNION:
			# Union of child bounding volumes
			var num_children := _read_u32()
			for _i in range(num_children):
				# Recursively read child bounding volumes
				var dummy := Defs.NiAVObject.new()
				var child_bv := _read_bounding_volume(dummy)
				bv.children.append(child_bv)

		Defs.BV_HALFSPACE:
			var hs := Defs.BoundingHalfSpace.new()
			# Plane equation: normal.x, normal.y, normal.z, distance
			var plane_x := _read_float()
			var plane_y := _read_float()
			var plane_z := _read_float()
			var plane_d := _read_float()
			hs.plane = Plane(Vector3(plane_x, plane_y, plane_z), plane_d)
			hs.origin = _read_vector3()
			bv.half_space = hs

		_:
			push_warning("NIFReader: Unknown bounding volume type %d" % bv.type)

	return bv

# =============================================================================
# LOW-LEVEL READ FUNCTIONS
# =============================================================================

func _read_u8() -> int:
	if _pos >= _buffer.size():
		return 0
	var val := _buffer[_pos]
	_pos += 1
	return val

## Read boolean - for Morrowind (< 4.1.0.0), bools are stored as int32!
func _read_bool() -> bool:
	# Morrowind uses version 4.0.0.2, which stores booleans as 4-byte integers
	if _version < 0x04010000:  # 4.1.0.0
		return _read_s32() != 0
	else:
		return _read_u8() != 0

func _read_u16() -> int:
	if _pos + 2 > _buffer.size():
		return 0
	var val := _buffer.decode_u16(_pos)
	_pos += 2
	return val

func _read_s16() -> int:
	if _pos + 2 > _buffer.size():
		return 0
	var val := _buffer.decode_s16(_pos)
	_pos += 2
	return val

func _read_u32() -> int:
	if _pos + 4 > _buffer.size():
		return 0
	var val := _buffer.decode_u32(_pos)
	_pos += 4
	return val

func _read_s32() -> int:
	if _pos + 4 > _buffer.size():
		return 0
	var val := _buffer.decode_s32(_pos)
	_pos += 4
	return val

func _read_float() -> float:
	if _pos + 4 > _buffer.size():
		return 0.0
	var val := _buffer.decode_float(_pos)
	_pos += 4
	return val

func _read_vector3() -> Vector3:
	return Vector3(_read_float(), _read_float(), _read_float())

func _read_quaternion() -> Quaternion:
	# NIF uses WXYZ order
	var w := _read_float()
	var x := _read_float()
	var y := _read_float()
	var z := _read_float()
	return Quaternion(x, y, z, w)

func _read_matrix3() -> Basis:
	# Read 3x3 rotation matrix (row-major)
	var m := Basis()
	m.x = Vector3(_read_float(), _read_float(), _read_float())
	m.y = Vector3(_read_float(), _read_float(), _read_float())
	m.z = Vector3(_read_float(), _read_float(), _read_float())
	return m

func _read_color3() -> Color:
	return Color(_read_float(), _read_float(), _read_float(), 1.0)

func _read_color4() -> Color:
	return Color(_read_float(), _read_float(), _read_float(), _read_float())

func _read_string() -> String:
	var length := _read_u32()
	# Safety check: NIF strings should never be longer than 65535 chars
	# If we get a huge length, the parser is likely out of sync
	if length == 0 or length > 65535 or _pos + length > _buffer.size():
		if length > 65535 and not _parse_failed:
			push_error("NIFReader: Invalid string length %d at pos %d - parser out of sync" % [length, _pos])
			_parse_failed = true
		return ""
	var bytes := _buffer.slice(_pos, _pos + length)
	_pos += length
	return bytes.get_string_from_ascii()

func _read_line() -> String:
	# Read until newline or end of buffer
	var start := _pos
	while _pos < _buffer.size() and _buffer[_pos] != 0x0A:  # '\n'
		_pos += 1
	var line := _buffer.slice(start, _pos).get_string_from_ascii()
	if _pos < _buffer.size():
		_pos += 1  # Skip newline
	return line

func _skip(bytes: int) -> void:
	_pos += bytes
