## Crash breadcrumb — single-file "last operation" writer.
##
## Writes to `user://logs/crash_breadcrumb.txt`. After a crash, read the file
## to see the last operation the game was executing.
##
## Phase 1 rewrite (2026-07-05): the original implementation did
## `FileAccess.open + store + close` on EVERY call. The doc claimed
## ~50-200µs, but on this machine (Windows + AV scanning on file close) it
## measured 4-8ms per call — per-tick breadcrumbs in the unload path were
## the dominant cost of the "budgeted" unloader (9-75ms observed vs 4ms
## budget). Canonical fix: open the handle ONCE, then per write seek(0) +
## store + flush(). flush() hands the bytes to the OS page cache, which
## survives a native SIGSEGV (only kernel panic / power loss would lose
## them) — same crash-forensics guarantee, ~µs cost.
##
## Lines are padded to a fixed width so a shorter breadcrumb fully
## overwrites a longer previous one; readers take content up to the pad.
@warning_ignore("untyped_declaration")
class_name CrashBreadcrumb
extends RefCounted

const _PATH: String = "user://logs/crash_breadcrumb.txt"
const _LINE_WIDTH: int = 256

static var _file: FileAccess = null
static var _open_failed: bool = false


## Write a single-line breadcrumb. Overwrites any previous content.
## Call at every native-entry hazard site (PackedScene.instantiate(),
## queue_free() of complex subtrees, RenderingServer/PhysicsServer calls
## that might race with concurrent state mutation).
static func write(tag: String, detail: String = "") -> void:
	if _file == null:
		if _open_failed:
			return
		_file = FileAccess.open(_PATH, FileAccess.WRITE)
		if _file == null:
			_open_failed = true
			return
	var ts := Time.get_ticks_msec()
	var line: String
	if detail.is_empty():
		line = "[%d] %s" % [ts, tag]
	else:
		line = "[%d] %s :: %s" % [ts, tag, detail]
	# Fixed-width pad so stale bytes from a longer previous line never
	# survive the overwrite. Truncate over-long lines to the same width.
	if line.length() > _LINE_WIDTH:
		line = line.substr(0, _LINE_WIDTH)
	else:
		line = line.rpad(_LINE_WIDTH, " ")
	_file.seek(0)
	_file.store_string(line)
	_file.flush()


## Read and return the last breadcrumb (for post-crash diagnosis).
static func read_last() -> String:
	if not FileAccess.file_exists(_PATH):
		return ""
	var f := FileAccess.open(_PATH, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text().strip_edges()
	f.close()
	return s
