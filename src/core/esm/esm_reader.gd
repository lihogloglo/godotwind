## ESM Reader - Binary reader for Elder Scrolls Master/Plugin files
## Ported from OpenMW components/esm3/esmreader.cpp
class_name ESMReader
extends RefCounted

# File handle
var _file: FileAccess
var _file_path: String
var _file_size: int

# Reading context
var _left_file: int  # Bytes left in file
var _left_rec: int   # Bytes left in current record
var _left_sub: int   # Bytes left in current subrecord
var _rec_name: int   # Current record name (FourCC)
var _sub_name: int   # Current subrecord name (FourCC)
var _sub_cached: bool  # True if subname was read but not consumed
var _record_flags: int

# Header data (populated after open())
var header: ESMHeader

# Character encoding for strings (Windows-1252 by default for Western Morrowind)
var _encoding: String = "latin1"

## Open an ESM/ESP file and parse its header
func open(path: String) -> Error:
	close()

	_file = FileAccess.open(path, FileAccess.READ)
	if _file == null:
		push_error("Failed to open file: %s (error: %s)" % [path, FileAccess.get_open_error()])
		return FileAccess.get_open_error()

	_file_path = path
	_file_size = _file.get_length()
	_left_file = _file_size
	_left_rec = 0
	_left_sub = 0
	_sub_cached = false

	# First record must be TES3
	var rec_name := get_rec_name()
	if rec_name != ESMDefs.RecordType.REC_TES3:
		push_error("Not a valid Morrowind file: expected TES3, got %s" % ESMDefs.four_cc_to_string(rec_name))
		close()
		return ERR_FILE_UNRECOGNIZED

	get_rec_header()

	# Parse header
	header = ESMHeader.new()
	header.load(self)

	return OK

## Close the file
func close() -> void:
	if _file != null:
		_file.close()
		_file = null
	_file_path = ""
	_file_size = 0
	_left_file = 0
	_left_rec = 0
	_left_sub = 0
	_sub_cached = false
	header = null

## Check if file is open
func is_open() -> bool:
	return _file != null

## Get the file path
func get_file_path() -> String:
	return _file_path

## Get current file position
func get_file_offset() -> int:
	return _file.get_position() if _file else 0

## Get file size
func get_file_size() -> int:
	return _file_size

## Get record flags of last record
func get_record_flags() -> int:
	return _record_flags

## Check if there are more records in the file
func has_more_recs() -> bool:
	return _left_file > 0

## Check if there are more subrecords in the current record
func has_more_subs() -> bool:
	return _left_rec > 0

## Get the name of the current record
func get_current_rec_name() -> int:
	return _rec_name

## Get the name of the current subrecord
func get_current_sub_name() -> int:
	return _sub_name

## Cache the current subrecord name so it can be re-read by get_sub_name()
## Used when a record needs to "put back" a subrecord for another handler
func cache_sub_name() -> void:
	_sub_cached = true

## Get subrecord size
func get_sub_size() -> int:
	return _left_sub

#region Low-level reading

## Read raw bytes
func get_exact(size: int) -> PackedByteArray:
	return _file.get_buffer(size)

## Read a single unsigned byte
func get_byte() -> int:
	return _file.get_8()

## Read a signed 8-bit integer
func get_s8() -> int:
	var val := _file.get_8()
	if val >= 128:
		val -= 256
	return val

## Read unsigned 16-bit integer (little-endian)
func get_u16() -> int:
	return _file.get_16()

## Read signed 16-bit integer (little-endian)
func get_s16() -> int:
	var val := _file.get_16()
	if val >= 32768:
		val -= 65536
	return val

## Read unsigned 32-bit integer (little-endian)
func get_u32() -> int:
	return _file.get_32()

## Read signed 32-bit integer (little-endian)
func get_s32() -> int:
	var val := _file.get_32()
	if val >= 2147483648:
		val -= 4294967296
	return int(val)

## Read unsigned 64-bit integer (little-endian)
func get_u64() -> int:
	return _file.get_64()

## Read 32-bit float (little-endian)
func get_float() -> float:
	return _file.get_float()

## Read a FourCC name (4 bytes as int)
func get_name() -> int:
	return _file.get_32()

## Skip bytes
func skip(bytes: int) -> void:
	_file.seek(_file.get_position() + bytes)

#endregion

#region Record-level reading

## Get the next record name
func get_rec_name() -> int:
	if not has_more_recs():
		push_error("No more records")
		return 0

	if has_more_subs():
		push_error("Previous record has unread subrecords")

	# Handle case where we read past record boundary
	if _left_rec < 0:
		skip(_left_rec)  # Go back

	_rec_name = get_name()
	_left_file -= 4
	_sub_cached = false

	return _rec_name

## Record end position (for robust error recovery)
var _rec_end_pos: int = 0

## Read record header (size and flags)
func get_rec_header() -> void:
	if _left_file < 12:
		push_error("End of file while reading record header")
		return

	_left_rec = get_u32()  # Record size
	get_u32()  # Unknown (always 0)
	_record_flags = get_u32()
	_left_file -= 12

	if _left_file < _left_rec:
		push_error("Record size exceeds file bounds")

	_left_file -= _left_rec

	# Track where record ends for robust recovery
	_rec_end_pos = _file.get_position() + _left_rec

## Skip the rest of the current record
func skip_record() -> void:
	# Use absolute position for robust recovery
	if _rec_end_pos > 0 and _file.get_position() != _rec_end_pos:
		_file.seek(_rec_end_pos)
	elif _left_rec > 0:
		skip(_left_rec)
	_left_rec = 0
	_sub_cached = false

## Get record end position (for debugging)
func get_rec_end_pos() -> int:
	return _rec_end_pos

#endregion

#region Subrecord-level reading

## Get the next subrecord name
func get_sub_name() -> void:
	if _sub_cached:
		_sub_cached = false
		return

	_sub_name = get_name()
	_left_rec -= 4

## Get subrecord header (reads the size)
func get_sub_header() -> void:
	if _left_rec < 4:
		push_error("End of record while reading subrecord header")
		return

	_left_sub = get_u32()
	_left_rec -= 4
	_left_rec -= _left_sub

## Check if the next subrecord has the given name
func is_next_sub(name: int) -> bool:
	if not has_more_subs():
		return false

	get_sub_name()

	if _sub_name != name:
		_sub_cached = true
		return false

	return true

## Get subrecord name and verify it matches
func get_sub_name_is(name: int) -> void:
	get_sub_name()
	if _sub_name != name:
		push_error("Expected subrecord %s, got %s" % [
			ESMDefs.four_cc_to_string(name),
			ESMDefs.four_cc_to_string(_sub_name)
		])

## Skip the current subrecord (header already read, skip data)
func skip_h_sub() -> void:
	get_sub_header()
	skip(_left_sub)

#endregion

#region High-level reading (typed data with subrecord header)

## Read a string with subrecord header
func get_h_string() -> String:
	get_sub_header()
	return get_string(_left_sub)

## Read a string by subrecord name
func get_hn_string(name: int) -> String:
	get_sub_name_is(name)
	return get_h_string()

## Optionally read a string by subrecord name
func get_hno_string(name: int) -> String:
	if is_next_sub(name):
		return get_h_string()
	return ""

## Read typed data with subrecord header
## Returns the raw bytes, caller is responsible for interpretation
func get_h_t(expected_size: int) -> PackedByteArray:
	get_sub_header()
	if _left_sub != expected_size:
		push_error("Subrecord size mismatch: expected %d, got %d" % [expected_size, _left_sub])
	return get_exact(_left_sub)

## Read typed data by subrecord name
func get_hn_t(name: int, expected_size: int) -> PackedByteArray:
	get_sub_name_is(name)
	return get_h_t(expected_size)

## Optionally read typed data by subrecord name
func get_hno_t(name: int, expected_size: int) -> PackedByteArray:
	if is_next_sub(name):
		return get_h_t(expected_size)
	return PackedByteArray()

#endregion

#region String reading

## Read a fixed-size string (null-terminated within buffer)
func get_string(size: int) -> String:
	if size == 0:
		return ""

	var bytes := get_exact(size)

	# Find null terminator
	var null_pos := -1
	for i in range(bytes.size()):
		if bytes[i] == 0:
			null_pos = i
			break

	if null_pos >= 0:
		bytes = bytes.slice(0, null_pos)

	# Convert from Windows-1252 (Latin-1 is close enough for most purposes)
	return bytes.get_string_from_ascii()

## Read a maybe-fixed-size string (for format version compatibility)
## In older formats, strings have fixed sizes. In newer formats, they're prefixed with length.
func get_maybe_fixed_string(size: int) -> String:
	# For original Morrowind format, strings are fixed size
	return get_string(size)

#endregion

#region Error handling

func fail(msg: String) -> void:
	var error_msg := "ESM Error: %s\n  File: %s\n  Record: %s\n  Subrecord: %s\n  Offset: 0x%X" % [
		msg,
		_file_path,
		ESMDefs.four_cc_to_string(_rec_name),
		ESMDefs.four_cc_to_string(_sub_name),
		get_file_offset()
	]
	push_error(error_msg)

#endregion
