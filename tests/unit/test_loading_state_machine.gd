## Unit tests for LoadingStateMachine — state transitions + predicate
## polling + timeout + signal emissions. Tests flip `pause_gameplay=false`
## on enter_loading() so the tree pause doesn't freeze the test runner
## itself (which is on the default PAUSABLE process_mode). The pause
## behaviour is a trivial `get_tree().paused = <bool>` call and is
## verified at runtime via the --bench-auto launches.
extends GdUnitTestSuite

const LoadingStateMachineScript := preload("res://src/core/loading/loading_state_machine.gd")


func _make_sm() -> LoadingStateMachineScript:
	var sm := LoadingStateMachineScript.new()
	sm.name = "LoadingStateMachineUnderTest"
	add_child(sm)
	return sm


func test_starts_idle() -> void:
	var sm := _make_sm()
	assert_bool(sm.is_loading()).is_false()
	assert_str(sm.get_current_reason()).is_empty()


func test_enter_loading_transitions_to_loading_state() -> void:
	var sm := _make_sm()
	sm.enter_loading(
		"test_boot",
		func() -> bool: return false,  # predicate never true — loading stays active
		"Loading Test",
		"",
		Callable(),
		30.0,
		false,  # fade_in=false — no extra delay before pause step
		false,  # pause_gameplay=false — keep test runner alive
	)
	# The state flow is ENTERING -> LOADING. With fade_in=false we go
	# straight into _pause_and_enter_loading() synchronously.
	assert_bool(sm.is_loading()).is_true()
	assert_str(sm.get_current_reason()).is_equal("test_boot")


func test_predicate_true_exits_state() -> void:
	var sm := _make_sm()
	var signal_fired := [false, 0.0, false]  # [received, duration_s, timed_out]
	sm.loading_finished.connect(func(reason: String, duration_s: float, timed_out: bool) -> void:
		signal_fired[0] = true
		signal_fired[1] = duration_s
		signal_fired[2] = timed_out)

	# Predicate flips true after 3 polls — lets us verify the exit path
	# fires via _process rather than the timeout fallback.
	var poll_count := [0]
	sm.enter_loading(
		"test_predicate",
		func() -> bool:
			poll_count[0] += 1
			return poll_count[0] >= 3,
		"", "", Callable(), 30.0, false, false,
	)

	# Wait up to 1 second for the state machine's _process to poll the
	# predicate + fire the exit signal. 10 × 100ms keeps the test fast
	# in the common case but tolerates slow CI.
	for _i in range(10):
		await get_tree().process_frame
		if signal_fired[0]:
			break
	assert_bool(signal_fired[0]).is_true()
	assert_bool(signal_fired[2]).is_false()  # timed_out=false — normal exit


func test_timeout_forces_exit() -> void:
	var sm := _make_sm()
	var got: Array = [false, false]
	sm.loading_finished.connect(func(_reason: String, _duration_s: float, timed_out: bool) -> void:
		got[0] = true
		got[1] = timed_out)

	# Predicate never true + 0.1s timeout → the timeout path fires.
	sm.enter_loading(
		"test_timeout",
		func() -> bool: return false,
		"", "", Callable(),
		0.1,   # timeout
		false, # fade_in
		false, # pause_gameplay
	)
	for _i in range(20):
		await get_tree().process_frame
		if got[0]:
			break
		await get_tree().create_timer(0.02).timeout
	assert_bool(got[0]).is_true()
	assert_bool(got[1]).is_true()  # timed_out=true


func test_loading_started_signal_fires_with_reason() -> void:
	var sm := _make_sm()
	var recv_reason := [""]
	sm.loading_started.connect(func(reason: String) -> void: recv_reason[0] = reason)
	sm.enter_loading(
		"fast_travel",
		func() -> bool: return true,  # immediate exit after the first _process
		"", "", Callable(), 30.0, false, false,
	)
	assert_str(recv_reason[0]).is_equal("fast_travel")


func test_double_enter_replaces_predicate_without_restarting() -> void:
	var sm := _make_sm()
	var started_count := [0]
	sm.loading_started.connect(func(_reason: String) -> void: started_count[0] += 1)

	sm.enter_loading(
		"first",
		func() -> bool: return false,
		"", "", Callable(), 30.0, false, false,
	)
	# Second call while still loading — must NOT re-fire loading_started.
	sm.enter_loading(
		"second",
		func() -> bool: return false,
		"", "", Callable(), 30.0, false, false,
	)
	# Give the state machine one process tick to settle.
	await get_tree().process_frame
	assert_int(started_count[0]).is_equal(1)
	# The reason label is updated to the latest enter_loading call even
	# though the signal didn't re-fire — this is how the caller retargets
	# the overlay mid-flow.
	assert_str(sm.get_current_reason()).is_equal("second")


func test_force_exit_from_loading_fires_timed_out_true() -> void:
	var sm := _make_sm()
	var got: Array = [false, false]
	sm.loading_finished.connect(func(_reason: String, _duration: float, timed_out: bool) -> void:
		got[0] = true
		got[1] = timed_out)

	sm.enter_loading(
		"shutdown",
		func() -> bool: return false,
		"", "", Callable(), 30.0, false, false,
	)
	sm.force_exit()
	# The signal is emitted synchronously inside force_exit → _exit_loading.
	assert_bool(got[0]).is_true()
	# force_exit maps to timed_out=true because it bypasses the predicate,
	# which semantically matches "the gate was not satisfied, we're just
	# leaving anyway".
	assert_bool(got[1]).is_true()
