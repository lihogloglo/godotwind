## BSA Definitions - Constants and types for BSA archive parsing
## Ported from OpenMW components/bsa/bsafile.hpp
class_name BSADefs
extends RefCounted

# BSA Version identifiers (read from first 4 bytes)
enum BSAVersion {
	UNKNOWN = 0,
	UNCOMPRESSED = 0x00000100,  # Morrowind BSA (TES3)
	COMPRESSED = 0x00415342,    # "BSA\0" - Oblivion/Skyrim BSA (TES4/TES5)
}

# Compressed BSA version numbers (at offset 4)
const COMPRESSED_VERSION_TES4: int = 0x67  # 103 - Oblivion
const COMPRESSED_VERSION_FO3: int = 0x68   # 104 - Fallout 3
const COMPRESSED_VERSION_SSE: int = 0x69   # 105 - Skyrim SE

# Compressed BSA archive flags
const ARCHIVE_FLAG_FOLDER_NAMES: int = 0x0001
const ARCHIVE_FLAG_FILE_NAMES: int = 0x0002
const ARCHIVE_FLAG_COMPRESS: int = 0x0004
const ARCHIVE_FLAG_RETAIN_DIR: int = 0x0008
const ARCHIVE_FLAG_RETAIN_NAME: int = 0x0010
const ARCHIVE_FLAG_RETAIN_FOFF: int = 0x0020
const ARCHIVE_FLAG_XBOX360: int = 0x0040
const ARCHIVE_FLAG_STARTUP_STR: int = 0x0080
const ARCHIVE_FLAG_EMBEDDED_NAMES: int = 0x0100
const ARCHIVE_FLAG_XMEM: int = 0x0200

# Compressed BSA file type flags
const FILE_FLAG_MESHES: int = 0x0001      # .nif
const FILE_FLAG_TEXTURES: int = 0x0002    # .dds
const FILE_FLAG_MENUS: int = 0x0004       # .xml
const FILE_FLAG_SOUNDS: int = 0x0008      # .wav
const FILE_FLAG_VOICES: int = 0x0010      # .mp3
const FILE_FLAG_SHADERS: int = 0x0020     # .sdp (unused)
const FILE_FLAG_TREES: int = 0x0040       # .spt
const FILE_FLAG_FONTS: int = 0x0080       # .fnt
const FILE_FLAG_MISC: int = 0x0100

# File size compression flag (for compressed BSA)
const FILE_SIZE_COMPRESS_FLAG: int = 0x40000000

## File entry structure for uncompressed BSA (Morrowind)
## Represents a single file within the archive
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

## Detect BSA version from file magic
static func detect_version(magic: int) -> BSAVersion:
	if magic == BSAVersion.UNCOMPRESSED:
		return BSAVersion.UNCOMPRESSED
	elif magic == BSAVersion.COMPRESSED:
		return BSAVersion.COMPRESSED
	else:
		return BSAVersion.UNKNOWN

## Calculate hash for uncompressed BSA (Morrowind format)
## Based on OpenMW bsafile.cpp getHash() function
static func calculate_hash(filename: String) -> Dictionary:
	# Normalize: lowercase and use backslashes
	var name := filename.to_lower().replace("/", "\\")
	var length := name.length()
	var half := length >> 1  # Integer division by 2

	var hash_low: int = 0
	var hash_high: int = 0
	var sum: int = 0
	var off: int = 0
	var temp: int
	var n: int

	# First half: XOR with shift
	for i in range(half):
		sum ^= (name.unicode_at(i) << (off & 0x1F))
		off += 8
	hash_low = sum

	# Second half: XOR with rotate right
	sum = 0
	off = 0
	for i in range(half, length):
		temp = (name.unicode_at(i) << (off & 0x1F))
		sum ^= temp
		n = temp & 0x1F
		if n > 0:
			sum = ((sum >> n) | (sum << (32 - n))) & 0xFFFFFFFF  # Rotate right
		off += 8
	hash_high = sum

	return {
		"low": hash_low & 0xFFFFFFFF,
		"high": hash_high & 0xFFFFFFFF,
		"combined": ((hash_high & 0xFFFFFFFF) << 32) | (hash_low & 0xFFFFFFFF)
	}

## Normalize a file path for BSA lookup (lowercase, backslashes)
static func normalize_path(path: String) -> String:
	return path.to_lower().replace("/", "\\")
