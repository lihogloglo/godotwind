## ESM Definitions - Constants and types for ESM file parsing
## Ported from OpenMW components/esm/defs.hpp and components/esm/esmcommon.hpp
class_name ESMDefs
extends RefCounted

# ESM Version constants (as stored in file - IEEE 754 float bit patterns)
const VER_120: int = 0x3f99999a  # TES3 1.2
const VER_130: int = 0x3fa66666  # TES3 1.3

# Record flags
const FLAG_DELETED: int = 0x00000020
const FLAG_PERSISTENT: int = 0x00000400
const FLAG_IGNORED: int = 0x00001000
const FLAG_BLOCKED: int = 0x00002000

# Cell flags
const CELL_INTERIOR: int = 0x01
const CELL_HAS_WATER: int = 0x02
const CELL_NO_SLEEP: int = 0x04
const CELL_QUASI_EXTERIOR: int = 0x80

# Record type FourCC codes - these match what's in the ESM files
# Format: Convert 4-char string to little-endian 32-bit int
# e.g., "STAT" = 0x54415453
enum RecordType {
	REC_TES3 = 0x33534554,  # "TES3" - File header
	REC_GMST = 0x54534D47,  # "GMST" - Game setting
	REC_GLOB = 0x424F4C47,  # "GLOB" - Global variable
	REC_CLAS = 0x53414C43,  # "CLAS" - Class
	REC_FACT = 0x54434146,  # "FACT" - Faction
	REC_RACE = 0x45434152,  # "RACE" - Race
	REC_SOUN = 0x4E554F53,  # "SOUN" - Sound
	REC_SKIL = 0x4C494B53,  # "SKIL" - Skill
	REC_MGEF = 0x4645474D,  # "MGEF" - Magic effect
	REC_SCPT = 0x54504353,  # "SCPT" - Script
	REC_REGN = 0x4E474552,  # "REGN" - Region
	REC_BSGN = 0x4E475342,  # "BSGN" - Birthsign
	REC_LTEX = 0x5845544C,  # "LTEX" - Land texture
	REC_STAT = 0x54415453,  # "STAT" - Static
	REC_DOOR = 0x524F4F44,  # "DOOR" - Door
	REC_MISC = 0x4353494D,  # "MISC" - Misc item
	REC_WEAP = 0x50414557,  # "WEAP" - Weapon
	REC_CONT = 0x544E4F43,  # "CONT" - Container
	REC_SPEL = 0x4C455053,  # "SPEL" - Spell
	REC_CREA = 0x41455243,  # "CREA" - Creature
	REC_BODY = 0x59444F42,  # "BODY" - Body part
	REC_LIGH = 0x4847494C,  # "LIGH" - Light
	REC_ENCH = 0x48434E45,  # "ENCH" - Enchantment
	REC_NPC_ = 0x5F43504E,  # "NPC_" - NPC
	REC_ARMO = 0x4F4D5241,  # "ARMO" - Armor
	REC_CLOT = 0x544F4C43,  # "CLOT" - Clothing
	REC_REPA = 0x41504552,  # "REPA" - Repair item
	REC_ACTI = 0x49544341,  # "ACTI" - Activator
	REC_APPA = 0x41505041,  # "APPA" - Alchemy apparatus
	REC_LOCK = 0x4B434F4C,  # "LOCK" - Lockpick
	REC_PROB = 0x424F5250,  # "PROB" - Probe
	REC_INGR = 0x52474E49,  # "INGR" - Ingredient
	REC_BOOK = 0x4B4F4F42,  # "BOOK" - Book
	REC_ALCH = 0x48434C41,  # "ALCH" - Potion
	REC_LEVI = 0x4956454C,  # "LEVI" - Leveled item
	REC_LEVC = 0x4356454C,  # "LEVC" - Leveled creature
	REC_CELL = 0x4C4C4543,  # "CELL" - Cell
	REC_LAND = 0x444E414C,  # "LAND" - Landscape
	REC_PGRD = 0x44524750,  # "PGRD" - Path grid
	REC_SNDG = 0x47444E53,  # "SNDG" - Sound generator
	REC_DIAL = 0x4C414944,  # "DIAL" - Dialogue topic
	REC_INFO = 0x4F464E49,  # "INFO" - Dialogue entry
	REC_SSCR = 0x52435353,  # "SSCR" - Start script
}

# Subrecord type FourCC codes
enum SubRecordType {
	SREC_NAME = 0x454D414E,  # "NAME"
	SREC_DELE = 0x454C4544,  # "DELE"
	SREC_FNAM = 0x4D414E46,  # "FNAM"
	SREC_MODL = 0x4C444F4D,  # "MODL"
	SREC_DATA = 0x41544144,  # "DATA"
	SREC_HEDR = 0x52444548,  # "HEDR"
	SREC_MAST = 0x5453414D,  # "MAST"
	SREC_SCRI = 0x49524353,  # "SCRI"
	SREC_ITEX = 0x58455449,  # "ITEX"
	SREC_BNAM = 0x4D414E42,  # "BNAM"
	SREC_INTV = 0x56544E49,  # "INTV"
	SREC_INDX = 0x58444E49,  # "INDX"
}

## Convert a 4-character string to FourCC integer (little-endian)
static func four_cc(s: String) -> int:
	if s.length() != 4:
		push_error("FourCC requires exactly 4 characters")
		return 0
	var bytes := s.to_ascii_buffer()
	return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)

## Convert FourCC integer back to string
static func four_cc_to_string(code: int) -> String:
	var chars := PackedByteArray([
		code & 0xFF,
		(code >> 8) & 0xFF,
		(code >> 16) & 0xFF,
		(code >> 24) & 0xFF
	])
	return chars.get_string_from_ascii()

## Convert IEEE 754 bit pattern to float
static func bits_to_float(bits: int) -> float:
	var bytes := PackedByteArray([
		bits & 0xFF,
		(bits >> 8) & 0xFF,
		(bits >> 16) & 0xFF,
		(bits >> 24) & 0xFF
	])
	return bytes.decode_float(0)
