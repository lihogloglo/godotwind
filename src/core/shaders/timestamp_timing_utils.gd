@tool
class_name TimestampTimingUtils
extends RefCounted

const MICROSECONDS_PER_MS := 1000.0
const NANOSECONDS_PER_MS := 1000000.0


static func choose_delta_ms(
		begin_raw: int,
		end_raw: int,
		max_reasonable_ms: float,
		begin_cpu_raw: int = -1,
		end_cpu_raw: int = -1
) -> float:
	var chosen := choose_delta(begin_raw, end_raw, max_reasonable_ms, begin_cpu_raw, end_cpu_raw)
	return float(chosen.get("ms", -1.0))


static func microsecond_delta_ms(begin_raw: int, end_raw: int) -> float:
	if begin_raw < 0 or end_raw < 0 or end_raw < begin_raw:
		return -1.0
	return float(end_raw - begin_raw) / MICROSECONDS_PER_MS


static func choose_delta(
		begin_raw: int,
		end_raw: int,
		max_reasonable_ms: float,
		begin_cpu_raw: int = -1,
		end_cpu_raw: int = -1
) -> Dictionary:
	var result := {
		"ms": -1.0,
		"unit": "invalid",
		"micro_ms": -1.0,
		"nano_ms": -1.0,
		"cpu_ms": -1.0,
	}
	if begin_raw < 0 or end_raw < 0 or end_raw < begin_raw:
		return result
	var raw_delta := float(end_raw - begin_raw)
	var micro_ms := raw_delta / MICROSECONDS_PER_MS
	var nano_ms := raw_delta / NANOSECONDS_PER_MS
	result["micro_ms"] = micro_ms
	result["nano_ms"] = nano_ms
	if begin_cpu_raw >= 0 and end_cpu_raw >= begin_cpu_raw:
		result["cpu_ms"] = float(end_cpu_raw - begin_cpu_raw) / MICROSECONDS_PER_MS
	var micro_valid := _is_plausible(micro_ms, max_reasonable_ms)
	var nano_valid := _is_plausible(nano_ms, max_reasonable_ms)
	if not micro_valid and not nano_valid:
		return result
	if micro_valid and not nano_valid:
		result["ms"] = micro_ms
		result["unit"] = "microseconds"
		return result
	if nano_valid and not micro_valid:
		result["ms"] = nano_ms
		result["unit"] = "nanoseconds"
		return result
	var cpu_ms := float(result["cpu_ms"])
	if cpu_ms >= 0.0:
		if absf(micro_ms - cpu_ms) <= absf(nano_ms - cpu_ms):
			result["ms"] = micro_ms
			result["unit"] = "microseconds"
			return result
		result["ms"] = nano_ms
		result["unit"] = "nanoseconds"
		return result
	result["ms"] = minf(micro_ms, nano_ms)
	result["unit"] = "nanoseconds" if nano_ms <= micro_ms else "microseconds"
	return result


static func _is_plausible(value_ms: float, max_reasonable_ms: float) -> bool:
	return value_ms >= 0.0 and value_ms <= max_reasonable_ms
