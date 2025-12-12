## BSA Reader - Reads Bethesda Softworks Archive files (Morrowind format)
## Ported from OpenMW components/bsa/bsafile.cpp
class_name BSAReader
extends RefCounted

# Preload dependencies to ensure they work in headless mode
const Defs := preload("res://src/core/bsa/bsa_defs.gd")

## File entry class (defined locally to avoid cross-script issues in headless mode)
class FileEntry:
	var name: String           # Full path within archive (normalized)
	var name_hash: int         # 64-bit hash (low 32 + high 32)
	var hash_low: int          # Lower 32 bits of hash
	var hash_high: int         # Upper 32 bits of hash
	var size: int              # File size in bytes
	var offset: int            # Offset in data section (relative to data start)
	var absolute_offset: int   # Absolute offset in BSA file

	func _to_string() -> String:
		return "%s (size=%d, offset=%d)" % [name, size, offset]

# BSA Version constants (duplicated here for standalone use)
enum BSAVersion {
	UNKNOWN = 0,
	UNCOMPRESSED = 0x00000100,  # Morrowind BSA (TES3)
	COMPRESSED = 0x00415342,    # "BSA\0" - Oblivion/Skyrim BSA (TES4/TES5)
}

# Private state
var _file_path: String
var _version: int = BSAVersion.UNKNOWN
var _file_count: int = 0
var _data_offset: int = 0  # Where the actual file data begins

# Persistent file handle - kept open to avoid repeated open/close overhead
# This is a major performance optimization: opening a file is expensive (1-5ms)
# and with 100+ objects per cell, this adds up to seconds of I/O overhead
var _file_handle: FileAccess = null

# File entries indexed by normalized path
var _files_by_path: Dictionary = {}  # String -> FileEntry
# File entries indexed by hash for fast lookup
var _files_by_hash: Dictionary = {}  # int (combined hash) -> FileEntry
# Sorted list of all file entries
var _file_list: Array = []

## Returns true if the archive is open and ready
func is_open() -> bool:
	return _file_count > 0

## Get the file path of the open archive
func get_file_path() -> String:
	return _file_path

## Get the BSA version
func get_version() -> int:
	return _version

## Get the total number of files in the archive
func get_file_count() -> int:
	return _file_count

## Get list of all files in the archive
func get_file_list() -> Array:
	return _file_list

## Check if a file exists in the archive
func has_file(path: String) -> bool:
	var normalized := _normalize_path(path)
	return _files_by_path.has(normalized)

## Get file entry by path (returns null if not found)
func get_file_entry(path: String) -> FileEntry:
	var normalized := _normalize_path(path)
	return _files_by_path.get(normalized)

## Normalize a file path for BSA lookup (lowercase, backslashes)
static func _normalize_path(path: String) -> String:
	return path.to_lower().replace("/", "\\")

## Detect BSA version from file magic
static func _detect_version(magic: int) -> int:
	if magic == BSAVersion.UNCOMPRESSED:
		return BSAVersion.UNCOMPRESSED
	elif magic == BSAVersion.COMPRESSED:
		return BSAVersion.COMPRESSED
	else:
		return BSAVersion.UNKNOWN

## Open and read a BSA archive
## Returns OK on success, error code on failure
func open(path: String) -> Error:
	_file_path = path
	_files_by_path.clear()
	_files_by_hash.clear()
	_file_list.clear()
	_file_count = 0

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("BSAReader: Failed to open file: %s" % path)
		return FileAccess.get_open_error()

	var file_size := file.get_length()
	if file_size < 12:
		push_error("BSAReader: File too small to be a valid BSA: %s" % path)
		return ERR_FILE_CORRUPT

	# Read header (12 bytes for Morrowind BSA)
	var magic := file.get_32()
	_version = _detect_version(magic)

	if _version == BSAVersion.UNKNOWN:
		push_error("BSAReader: Unknown BSA version (magic=0x%08X): %s" % [magic, path])
		return ERR_FILE_UNRECOGNIZED

	if _version == BSAVersion.COMPRESSED:
		push_error("BSAReader: Compressed BSA (Oblivion/Skyrim) not yet supported: %s" % path)
		return ERR_FILE_UNRECOGNIZED

	# Morrowind uncompressed BSA format
	var dir_size := file.get_32()  # Size of directory section
	var num_files := file.get_32()
	_file_count = num_files

	# Validate header
	if num_files == 0:
		push_warning("BSAReader: Empty archive: %s" % path)
		return OK

	# Sanity check: directory can't be larger than file
	# OpenMW check: filenum * 21 > fsize - 12
	if num_files * 21 > file_size - 12:
		push_error("BSAReader: Directory too large for file size: %s" % path)
		return ERR_FILE_CORRUPT

	# Read directory
	var result := _read_directory(file, num_files, dir_size, file_size)

	# Keep file handle open for fast extraction (don't close!)
	# This dramatically improves performance by avoiding file open/close per extraction
	_file_handle = file

	return result

## Read the directory section of an uncompressed BSA
func _read_directory(file: FileAccess, num_files: int, dir_size: int, file_size: int) -> Error:
	# BSA archive layout:
	# - 12 bytes header: [id:4, dirsize:4, numfiles:4]
	# - Directory block (dirsize bytes):
	#   - File records: [size:4, offset:4] × num_files (8 bytes each)
	#   - Name offsets: [offset:4] × num_files (4 bytes each)
	#   - String table: null-terminated filenames (dirsize - 12*numfiles bytes)
	# - Hash table: [hash_low:4, hash_high:4] × num_files (8 bytes each)
	# - Data buffer: file contents

	var header_size := 12
	var file_records_size := num_files * 8
	var name_offsets_size := num_files * 4
	var hash_table_size := num_files * 8

	# String table size = dirsize - (file records + name offsets)
	# Note: hash table is OUTSIDE the directory block
	var string_table_size := dir_size - (file_records_size + name_offsets_size)

	if string_table_size <= 0:
		push_error("BSAReader: Invalid string table size: %d" % string_table_size)
		return ERR_FILE_CORRUPT

	# Calculate data section start (after header + directory + hash table)
	_data_offset = header_size + dir_size + hash_table_size

	# Read file records (size and offset for each file)
	var sizes: Array[int] = []
	var offsets: Array[int] = []
	sizes.resize(num_files)
	offsets.resize(num_files)

	for i in range(num_files):
		sizes[i] = file.get_32()
		offsets[i] = file.get_32()

	# Read name offsets
	var name_offsets: Array[int] = []
	name_offsets.resize(num_files)
	for i in range(num_files):
		name_offsets[i] = file.get_32()

	# Read entire string table
	var string_buffer := file.get_buffer(string_table_size)
	if string_buffer.size() != string_table_size:
		push_error("BSAReader: Failed to read string table")
		return ERR_FILE_CORRUPT

	# Read hash table (comes after the directory block)
	var hashes_low: Array[int] = []
	var hashes_high: Array[int] = []
	hashes_low.resize(num_files)
	hashes_high.resize(num_files)

	for i in range(num_files):
		hashes_low[i] = file.get_32()
		hashes_high[i] = file.get_32()

	# Build file entries
	for i in range(num_files):
		var entry := FileEntry.new()

		# Extract filename from string buffer
		var name_start := name_offsets[i]
		if name_start >= string_buffer.size():
			push_error("BSAReader: Invalid name offset for file %d" % i)
			continue

		# Find null terminator
		var name_end := name_start
		while name_end < string_buffer.size() and string_buffer[name_end] != 0:
			name_end += 1

		var name_bytes := string_buffer.slice(name_start, name_end)
		entry.name = name_bytes.get_string_from_ascii()

		entry.size = sizes[i]
		entry.offset = offsets[i]
		entry.absolute_offset = _data_offset + offsets[i]
		entry.hash_low = hashes_low[i]
		entry.hash_high = hashes_high[i]
		entry.name_hash = (hashes_high[i] << 32) | hashes_low[i]

		# Validate offset
		if entry.absolute_offset + entry.size > file_size:
			push_warning("BSAReader: File '%s' extends beyond archive bounds" % entry.name)
			continue

		# Store entry
		var normalized := _normalize_path(entry.name)
		_files_by_path[normalized] = entry
		_files_by_hash[entry.name_hash] = entry
		_file_list.append(entry)

	return OK

## Extract a file's raw data from the archive
## Returns PackedByteArray (empty on error)
func extract_file(path: String) -> PackedByteArray:
	var entry := get_file_entry(path)
	if entry == null:
		push_error("BSAReader: File not found in archive: %s" % path)
		return PackedByteArray()

	return extract_file_entry(entry)

## Extract file data using a FileEntry
## Uses persistent file handle for performance (avoids open/close per call)
func extract_file_entry(entry: FileEntry) -> PackedByteArray:
	if entry == null:
		return PackedByteArray()

	# Use persistent file handle if available (fast path)
	if _file_handle != null:
		_file_handle.seek(entry.absolute_offset)
		var data := _file_handle.get_buffer(entry.size)
		if data.size() != entry.size:
			push_error("BSAReader: Failed to read file data for: %s" % entry.name)
			return PackedByteArray()
		return data

	# Fallback: reopen file if handle was closed (shouldn't happen in normal use)
	var file := FileAccess.open(_file_path, FileAccess.READ)
	if file == null:
		push_error("BSAReader: Failed to reopen archive: %s" % _file_path)
		return PackedByteArray()

	file.seek(entry.absolute_offset)
	var data := file.get_buffer(entry.size)
	file.close()

	if data.size() != entry.size:
		push_error("BSAReader: Failed to read file data for: %s" % entry.name)
		return PackedByteArray()

	return data


## Close the persistent file handle (call when done with archive)
func close() -> void:
	if _file_handle != null:
		_file_handle.close()
		_file_handle = null

## List all files matching a glob pattern (e.g., "meshes/*.nif")
func find_files(pattern: String) -> Array:
	var results: Array = []
	var normalized_pattern := _normalize_path(pattern)

	for entry in _file_list:
		var normalized_name := _normalize_path(entry.name)
		if normalized_name.match(normalized_pattern):
			results.append(entry)

	return results

## List all files in a directory (non-recursive)
func list_directory(dir_path: String) -> Array:
	var results: Array = []
	var normalized_dir := _normalize_path(dir_path)
	if not normalized_dir.ends_with("\\"):
		normalized_dir += "\\"

	for entry in _file_list:
		var normalized_name := _normalize_path(entry.name)
		if normalized_name.begins_with(normalized_dir):
			# Check if it's directly in this directory (no more backslashes after dir prefix)
			var remainder := normalized_name.substr(normalized_dir.length())
			if "\\" not in remainder:
				results.append(entry)

	return results

## Get all unique directory paths in the archive
func get_directories() -> Array[String]:
	var dirs: Dictionary = {}
	for entry in _file_list:
		var path := _normalize_path(entry.name)
		var last_slash := path.rfind("\\")
		if last_slash > 0:
			var dir := path.substr(0, last_slash)
			# Add this directory and all parent directories
			while dir.length() > 0:
				dirs[dir] = true
				last_slash = dir.rfind("\\")
				if last_slash > 0:
					dir = dir.substr(0, last_slash)
				else:
					break

	var result: Array[String] = []
	for dir in dirs.keys():
		result.append(dir)
	result.sort()
	return result

## Get statistics about the archive
func get_stats() -> Dictionary:
	var total_size: int = 0
	var extensions: Dictionary = {}

	for entry in _file_list:
		total_size += entry.size
		var ext: String = entry.name.get_extension().to_lower()
		if ext not in extensions:
			extensions[ext] = {"count": 0, "size": 0}
		extensions[ext]["count"] += 1
		extensions[ext]["size"] += entry.size

	return {
		"file_count": _file_count,
		"total_size": total_size,
		"data_offset": _data_offset,
		"extensions": extensions
	}
