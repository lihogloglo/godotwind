## Region Record (REGN)
## World region definitions with weather
## Ported from OpenMW components/esm3/loadregn.hpp
class_name RegionRecord
extends ESMRecord

var name: String
var sleep_creature_list: String  # Leveled list for sleep encounters

# WEAT subrecord (10 bytes) - weather probabilities that sum to 100
var weather_clear: int
var weather_cloudy: int
var weather_foggy: int
var weather_overcast: int
var weather_rain: int
var weather_thunder: int
var weather_ash: int
var weather_blight: int
var weather_snow: int
var weather_blizzard: int

# Map color (CNAM, 4 bytes RGBA)
var map_color: Color

# Sound references (SNAM subrecords)
var sounds: Array[Dictionary] = []  # {sound_id, chance}

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_REGN

static func get_record_type_name() -> String:
	return "Region"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	sleep_creature_list = ""
	weather_clear = 0
	weather_cloudy = 0
	weather_foggy = 0
	weather_overcast = 0
	weather_rain = 0
	weather_thunder = 0
	weather_ash = 0
	weather_blight = 0
	weather_snow = 0
	weather_blizzard = 0
	map_color = Color.WHITE
	sounds.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var WEAT := ESMDefs.four_cc("WEAT")
	var CNAM := ESMDefs.four_cc("CNAM")
	var SNAM := ESMDefs.four_cc("SNAM")
	var BNAM := ESMDefs.SubRecordType.SREC_BNAM

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == WEAT:
			_load_weather(esm)
		elif sub_name == BNAM:
			sleep_creature_list = esm.get_h_string()
		elif sub_name == CNAM:
			esm.get_sub_header()
			var r := esm.get_byte()
			var g := esm.get_byte()
			var b := esm.get_byte()
			esm.get_byte()  # Alpha (unused)
			map_color = Color(r / 255.0, g / 255.0, b / 255.0)
		elif sub_name == SNAM:
			_load_sound_ref(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_weather(esm: ESMReader) -> void:
	esm.get_sub_header()
	weather_clear = esm.get_byte()
	weather_cloudy = esm.get_byte()
	weather_foggy = esm.get_byte()
	weather_overcast = esm.get_byte()
	weather_rain = esm.get_byte()
	weather_thunder = esm.get_byte()
	weather_ash = esm.get_byte()
	weather_blight = esm.get_byte()
	# Snow/Blizzard only in Bloodmoon
	if esm.get_sub_size() >= 10:
		weather_snow = esm.get_byte()
		weather_blizzard = esm.get_byte()

func _load_sound_ref(esm: ESMReader) -> void:
	esm.get_sub_header()
	var size := esm.get_sub_size()
	# Sound name is 32 bytes, then 1 byte chance
	var sound_name := esm.get_string(32)
	var chance := esm.get_byte()
	sounds.append({"sound": sound_name, "chance": chance})

func _to_string() -> String:
	return "Region('%s', sounds=%d)" % [record_id, sounds.size()]
