class_name StreamingPublicationBudget
extends RefCounted

const KNOWN_LANES: Array[String] = [
	"near_gameplay",
	"static_visuals",
	"hlod",
	"far_impostors",
	"distant_lights",
	"unload",
]

var frame_budget_usec: int = 2500
var _remaining_usec: int = 2500
var _spent_usec: int = 0
var _lane_claimed: Dictionary[String, int] = {}
var _lane_spent: Dictionary[String, int] = {}
var _lane_refunded: Dictionary[String, int] = {}
var _denied_claims: Dictionary[String, int] = {}


func begin_frame(budget_usec: int) -> void:
	frame_budget_usec = maxi(0, budget_usec)
	_remaining_usec = frame_budget_usec
	_spent_usec = 0
	_lane_claimed.clear()
	_lane_spent.clear()
	_lane_refunded.clear()
	_denied_claims.clear()


func can_run(minimum_usec: int = 1) -> bool:
	return _remaining_usec >= minimum_usec


func claim(lane: String, requested_usec: int) -> int:
	if not _is_known_lane(lane):
		_denied_claims[lane] = int(_denied_claims.get(lane, 0)) + 1
		return 0
	if requested_usec <= 0 or _remaining_usec <= 0:
		return 0
	var granted := mini(requested_usec, _remaining_usec)
	_remaining_usec -= granted
	_lane_claimed[lane] = int(_lane_claimed.get(lane, 0)) + granted
	return granted


func make_deadline(lane: String, requested_usec: int) -> int:
	var granted := claim(lane, requested_usec)
	if granted <= 0:
		return 0
	return Time.get_ticks_usec() + granted


func make_slice(lane: String, requested_usec: int) -> Dictionary:
	var granted := claim(lane, requested_usec)
	if granted <= 0:
		return {}
	return {
		"lane": lane,
		"granted_usec": granted,
		"deadline_usec": Time.get_ticks_usec() + granted,
	}


func refund(lane: String, unused_usec: int) -> void:
	if unused_usec <= 0 or not _is_known_lane(lane):
		return
	var active_claim := maxi(
		0,
		int(_lane_claimed.get(lane, 0))
			- int(_lane_refunded.get(lane, 0))
			- int(_lane_spent.get(lane, 0))
	)
	var refund_amount := mini(unused_usec, active_claim)
	_lane_refunded[lane] = int(_lane_refunded.get(lane, 0)) + refund_amount
	_remaining_usec = mini(frame_budget_usec, _remaining_usec + refund_amount)


func record_actual(lane: String, elapsed_usec: int) -> void:
	if not _is_known_lane(lane):
		_denied_claims[lane] = int(_denied_claims.get(lane, 0)) + 1
		return
	if elapsed_usec <= 0:
		return
	_spent_usec += elapsed_usec
	_lane_spent[lane] = int(_lane_spent.get(lane, 0)) + elapsed_usec


func get_stats() -> Dictionary:
	var lane_stats: Dictionary = {}
	for lane: String in KNOWN_LANES:
		var claimed := int(_lane_claimed.get(lane, 0))
		var spent := int(_lane_spent.get(lane, 0))
		var refunded := int(_lane_refunded.get(lane, 0))
		var active_claim := maxi(0, claimed - refunded)
		lane_stats[lane] = {
			"claimed_usec": claimed,
			"spent_usec": spent,
			"refunded_usec": refunded,
			"remaining_usec": maxi(0, active_claim - spent),
			"overrun_usec": maxi(0, spent - active_claim),
		}
	return {
		"publication_budget_usec": frame_budget_usec,
		"publication_remaining_usec": _remaining_usec,
		"publication_spent_usec": _spent_usec,
		"publication_lanes": lane_stats,
		"publication_denied_claims": _denied_claims.duplicate(),
	}


func _is_known_lane(lane: String) -> bool:
	return KNOWN_LANES.has(lane)
