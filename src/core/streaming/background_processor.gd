## BackgroundProcessor - Manages CPU-intensive work on worker threads
## Uses Godot's WorkerThreadPool for parallel task execution
## Results are safely delivered to main thread via call_deferred
class_name BackgroundProcessor
extends Node

signal task_completed(task_id: int, result: Variant)
signal task_failed(task_id: int, error: String)

## Maximum time (ms) before a running task is considered hung
## Can't actually kill the worker thread, but frees the slot for new tasks
const TASK_TIMEOUT_MS := 30000  # 30 seconds

## Task entry for tracking
class TaskEntry:
	var id: int
	var callable: Callable
	var priority: float
	var group_task_id: int = -1  # WorkerThreadPool task ID
	var cancelled: bool = false
	var started: bool = false
	var start_time_msec: int = 0  # When task started executing

## Next task ID
var _next_task_id: int = 1

## Pending tasks (priority queue, lower priority value = higher priority)
var _pending_tasks: Array[TaskEntry] = []

## Active tasks (currently running on workers)
var _active_tasks: Dictionary = {}  # task_id -> TaskEntry

## Completed results waiting for main thread dispatch
var _completed_results: Array = []  # Array of {task_id, result, error}

## Timed-out WTP handles that still need cleanup when the worker eventually finishes
var _orphaned_wtp_handles: Array[int] = []

## Mutex for thread-safe access to completed results
var _results_mutex: Mutex

## Maximum concurrent tasks (0 = auto based on CPU cores)
@export var max_concurrent_tasks: int = 0

## Actual concurrent task limit after initialization
var _concurrent_limit: int = 4

## Whether the processor is running
var _running: bool = false


func _ready() -> void:
	_results_mutex = Mutex.new()

	# Auto-detect concurrent limit based on CPU cores
	if max_concurrent_tasks <= 0:
		_concurrent_limit = maxi(1, OS.get_processor_count() - 1)
	else:
		_concurrent_limit = max_concurrent_tasks

	_running = true
	Log.info("threading", "BackgroundProcessor initialized with %d concurrent task limit" % _concurrent_limit)


func _exit_tree() -> void:
	_running = false
	# If quitting, fast_cleanup already cleared everything — bail immediately
	# WTP handles are abandoned; the OS reclaims them when the process exits
	if Engine.has_meta("_quitting"):
		return
	# Only wait for COMPLETED tasks (instant) — don't block on in-progress ones
	# Blocking on disk I/O tasks causes the freeze on Alt+F4
	for task_id: int in _active_tasks:
		var task: TaskEntry = _active_tasks[task_id]
		if task.group_task_id >= 0 and WorkerThreadPool.is_task_completed(task.group_task_id):
			WorkerThreadPool.wait_for_task_completion(task.group_task_id)
	_active_tasks.clear()
	_pending_tasks.clear()
	# Clean up completed orphaned handles only
	for handle: int in _orphaned_wtp_handles:
		if WorkerThreadPool.is_task_completed(handle):
			WorkerThreadPool.wait_for_task_completion(handle)
	_orphaned_wtp_handles.clear()


func _process(_delta: float) -> void:
	# Check for timed-out tasks before dispatching results
	_check_task_timeouts()

	# Dispatch completed results on main thread
	_dispatch_completed_results()

	# Clean up orphaned WTP handles from timed-out tasks that eventually finished
	_cleanup_orphaned_handles()

	# Start pending tasks if we have capacity
	_start_pending_tasks()


## Submit a task to run on a worker thread
## callable: The function to execute (must be thread-safe, no scene tree access!)
## priority: Lower value = higher priority (0.0 is highest)
## Returns: Task ID for tracking/cancellation
func submit_task(callable: Callable, priority: float = 0.0) -> int:
	var task := TaskEntry.new()
	task.id = _next_task_id
	_next_task_id += 1
	task.callable = callable
	task.priority = priority

	# Binary heap insertion - O(log n) instead of O(n) linear search
	_heap_push(task)

	return task.id


## Cancel a pending or active task
## Returns true if task was found and cancelled
func cancel_task(task_id: int) -> bool:
	# Check pending tasks
	for i in range(_pending_tasks.size()):
		if _pending_tasks[i].id == task_id:
			_pending_tasks.remove_at(i)
			return true

	# Check active tasks - mark as cancelled (can't stop worker, but won't emit signal)
	if task_id in _active_tasks:
		_active_tasks[task_id].cancelled = true
		return true

	return false


## Cancel all tasks with IDs in the given array
func cancel_tasks(task_ids: Array) -> int:
	var cancelled := 0
	for task_id: int in task_ids:
		if cancel_task(task_id):
			cancelled += 1
	return cancelled


## Get number of pending tasks
func get_pending_count() -> int:
	return _pending_tasks.size()


## Get number of active (running) tasks
func get_active_count() -> int:
	return _active_tasks.size()


## Get total queued + active tasks
func get_total_count() -> int:
	return _pending_tasks.size() + _active_tasks.size()


## Check if a specific task is still pending or active
func is_task_pending(task_id: int) -> bool:
	for task in _pending_tasks:
		if task.id == task_id:
			return true
	return task_id in _active_tasks


## Clear all pending tasks (active tasks will complete)
func clear_pending() -> void:
	_pending_tasks.clear()


## Internal: Start pending tasks up to concurrent limit
func _start_pending_tasks() -> void:
	while _active_tasks.size() < _concurrent_limit and not _pending_tasks.is_empty():
		var task: TaskEntry = _heap_pop()
		if task == null:
			continue
		if task.cancelled:
			continue

		task.started = true
		task.start_time_msec = Time.get_ticks_msec()
		_active_tasks[task.id] = task

		# Submit to WorkerThreadPool
		var group_task_id := WorkerThreadPool.add_task(
			_execute_task.bind(task.id, task.callable)
		)
		task.group_task_id = group_task_id


## Internal: Execute task on worker thread
## This runs on a worker thread - must be thread-safe!
func _execute_task(task_id: int, callable: Callable) -> void:
	var result: Variant = null
	var error: String = ""

	# Execute the callable
	result = callable.call()

	# Queue result for main thread dispatch
	_results_mutex.lock()
	_completed_results.append({
		"task_id": task_id,
		"result": result,
		"error": error
	})
	_results_mutex.unlock()


## Internal: Dispatch completed results on main thread
func _dispatch_completed_results() -> void:
	if _completed_results.is_empty():
		return

	# Get results under lock
	_results_mutex.lock()
	var results := _completed_results.duplicate()
	_completed_results.clear()
	_results_mutex.unlock()

	# Dispatch each result
	for entry: Dictionary in results:
		var task_id: int = entry.task_id
		var result: Variant = entry.result
		var error: String = entry.error

		# Remove from active tasks
		var task: TaskEntry = _active_tasks.get(task_id)
		_active_tasks.erase(task_id)

		# Clean up WTP handle — task already finished so this returns immediately
		if task and task.group_task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(task.group_task_id)

		# Skip if cancelled or already removed (e.g. timed out)
		if not task or task.cancelled:
			continue

		# Emit appropriate signal
		if error.is_empty():
			task_completed.emit(task_id, result)
		else:
			task_failed.emit(task_id, error)


## Check for tasks that have been running longer than TASK_TIMEOUT_MS
## Can't actually kill the worker thread, but marks the slot as free
## so new tasks can start. The hung task will eventually complete and
## its result will be silently discarded (cancelled flag).
func _check_task_timeouts() -> void:
	if _active_tasks.is_empty():
		return

	var now := Time.get_ticks_msec()
	var timed_out: Array[int] = []

	for task_id: int in _active_tasks:
		var task: TaskEntry = _active_tasks[task_id]
		if task.start_time_msec > 0 and now - task.start_time_msec > TASK_TIMEOUT_MS:
			timed_out.append(task_id)

	for task_id: int in timed_out:
		var task: TaskEntry = _active_tasks[task_id]
		task.cancelled = true
		# Track orphaned WTP handle for deferred cleanup
		if task.group_task_id >= 0:
			_orphaned_wtp_handles.append(task.group_task_id)
		_active_tasks.erase(task_id)
		Log.warn("threading", "BackgroundProcessor: Task %d timed out after %ds" % [task_id, TASK_TIMEOUT_MS / 1000])
		task_failed.emit(task_id, "Task timed out after %d seconds" % [TASK_TIMEOUT_MS / 1000])


## Clean up WTP handles from timed-out tasks that have since completed
## Uses wait_for_task_completion() which returns immediately if the task finished
func _cleanup_orphaned_handles() -> void:
	if _orphaned_wtp_handles.is_empty():
		return

	# Try to clean up one handle per frame to avoid blocking
	var handle: int = _orphaned_wtp_handles[-1]
	if WorkerThreadPool.is_task_completed(handle):
		WorkerThreadPool.wait_for_task_completion(handle)
		_orphaned_wtp_handles.pop_back()


#region Binary Heap Operations

## Push a task onto the min-heap - O(log n)
func _heap_push(task: TaskEntry) -> void:
	_pending_tasks.append(task)
	_heap_sift_up(_pending_tasks.size() - 1)


## Pop the minimum priority task from the heap - O(log n)
func _heap_pop() -> TaskEntry:
	if _pending_tasks.is_empty():
		return null

	var result: TaskEntry = _pending_tasks[0]

	# Move last element to root and sift down
	var last_idx := _pending_tasks.size() - 1
	if last_idx > 0:
		_pending_tasks[0] = _pending_tasks[last_idx]
	_pending_tasks.pop_back()

	if not _pending_tasks.is_empty():
		_heap_sift_down(0)

	return result


## Sift element up to maintain heap property
func _heap_sift_up(idx: int) -> void:
	while idx > 0:
		var parent_idx := (idx - 1) >> 1  # Integer division by 2
		if _pending_tasks[idx].priority < _pending_tasks[parent_idx].priority:
			# Swap with parent
			var tmp: TaskEntry = _pending_tasks[idx]
			_pending_tasks[idx] = _pending_tasks[parent_idx]
			_pending_tasks[parent_idx] = tmp
			idx = parent_idx
		else:
			break


## Sift element down to maintain heap property
func _heap_sift_down(idx: int) -> void:
	var size := _pending_tasks.size()
	while true:
		var smallest := idx
		var left := (idx << 1) + 1  # 2*idx + 1
		var right := left + 1

		if left < size and _pending_tasks[left].priority < _pending_tasks[smallest].priority:
			smallest = left
		if right < size and _pending_tasks[right].priority < _pending_tasks[smallest].priority:
			smallest = right

		if smallest != idx:
			# Swap and continue
			var tmp: TaskEntry = _pending_tasks[idx]
			_pending_tasks[idx] = _pending_tasks[smallest]
			_pending_tasks[smallest] = tmp
			idx = smallest
		else:
			break

#endregion
