## Container Record (CONT)
## Containers hold items
## Ported from OpenMW components/esm3/loadcont.cpp
class_name ContainerRecord
extends ESMRecord

# Container flags
const FLAG_ORGANIC: int = 0x0001    # Organic container (like plants)
const FLAG_RESPAWNS: int = 0x0002   # Contents respawn

# Item in container
class ContainerItem:
	var count: int
	var item_id: String

var name: String           # Display name
var model: String          # Path to NIF model
var script_id: String         # Script ID
var weight: float          # Weight capacity
var flags: int             # Container flags
var items: Array[ContainerItem]

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_CONT

static func get_record_type_name() -> String:
	return "Container"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	name = ""
	model = ""
	script_id = ""
	weight = 0.0
	flags = 0
	items = []

	# NAME - object ID
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Pre-compute FourCC values
	var CNDT := ESMDefs.four_cc("CNDT")  # Container data
	var FLAG := ESMDefs.four_cc("FLAG")  # Container flags
	var NPCO := ESMDefs.four_cc("NPCO")  # Container item

	# Load the rest
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_MODL:
			model = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_SCRI:
			script_id = esm.get_h_string()
		elif sub_name == CNDT:
			var data := esm.get_h_t(4)
			weight = data.decode_float(0)
		elif sub_name == FLAG:
			var data := esm.get_h_t(4)
			flags = data.decode_s32(0)
		elif sub_name == NPCO:
			_load_item(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_item(esm: ESMReader) -> void:
	esm.get_sub_header()

	var item := ContainerItem.new()
	item.count = esm.get_s32()

	# Item ID is 32 bytes, null-terminated
	item.item_id = esm.get_string(32)

	items.append(item)

## Check container flags
func is_organic() -> bool:
	return (flags & FLAG_ORGANIC) != 0

func respawns() -> bool:
	return (flags & FLAG_RESPAWNS) != 0

func _to_string() -> String:
	return "Container('%s', items=%d)" % [record_id, items.size()]
