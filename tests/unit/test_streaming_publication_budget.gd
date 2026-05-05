extends GdUnitTestSuite

const BudgetScript := preload("res://src/core/world/streaming_publication_budget.gd")


func test_claim_spend_refund_stats_are_per_lane() -> void:
	var budget := BudgetScript.new()
	budget.begin_frame(1000)

	assert_int(budget.claim("near_gameplay", 600)).is_equal(600)
	budget.record_actual("near_gameplay", 250)
	budget.refund("near_gameplay", 350)

	var stats: Dictionary = budget.get_stats()
	var lanes: Dictionary = stats["publication_lanes"]
	var near: Dictionary = lanes["near_gameplay"]
	assert_int(near["claimed_usec"]).is_equal(600)
	assert_int(near["spent_usec"]).is_equal(250)
	assert_int(near["refunded_usec"]).is_equal(350)
	assert_int(near["remaining_usec"]).is_equal(0)
	assert_int(stats["publication_remaining_usec"]).is_equal(750)


func test_unknown_lane_claims_fail_closed() -> void:
	var budget := BudgetScript.new()
	budget.begin_frame(1000)

	assert_int(budget.claim("mystery_lane", 500)).is_equal(0)
	budget.record_actual("mystery_lane", 100)

	var stats: Dictionary = budget.get_stats()
	assert_int(stats["publication_remaining_usec"]).is_equal(1000)
	assert_dict(stats["publication_denied_claims"]).contains_key_value("mystery_lane", 2)


func test_make_deadline_claims_from_shared_remaining_budget() -> void:
	var budget := BudgetScript.new()
	budget.begin_frame(300)

	var deadline := budget.make_deadline("hlod", 500)
	assert_bool(deadline > 0).is_true()

	var stats: Dictionary = budget.get_stats()
	var lanes: Dictionary = stats["publication_lanes"]
	assert_int(lanes["hlod"]["claimed_usec"]).is_equal(300)
	assert_int(stats["publication_remaining_usec"]).is_equal(0)
