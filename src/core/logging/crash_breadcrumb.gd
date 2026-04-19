## Crash breadcrumb — single-file "last operation" writer.
##
## Writes to `user://logs/crash_breadcrumb.txt`, overwriting on each call.
## File is opened, written, and closed (which flushes) on every call so the
## contents survive a native SIGSEGV. After a crash, read the file to see
## the last operation the game was executing.
##
## Cost per call: one `FileAccess.open` + `store_string` + `close()`. On SSD
## this is ~50-200µs. At 24k instantiates/session = ~1-5s total overhead.
## Acceptable for a diagnostic build; remove call sites once the race is
## identified.
##
## S.1 follow-up 2026-04-19 — added to pinpoint the native-level sig11
## crash that persists after the canonical PackedScene pattern landed on
## 2026-04-16. See docs/plans/distant_rendering_2026_04/near_tier_refactor.md
## §S.4 (model_loader race hard prerequisite).
@warning_ignore("untyped_declaration")
class_name CrashBreadcrumb
extends RefCounted

const _PATH: String = "user://logs/crash_breadcrumb.txt"

## Write a single-line breadcrumb. Overwrites any previous content.
## Call at every native-entry hazard site (PackedScene.instantiate(),
## queue_free() of complex subtrees, RenderingServer/PhysicsServer calls
## that might race with concurrent state mutation).
static func write(tag: String, detail: String = "") -> void:
	var f := FileAccess.open(_PATH, FileAccess.WRITE)
	if f == null:
		return
	var ts := Time.get_ticks_msec()
	var line: String
	if detail.is_empty():
		line = "[%d] %s" % [ts, tag]
	else:
		line = "[%d] %s :: %s" % [ts, tag, detail]
	f.store_string(line)
	f.close()


## Read and return the last breadcrumb (for post-crash diagnosis).
static func read_last() -> String:
	if not FileAccess.file_exists(_PATH):
		return ""
	var f := FileAccess.open(_PATH, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s
