## BackgroundJobSystem - Generic multi-threaded job queue
##
## A reusable job system for offloading work to background threads.
## Supports multiple worker threads, job priorities, and cancellation.
##
## Key features:
## - Configurable worker thread count (defaults to CPU cores - 1)
## - Priority queue (lower priority value = processed first)
## - Job cancellation by ID or tag
## - Thread-safe result collection
## - Automatic thread lifecycle management
##
## Usage:
##   var job_system := BackgroundJobSystem.new()
##   job_system.start(2)  # 2 worker threads
##
##   var job_id := job_system.submit(func(): return load_texture(path), "textures")
##
##   # In _process():
##   for result in job_system.poll_results():
##       handle_result(result)
##
##   job_system.stop()  # On cleanup
##
## Thread safety:
## - submit(), cancel_job(), cancel_by_tag() are thread-safe
## - poll_results() should only be called from main thread
class_name BackgroundJobSystem
extends RefCounted


## Job status enum
enum JobStatus {
	PENDING,     ## Waiting in queue
	RUNNING,     ## Currently being processed
	COMPLETED,   ## Finished successfully
	CANCELLED,   ## Cancelled before completion
	FAILED,      ## Threw an exception
}


## Job data structure
class Job:
	var id: int
	var callable: Callable
	var tag: String
	var priority: int
	var status: int = JobStatus.PENDING
	var result: Variant = null
	var error_message: String = ""
	var submit_time_ms: int = 0
	var start_time_ms: int = 0
	var end_time_ms: int = 0


## Result data returned by poll_results()
class JobResult:
	var job_id: int
	var tag: String
	var status: int
	var result: Variant
	var error_message: String
	var duration_ms: int  ## Time spent processing (not waiting)
	var total_ms: int     ## Total time from submit to completion


## Worker threads
var _workers: Array[Thread] = []

## Job queue (sorted by priority - lower = higher priority)
var _job_queue: Array[Job] = []

## Jobs currently being processed: job_id -> Job
var _active_jobs: Dictionary = {}

## Completed jobs waiting for poll: Array[JobResult]
var _completed_results: Array[JobResult] = []

## Cancelled job IDs (checked by workers before processing)
var _cancelled_ids: Dictionary = {}

## Thread synchronization
var _queue_mutex: Mutex = null
var _results_mutex: Mutex = null
var _semaphore: Semaphore = null

## Control flags
var _should_stop: bool = false
var _is_running: bool = false

## Next job ID
var _next_job_id: int = 1

## Statistics
var _stats: Dictionary = {
	"jobs_submitted": 0,
	"jobs_completed": 0,
	"jobs_cancelled": 0,
	"jobs_failed": 0,
	"total_processing_ms": 0,
	"queue_high_water_mark": 0,
	"worker_count": 0,
}


#region Lifecycle

## Start the job system with specified number of worker threads
## worker_count: Number of threads (0 = auto, uses CPU cores - 1, minimum 1)
func start(worker_count: int = 0) -> Error:
	if _is_running:
		push_warning("BackgroundJobSystem: Already running")
		return ERR_ALREADY_IN_USE

	# Auto-detect worker count
	if worker_count <= 0:
		worker_count = maxi(1, OS.get_processor_count() - 1)

	# Initialize synchronization primitives
	_queue_mutex = Mutex.new()
	_results_mutex = Mutex.new()
	_semaphore = Semaphore.new()

	# Reset state
	_should_stop = false
	_is_running = true
	_job_queue.clear()
	_active_jobs.clear()
	_completed_results.clear()
	_cancelled_ids.clear()

	# Start worker threads
	_workers.clear()
	for i in range(worker_count):
		var thread := Thread.new()
		var err := thread.start(_worker_function.bind(i))
		if err != OK:
			push_error("BackgroundJobSystem: Failed to start worker thread %d" % i)
			stop()
			return err
		_workers.append(thread)

	_stats["worker_count"] = _workers.size()
	print("BackgroundJobSystem: Started with %d worker threads" % _workers.size())

	return OK


## Stop all worker threads and clean up
## Waits for currently running jobs to complete
func stop() -> void:
	if not _is_running:
		return

	_should_stop = true

	# Wake up all waiting workers so they can exit
	for i in range(_workers.size()):
		_semaphore.post()

	# Wait for all workers to finish
	for thread in _workers:
		if thread.is_started():
			thread.wait_to_finish()

	_workers.clear()
	_is_running = false

	# Clear remaining state
	_queue_mutex = null
	_results_mutex = null
	_semaphore = null

	print("BackgroundJobSystem: Stopped")


## Check if the system is running
func is_running() -> bool:
	return _is_running

#endregion


#region Job Submission

## Submit a job for background processing
## callable: The function to execute (must be thread-safe!)
## tag: Optional tag for grouping/cancellation (e.g., "textures", "meshes")
## priority: Lower values are processed first (default 0)
## Returns: Job ID for tracking/cancellation
func submit(callable: Callable, tag: String = "", priority: int = 0) -> int:
	if not _is_running:
		push_error("BackgroundJobSystem: Not running, cannot submit job")
		return -1

	var job := Job.new()
	job.id = _next_job_id
	_next_job_id += 1
	job.callable = callable
	job.tag = tag
	job.priority = priority
	job.submit_time_ms = Time.get_ticks_msec()

	# Add to queue (thread-safe)
	_queue_mutex.lock()
	_insert_by_priority(job)
	_stats["jobs_submitted"] += 1
	_stats["queue_high_water_mark"] = maxi(_stats["queue_high_water_mark"], _job_queue.size())
	_queue_mutex.unlock()

	# Signal a worker that there's work available
	_semaphore.post()

	return job.id


## Submit multiple jobs at once (more efficient than individual submits)
## Returns: Array of job IDs
func submit_batch(jobs: Array[Dictionary]) -> Array[int]:
	if not _is_running:
		push_error("BackgroundJobSystem: Not running, cannot submit jobs")
		return []

	var ids: Array[int] = []

	_queue_mutex.lock()
	for job_data in jobs:
		var job := Job.new()
		job.id = _next_job_id
		_next_job_id += 1
		job.callable = job_data.get("callable", Callable())
		job.tag = job_data.get("tag", "")
		job.priority = job_data.get("priority", 0)
		job.submit_time_ms = Time.get_ticks_msec()

		_insert_by_priority(job)
		ids.append(job.id)

	_stats["jobs_submitted"] += ids.size()
	_stats["queue_high_water_mark"] = maxi(_stats["queue_high_water_mark"], _job_queue.size())
	_queue_mutex.unlock()

	# Signal workers
	for i in range(ids.size()):
		_semaphore.post()

	return ids

#endregion


#region Job Cancellation

## Cancel a specific job by ID
## Returns true if job was cancelled, false if already completed/running
func cancel_job(job_id: int) -> bool:
	_queue_mutex.lock()

	# Check if in queue
	for i in range(_job_queue.size()):
		if _job_queue[i].id == job_id:
			var job := _job_queue[i]
			_job_queue.remove_at(i)
			job.status = JobStatus.CANCELLED
			_stats["jobs_cancelled"] += 1
			_queue_mutex.unlock()
			return true

	# Mark as cancelled (worker will check before processing)
	_cancelled_ids[job_id] = true
	_queue_mutex.unlock()

	return false


## Cancel all jobs with a specific tag
## Returns number of jobs cancelled
func cancel_by_tag(tag: String) -> int:
	var count := 0

	_queue_mutex.lock()

	# Remove from queue
	var remaining: Array[Job] = []
	for job in _job_queue:
		if job.tag == tag:
			job.status = JobStatus.CANCELLED
			count += 1
		else:
			remaining.append(job)
	_job_queue = remaining

	# Mark active jobs for cancellation
	for job_id in _active_jobs:
		var job: Job = _active_jobs[job_id]
		if job.tag == tag:
			_cancelled_ids[job_id] = true

	_stats["jobs_cancelled"] += count
	_queue_mutex.unlock()

	return count


## Cancel all pending jobs
## Returns number of jobs cancelled
func cancel_all() -> int:
	_queue_mutex.lock()

	var count := _job_queue.size()
	for job in _job_queue:
		job.status = JobStatus.CANCELLED
	_job_queue.clear()

	# Mark all active jobs for cancellation
	for job_id in _active_jobs:
		_cancelled_ids[job_id] = true

	_stats["jobs_cancelled"] += count
	_queue_mutex.unlock()

	return count

#endregion


#region Results

## Poll for completed job results (call from main thread in _process)
## max_results: Maximum results to return per call (0 = all available)
## Returns: Array of JobResult
func poll_results(max_results: int = 0) -> Array[JobResult]:
	if not _is_running:
		return []

	var results: Array[JobResult] = []

	_results_mutex.lock()
	if max_results <= 0 or max_results >= _completed_results.size():
		results = _completed_results.duplicate()
		_completed_results.clear()
	else:
		for i in range(max_results):
			results.append(_completed_results[i])
		_completed_results = _completed_results.slice(max_results)
	_results_mutex.unlock()

	return results


## Get number of pending results waiting to be polled
func get_pending_result_count() -> int:
	if not _results_mutex:
		return 0
	_results_mutex.lock()
	var count := _completed_results.size()
	_results_mutex.unlock()
	return count


## Get number of jobs currently in queue
func get_queue_size() -> int:
	if not _queue_mutex:
		return 0
	_queue_mutex.lock()
	var size := _job_queue.size()
	_queue_mutex.unlock()
	return size


## Get number of jobs currently being processed
func get_active_count() -> int:
	if not _queue_mutex:
		return 0
	_queue_mutex.lock()
	var count := _active_jobs.size()
	_queue_mutex.unlock()
	return count


## Get statistics
func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats["queue_size"] = get_queue_size()
	stats["active_jobs"] = get_active_count()
	stats["pending_results"] = get_pending_result_count()
	return stats

#endregion


#region Internal

## Insert job into queue maintaining priority order (lower = higher priority)
func _insert_by_priority(job: Job) -> void:
	# Binary search for insertion point
	var low := 0
	var high := _job_queue.size()

	while low < high:
		var mid := (low + high) / 2
		if _job_queue[mid].priority <= job.priority:
			low = mid + 1
		else:
			high = mid

	_job_queue.insert(low, job)


## Worker thread function
func _worker_function(worker_id: int) -> void:
	while not _should_stop:
		# Wait for work
		_semaphore.wait()

		if _should_stop:
			break

		# Get next job from queue
		_queue_mutex.lock()
		if _job_queue.is_empty():
			_queue_mutex.unlock()
			continue

		var job: Job = _job_queue.pop_front()

		# Check if cancelled
		if job.id in _cancelled_ids:
			_cancelled_ids.erase(job.id)
			_queue_mutex.unlock()
			continue

		# Mark as active
		job.status = JobStatus.RUNNING
		job.start_time_ms = Time.get_ticks_msec()
		_active_jobs[job.id] = job
		_queue_mutex.unlock()

		# Execute job
		var result: Variant = null
		var error_msg := ""
		var status := JobStatus.COMPLETED

		if job.callable.is_valid():
			result = job.callable.call()
		else:
			status = JobStatus.FAILED
			error_msg = "Invalid callable"

		# Check if cancelled during execution
		_queue_mutex.lock()
		if job.id in _cancelled_ids:
			_cancelled_ids.erase(job.id)
			status = JobStatus.CANCELLED
		_active_jobs.erase(job.id)
		_queue_mutex.unlock()

		# Record completion
		job.end_time_ms = Time.get_ticks_msec()
		job.status = status
		job.result = result
		job.error_message = error_msg

		# Update stats
		var duration: int = job.end_time_ms - job.start_time_ms
		_stats["total_processing_ms"] += duration

		match status:
			JobStatus.COMPLETED:
				_stats["jobs_completed"] += 1
			JobStatus.FAILED:
				_stats["jobs_failed"] += 1
			JobStatus.CANCELLED:
				_stats["jobs_cancelled"] += 1

		# Queue result for main thread
		var job_result := JobResult.new()
		job_result.job_id = job.id
		job_result.tag = job.tag
		job_result.status = status
		job_result.result = result
		job_result.error_message = error_msg
		job_result.duration_ms = duration
		job_result.total_ms = job.end_time_ms - job.submit_time_ms

		_results_mutex.lock()
		_completed_results.append(job_result)
		_results_mutex.unlock()

#endregion
