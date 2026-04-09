## NIF Debug Dump — one-shot diagnostic for parser failures.
##
## Loads a specific NIF from the BSA archive and parses it with `debug_mode = true`
## so the full record sequence (type, position, size) lands in the log. Used to
## identify which record handler in `nif_reader.gd` is under- or over-reading the
## stream when "Invalid string length 1399410176 at pos N — parser out of sync"
## fires on the downstream record.
##
## Usage:
##   "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" \
##     res://src/tools/nif_debug_dump.tscn
##
## Edit NIF_PATHS below to change which files get dumped. Auto-quits on completion.
##
## Output goes through the `Log` autoload (category `nifdbg`). Levels:
##   info  — top-level section headers and per-record summaries
##   debug — byte-by-byte offsets (enabled by setting debug_mode = true on the reader)
extends Node

const NIFReaderScript := preload("res://src/core/nif/nif_reader.gd")

## NIF files to dump. All should come from the active failure catalog in
## docs/audit/NIF_UNSUPPORTED.md — pick files from the same family so we can
## compare their record sequences and spot the common culprit.
const NIF_PATHS: Array[String] = [
	"i\\active_port_Andra.NIF",     # aborts at index 4, same as all other active_port_*
	"i\\active_port_Beran.NIF",     # second sample — should fail identically if template-authored
	"a\\A_Glass_Boots_A.nif",       # aborts at index 17 — different family, different failure depth
	"w\\W_shortsword00.nif",        # aborts at index 23 — weapon enchant/glow path
	"x\\ex_dwrv_ruin30.nif",        # aborts at index 3 — architecture, short abort
]

func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	Log.info("nifdbg", "=".repeat(80))
	Log.info("nifdbg", "NIF DEBUG DUMP — parser failure reproducer")
	Log.info("nifdbg", "=".repeat(80))

	# BSAManager autoload is required. The main Godotwind scene initializes it
	# in its _ready, but our tool scene doesn't inherit that — call refresh here.
	if BSAManager == null:
		Log.error("nifdbg", "BSAManager autoload missing — cannot proceed")
		_quit(1)
		return

	# Make sure the archive index is populated. Reuse the same path settings the
	# main scene uses so we read from the configured Morrowind install.
	var install_path: String = SettingsManager.get_morrowind_install_path()
	if install_path.is_empty():
		Log.error("nifdbg", "Morrowind install path not configured in SettingsManager")
		_quit(1)
		return

	Log.info("nifdbg", "Morrowind install: %s" % install_path)

	# Ensure BSAs are loaded (BSAManager does this lazily via has_file/extract_file,
	# but trigger a cheap lookup first to force initialization in case of cold start).
	var probe: bool = BSAManager.has_file("meshes/base_anim.nif")
	Log.info("nifdbg", "BSA probe result: base_anim.nif exists = %s" % probe)
	if not probe:
		Log.error("nifdbg", "BSA not readable — check Morrowind path and archive files")
		_quit(1)
		return

	for nif_path: String in NIF_PATHS:
		await _dump_one(nif_path)
		Log.info("nifdbg", "")

	Log.info("nifdbg", "=".repeat(80))
	Log.info("nifdbg", "NIF DEBUG DUMP complete — quitting")
	Log.info("nifdbg", "=".repeat(80))
	_quit(0)


func _dump_one(nif_path: String) -> void:
	Log.info("nifdbg", "-".repeat(80))
	Log.info("nifdbg", "FILE: %s" % nif_path)
	Log.info("nifdbg", "-".repeat(80))

	# Normalize path to the BSA's internal form. BSAs use forward slashes under
	# the meshes/ prefix per Bethesda's archive format.
	var bsa_path: String = nif_path.replace("\\", "/")
	if not bsa_path.to_lower().begins_with("meshes/"):
		bsa_path = "meshes/" + bsa_path

	if not BSAManager.has_file(bsa_path):
		# Some failure catalog entries might be tool-side paths already prefixed
		# with "meshes/" — retry with the raw string before giving up.
		if BSAManager.has_file(nif_path):
			bsa_path = nif_path
		else:
			Log.warn("nifdbg", "FILE NOT IN BSA: tried '%s' and '%s'" % [bsa_path, nif_path])
			return

	var data: PackedByteArray = BSAManager.extract_file(bsa_path)
	if data.is_empty():
		Log.warn("nifdbg", "Extracted 0 bytes from BSA — aborted")
		return

	Log.info("nifdbg", "Extracted %d bytes from BSA path '%s'" % [data.size(), bsa_path])

	# Dump the first 64 bytes as hex + ASCII so we can sanity-check the header
	# (every Morrowind NIF starts with "NetImmerse File Format, Version 4.0.0.2\n")
	_hex_dump(data, 0, 64, "HEADER")

	# Parse with full debug tracing
	var reader: Object = NIFReaderScript.new()
	reader.debug_mode = true
	var err: int = reader.load_buffer(data, nif_path)
	if err != OK:
		Log.warn("nifdbg", "load_buffer returned error %d — see errors above for the failing record" % err)
	else:
		Log.info("nifdbg", "Parse SUCCEEDED — records: %d, roots: %d" % [
			reader.records.size(), reader.roots.size()
		])

	# Yield a frame between files so the log stays readable in real time
	await get_tree().process_frame


## Print a slice of the buffer as hex + ASCII for manual inspection.
func _hex_dump(buffer: PackedByteArray, start: int, count: int, label: String) -> void:
	var end: int = mini(start + count, buffer.size())
	Log.info("nifdbg", "[%s] bytes [%d..%d]:" % [label, start, end])
	var row_start: int = start
	while row_start < end:
		var row_end: int = mini(row_start + 16, end)
		var hex_part: String = ""
		var ascii_part: String = ""
		for i in range(row_start, row_end):
			var b: int = buffer[i]
			hex_part += "%02X " % b
			ascii_part += char(b) if b >= 0x20 and b < 0x7F else "."
		# Pad hex column to 48 chars for alignment when the last row is short
		while hex_part.length() < 48:
			hex_part += "   "
		Log.info("nifdbg", "  %04X  %s  %s" % [row_start, hex_part, ascii_part])
		row_start = row_end


func _quit(code: int) -> void:
	# Flush logs and exit. Using a one-frame delay so the final Log.info lines
	# actually make it to stdout before the process dies.
	await get_tree().process_frame
	get_tree().quit(code)
