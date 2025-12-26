## BSA Manager - Global singleton for managing BSA archives
## Provides unified access to files across multiple BSA archives
extends Node

# Preload dependencies
const BSAReaderScript := preload("res://src/core/bsa/bsa_reader.gd")

# Signals
signal archive_loaded(path: String, file_count: int)
signal archive_load_failed(path: String, error: String)
signal file_extracted(archive_path: String, file_path: String, size: int)

# Loaded archives (path -> BSAReader)
var _archives: Dictionary = {}
# File lookup cache (normalized path -> {archive: BSAReader, entry: FileEntry})
var _file_cache: Dictionary = {}
# Load order (later archives override earlier ones)
var _load_order: Array[String] = []

# Extracted data cache - stores frequently accessed file data in memory
# This avoids repeated disk reads for common models/textures
var _extracted_cache: Dictionary = {}  # normalized_path -> PackedByteArray
var _extracted_cache_size: int = 0     # Current cache size in bytes
const MAX_EXTRACTED_CACHE_SIZE := 256 * 1024 * 1024  # 256MB max cache
const MAX_CACHEABLE_FILE_SIZE := 2 * 1024 * 1024      # Only cache files < 2MB

# Thread safety: Mutex for extracted cache access
# This protects against concurrent access when async loading is enabled
var _cache_mutex: Mutex = null

# Statistics
var total_archives_loaded: int = 0
var total_files_indexed: int = 0
var cache_hits: int = 0
var cache_misses: int = 0


func _init() -> void:
	_cache_mutex = Mutex.new()

## Normalize a file path for BSA lookup (lowercase, backslashes)
static func _normalize_path(path: String) -> String:
	return path.to_lower().replace("/", "\\")

## Load a BSA archive and add it to the manager
## Later loaded archives take priority for file lookups
func load_archive(path: String) -> Error:
	if _archives.has(path):
		push_warning("BSAManager: Archive already loaded: %s" % path)
		return OK

	var reader: BSAReader = BSAReaderScript.new()
	var result: Error = reader.open(path)

	if result != OK:
		var error_msg := "Failed to open archive (error %d)" % result
		push_error("BSAManager: %s: %s" % [error_msg, path])
		archive_load_failed.emit(path, error_msg)
		return result

	_archives[path] = reader
	_load_order.append(path)
	total_archives_loaded += 1

	# Index files from this archive
	var file_count := 0
	for entry: BSAReader.FileEntry in reader.get_file_list():
		var normalized := _normalize_path(entry.name)
		# Later archives override earlier ones
		_file_cache[normalized] = {
			"archive": reader,
			"entry": entry,
			"archive_path": path
		}
		file_count += 1

	total_files_indexed = _file_cache.size()

	print("BSAManager: Loaded %s (%d files)" % [path.get_file(), file_count])
	archive_loaded.emit(path, file_count)
	return OK

## Unload a BSA archive
func unload_archive(path: String) -> void:
	if not _archives.has(path):
		return

	_archives.erase(path)
	_load_order.erase(path)
	total_archives_loaded -= 1

	# Rebuild file cache
	_rebuild_file_cache()

## Rebuild the file cache from all loaded archives
func _rebuild_file_cache() -> void:
	_file_cache.clear()

	for archive_path: String in _load_order:
		var reader: BSAReader = _archives[archive_path]
		for entry: BSAReader.FileEntry in reader.get_file_list():
			var normalized := _normalize_path(entry.name)
			_file_cache[normalized] = {
				"archive": reader,
				"entry": entry,
				"archive_path": archive_path
			}

	total_files_indexed = _file_cache.size()

## Check if a file exists in any loaded archive
func has_file(path: String) -> bool:
	var normalized := _normalize_path(path)
	return _file_cache.has(normalized)

## Get information about a file
func get_file_info(path: String) -> Dictionary:
	var normalized := _normalize_path(path)
	if not _file_cache.has(normalized):
		return {}

	var cached: Dictionary = _file_cache[normalized]
	var entry: BSAReader.FileEntry = cached["entry"]
	return {
		"path": entry.name,
		"size": entry.size,
		"archive": cached["archive_path"]
	}

## Extract a file from the archives
## Returns the raw file data as PackedByteArray
## Uses extracted data cache for frequently accessed files
## Thread-safe: Uses mutex to protect cache access
func extract_file(path: String) -> PackedByteArray:
	var normalized := _normalize_path(path)

	# Check extracted data cache first (fast path) - with mutex protection
	_cache_mutex.lock()
	if normalized in _extracted_cache:
		cache_hits += 1
		var cached_data: PackedByteArray = _extracted_cache[normalized]
		_cache_mutex.unlock()
		return cached_data

	cache_misses += 1
	_cache_mutex.unlock()

	if not _file_cache.has(normalized):
		push_error("BSAManager: File not found: %s" % path)
		return PackedByteArray()

	var cached: Dictionary = _file_cache[normalized]
	var reader: BSAReader = cached["archive"]
	var entry: BSAReader.FileEntry = cached["entry"]

	var data: PackedByteArray = reader.extract_file_entry(entry)
	if data.size() > 0:
		file_extracted.emit(cached["archive_path"], entry.name, data.size())

		# Cache small-to-medium files that are likely to be reused
		# (textures, common models, etc.)
		if data.size() <= MAX_CACHEABLE_FILE_SIZE:
			_cache_extracted_data(normalized, data)

	return data


## Cache extracted file data for fast reuse
## Thread-safe: Uses mutex to protect cache access
func _cache_extracted_data(normalized_path: String, data: PackedByteArray) -> void:
	_cache_mutex.lock()

	# Don't cache if already at limit
	if _extracted_cache_size >= MAX_EXTRACTED_CACHE_SIZE:
		_cache_mutex.unlock()
		return

	# Don't duplicate cache
	if normalized_path in _extracted_cache:
		_cache_mutex.unlock()
		return

	_extracted_cache[normalized_path] = data
	_extracted_cache_size += data.size()
	_cache_mutex.unlock()


## Clear the extracted data cache (frees memory)
## Thread-safe: Uses mutex to protect cache access
func clear_extracted_cache() -> void:
	_cache_mutex.lock()
	_extracted_cache.clear()
	_extracted_cache_size = 0
	cache_hits = 0
	cache_misses = 0
	_cache_mutex.unlock()


## Get extracted cache statistics
## Thread-safe: Uses mutex to protect cache access
func get_cache_stats() -> Dictionary:
	_cache_mutex.lock()
	var hit_rate := 0.0
	var total := cache_hits + cache_misses
	if total > 0:
		hit_rate = float(cache_hits) / float(total)

	var stats := {
		"cache_size_mb": _extracted_cache_size / (1024.0 * 1024.0),
		"cached_files": _extracted_cache.size(),
		"cache_hits": cache_hits,
		"cache_misses": cache_misses,
		"hit_rate": hit_rate,
	}
	_cache_mutex.unlock()
	return stats

## Find all files matching a pattern across all archives
func find_files(pattern: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var normalized_pattern := _normalize_path(pattern)

	for path: String in _file_cache.keys():
		if path.match(normalized_pattern):
			var cached: Dictionary = _file_cache[path]
			var entry: BSAReader.FileEntry = cached["entry"]
			results.append({
				"path": entry.name,
				"size": entry.size,
				"archive": cached["archive_path"]
			})

	return results

## Get all files with a specific extension
func get_files_by_extension(ext: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var target_ext := ext.to_lower()
	if not target_ext.begins_with("."):
		target_ext = "." + target_ext

	for path: String in _file_cache.keys():
		if path.ends_with(target_ext):
			var cached: Dictionary = _file_cache[path]
			var entry: BSAReader.FileEntry = cached["entry"]
			results.append({
				"path": entry.name,
				"size": entry.size,
				"archive": cached["archive_path"]
			})

	return results

## Get all unique directories across all archives
func get_all_directories() -> Array[String]:
	var dirs: Dictionary = {}

	for path_key: String in _file_cache.keys():
		var last_slash: int = path_key.rfind("\\")
		if last_slash > 0:
			var dir_path: String = path_key.substr(0, last_slash)
			while dir_path.length() > 0:
				dirs[dir_path] = true
				last_slash = dir_path.rfind("\\")
				if last_slash > 0:
					dir_path = dir_path.substr(0, last_slash)
				else:
					break

	var result: Array[String] = []
	for dir_key: String in dirs.keys():
		result.append(dir_key)
	result.sort()
	return result

## Get list of loaded archives
func get_loaded_archives() -> Array[String]:
	return _load_order.duplicate()

## Get number of loaded archives
func get_archive_count() -> int:
	return total_archives_loaded

## Get a specific archive reader
func get_archive(path: String) -> RefCounted:
	return _archives.get(path)

## Get combined statistics from all archives
func get_stats() -> Dictionary:
	var total_size: int = 0
	var extensions: Dictionary = {}

	for archive_path: String in _archives:
		var reader: BSAReader = _archives[archive_path]
		var stats: Dictionary = reader.get_stats()
		total_size += stats["total_size"]

		for ext: String in stats["extensions"]:
			if ext not in extensions:
				extensions[ext] = {"count": 0, "size": 0}
			extensions[ext]["count"] += stats["extensions"][ext]["count"]
			extensions[ext]["size"] += stats["extensions"][ext]["size"]

	return {
		"archives_loaded": total_archives_loaded,
		"total_files": total_files_indexed,
		"total_size": total_size,
		"extensions": extensions,
		"load_order": _load_order.duplicate(),
		# Include extraction cache stats
		"extracted_cache_size_mb": _extracted_cache_size / (1024.0 * 1024.0),
		"extracted_cache_files": _extracted_cache.size(),
		"cache_hits": cache_hits,
		"cache_misses": cache_misses,
	}

## Load all BSA files from a directory
func load_archives_from_directory(dir_path: String, pattern: String = "*.bsa") -> int:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("BSAManager: Failed to open directory: %s" % dir_path)
		return 0

	var loaded_count := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()

	while file_name != "":
		if not dir.current_is_dir() and file_name.to_lower().match(pattern.to_lower()):
			var full_path := dir_path.path_join(file_name)
			if load_archive(full_path) == OK:
				loaded_count += 1
		file_name = dir.get_next()

	dir.list_dir_end()
	return loaded_count

## Clear all loaded archives and caches
## Thread-safe: Uses mutex to protect cache access
func clear() -> void:
	# Close all archive file handles
	for archive_path: String in _archives:
		var reader: BSAReader = _archives[archive_path]
		if reader.has_method("close"):
			reader.close()

	_archives.clear()
	_file_cache.clear()
	_load_order.clear()

	# Clear extraction cache with mutex protection
	_cache_mutex.lock()
	_extracted_cache.clear()
	_extracted_cache_size = 0
	cache_hits = 0
	cache_misses = 0
	_cache_mutex.unlock()

	total_archives_loaded = 0
	total_files_indexed = 0
