## Path Grid Record (PGRD)
## Pathfinding grid for NPCs
## Ported from OpenMW components/esm3/loadpgrd.hpp
class_name PathgridRecord
extends ESMRecord

var cell_name: String  # Cell name (interior) or empty for exterior
var cell_x: int        # Cell X coordinate (exterior)
var cell_y: int        # Cell Y coordinate (exterior)
var granularity: int   # Grid granularity (unused?)

# Path points
var points: Array[Dictionary] = []  # {x, y, z, auto_generated, connection_count}

# Connections between points (edges)
var edges: Array[Dictionary] = []  # {point_a, point_b}

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_PGRD

static func get_record_type_name() -> String:
	return "PathGrid"

func load(esm: ESMReader) -> void:
	super.load(esm)

	cell_name = ""
	cell_x = 0
	cell_y = 0
	granularity = 0
	points.clear()
	edges.clear()

	var PGRP := ESMDefs.four_cc("PGRP")
	var PGRC := ESMDefs.four_cc("PGRC")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_NAME:
			cell_name = esm.get_h_string()
			record_id = cell_name
		elif sub_name == ESMDefs.SubRecordType.SREC_DATA:
			esm.get_sub_header()
			cell_x = esm.get_s32()
			cell_y = esm.get_s32()
			granularity = esm.get_u16()
			@warning_ignore("unused_variable")
			var point_count := esm.get_u16()
			if cell_name.is_empty():
				record_id = "%d,%d" % [cell_x, cell_y]
		elif sub_name == PGRP:
			_load_points(esm)
		elif sub_name == PGRC:
			_load_edges(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_points(esm: ESMReader) -> void:
	esm.get_sub_header()
	var size := esm.get_sub_size()
	@warning_ignore("integer_division")
	var point_count := size / 16  # Each point is 16 bytes

	for i in range(point_count):
		var point := {
			"x": esm.get_s32(),
			"y": esm.get_s32(),
			"z": esm.get_s32(),
			"auto_generated": esm.get_byte(),
			"connection_count": esm.get_byte(),
		}
		esm.get_u16()  # Padding
		points.append(point)

func _load_edges(esm: ESMReader) -> void:
	esm.get_sub_header()
	var size := esm.get_sub_size()
	@warning_ignore("integer_division")
	var edge_count := size / 4  # Each edge is 4 bytes (2x u16 indices)

	for i in range(edge_count):
		var edge := {
			"point_a": esm.get_u16(),
			"point_b": esm.get_u16(),
		}
		# Note: In ESM format, edges are stored per-point, but we store them
		# as undirected pairs. The connection_count field indicates how many
		# connections each point has.
		edges.append(edge)

func is_interior() -> bool:
	return not cell_name.is_empty()

func _to_string() -> String:
	return "PathGrid('%s', points=%d)" % [record_id, points.size()]
