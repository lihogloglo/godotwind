## ESM Header - File header record (TES3)
## Ported from OpenMW components/esm3/loadtes3.cpp
class_name ESMHeader
extends RefCounted

## Master file dependency
class MasterData:
	var name: String
	var size: int

	func _to_string() -> String:
		return "MasterData(%s, %d bytes)" % [name, size]

# Header data
var version_int: int     # Version as stored (IEEE 754 bits)
var version_float: float # Version as float (1.2 or 1.3)
var file_type: int       # 0 = ESP, 1 = ESM, 32 = ESS (save)
var author: String
var description: String
var record_count: int
var master_files: Array[MasterData]

# Format version (OpenMW extension, not in original files)
var format_version: int = 0

## Load header from ESM reader (assumes TES3 record header already read)
func load(esm: ESMReader) -> void:
	# Check for FORM subrecord (OpenMW format extension)
	if esm.is_next_sub(ESMDefs.four_cc("FORM")):
		var data := esm.get_h_t(4)
		format_version = data.decode_u32(0)

	# HEDR subrecord - main header data
	if esm.is_next_sub(ESMDefs.four_cc("HEDR")):
		esm.get_sub_header()

		version_int = esm.get_u32()
		version_float = _decode_version(version_int)
		file_type = esm.get_s32()
		author = esm.get_maybe_fixed_string(32)
		description = esm.get_maybe_fixed_string(256)
		record_count = esm.get_s32()

	# MAST/DATA pairs - master file dependencies
	master_files = []
	while esm.is_next_sub(ESMDefs.four_cc("MAST")):
		var master := MasterData.new()
		master.name = esm.get_h_string()

		# DATA subrecord contains file size
		var data := esm.get_hn_t(ESMDefs.four_cc("DATA"), 8)
		master.size = data.decode_u64(0)

		master_files.append(master)

	# GMDT - Game data (only in save files)
	if esm.is_next_sub(ESMDefs.four_cc("GMDT")):
		esm.skip_h_sub()  # Skip for now

	# SCRD - Screenshot data (only in save files)
	if esm.is_next_sub(ESMDefs.four_cc("SCRD")):
		esm.skip_h_sub()

	# SCRS - Screenshot (only in save files)
	if esm.is_next_sub(ESMDefs.four_cc("SCRS")):
		esm.skip_h_sub()

## Convert version int (IEEE 754 bits) to float
func _decode_version(bits: int) -> float:
	var bytes := PackedByteArray([
		bits & 0xFF,
		(bits >> 8) & 0xFF,
		(bits >> 16) & 0xFF,
		(bits >> 24) & 0xFF
	])
	return bytes.decode_float(0)

## Check if this is an ESM (master) file
func is_master() -> bool:
	return file_type == 1

## Check if this is an ESP (plugin) file
func is_plugin() -> bool:
	return file_type == 0

## Check if this is an ESS (save) file
func is_save() -> bool:
	return file_type == 32

func _to_string() -> String:
	var type_str := "ESM" if is_master() else ("ESP" if is_plugin() else "ESS")
	return "ESMHeader(v%.1f %s by '%s', %d records, %d masters)" % [
		version_float, type_str, author, record_count, master_files.size()
	]
