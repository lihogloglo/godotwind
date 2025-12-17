## BackgroundProcessor - Manages CPU-intensive work on worker threads
## Uses Godot's WorkerThreadPool for parallel task execution
## Results are safely delivered to main thread via call_deferred
class_name BackgroundProcessor
extends Node

signal task_completed(task_id: int, result: Variant)
signal task_failed(task_id: int, error: String)

## Task entry for tracking
class TaskEntry:
	var id: int
	var callable: Callable
	var priority: float
	var group_task_id: int = -1  # WorkerThreadPool task ID
	var cancelled: bool = false
	var started: bool = false

## Next task ID
var _next_task_id: int = 1

## Pending tasks (priority queue, lower priority value = higher priority)
var _pending_tasks: Array[TaskEntry] = []

## Active tasks (currently running on workers)
var _active_tasks: Dictionary = {}  # task_id -> TaskEntry

## Completed results waiting for main thread dispatch
var _completed_results: Array = []  # Array of {task_id, result, error}

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
	print("BackgroundProcessor: Initialized with %d concurrent task limit" % _concurrent_limit)


func _process(_delta: float) -> void:
	# Dispatch completed results on main thread
	_dispatch_completed_results()

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

	# Insert in priority order (lower priority value first)
	var inserted := false
	for i in range(_pending_tasks.size()):
		if priority < _pending_tasks[i].priority:
			_pending_tasks.insert(i, task)
			inserted = true
			break
	if not inserted:
		_pending_tasks.append(task)

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
	for task_id in task_ids:
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
		var task := _pending_tasks.pop_front() as TaskEntry
		if task.cancelled:
			continue

		task.started = true
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
	for entry in results:
		var task_id: int = entry.task_id
		var result: Variant = entry.result
		var error: String = entry.error

		# Remove from active tasks
		var task: TaskEntry = _active_tasks.get(task_id)
		_active_tasks.erase(task_id)

		# Skip if cancelled
		if task and task.cancelled:
			continue

		# Emit appropriate signal
		if error.is_empty():
			task_completed.emit(task_id, result)
		else:
			task_failed.emit(task_id, error)
