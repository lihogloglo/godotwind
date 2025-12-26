## NIFParseResult - Container for parsed NIF data
## Used to transfer parsed NIF data from worker threads to main thread
## The reader is already parsed and ready for instantiation
class_name NIFParseResult
extends RefCounted

## The parsed NIFReader instance with records and roots populated
## Can be either GDScript Reader or C# NIFReader (native)
var reader: RefCounted = null  # NIFReader type, using RefCounted for forward reference

## Whether the reader is the native C# NIFReader (faster) or GDScript Reader
var is_native: bool = false

## Original file path (for caching and error messages)
var path: String = ""

## Whether parsing succeeded
var success: bool = false

## Error message if parsing failed
var error: String = ""

## Hash of the source buffer (for cache key generation)
var buffer_hash: int = 0

## Item ID for collision shape library lookups (optional)
var item_id: String = ""

## Configuration flags that were used during parsing
var load_textures: bool = true
var load_animations: bool = false
var load_collision: bool = true
var collision_mode: int = 0
var auto_collision_mode: bool = true


## Create a successful parse result
static func create_success(nif_reader: RefCounted, file_path: String, native: bool = false) -> NIFParseResult:
	var result := NIFParseResult.new()
	result.reader = nif_reader
	result.path = file_path
	result.success = true
	result.is_native = native
	return result


## Create a failed parse result
static func create_failure(file_path: String, error_msg: String) -> NIFParseResult:
	var result := NIFParseResult.new()
	result.path = file_path
	result.success = false
	result.error = error_msg
	return result


## Check if result is valid for instantiation
func is_valid() -> bool:
	return success and reader != null


## Get a cache key for this parsed result
func get_cache_key() -> String:
	if not item_id.is_empty():
		return path.to_lower().replace("/", "\\") + ":" + item_id.to_lower()
	return path.to_lower().replace("/", "\\")
