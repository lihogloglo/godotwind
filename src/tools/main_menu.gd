extends Control

const ModRegistryScript := preload("res://src/core/modding/mod_registry.gd")
const WORLD_SCENE := "res://scenes/Godotwind.tscn"

@onready var _status_label: Label = $Center/VBox/StatusLabel
@onready var _path_label: Label = $Center/VBox/PathLabel
@onready var _new_game_button: Button = $Center/VBox/Buttons/NewGameButton
@onready var _quit_button: Button = $Center/VBox/Buttons/QuitButton

var _data_path: String = ""


func _ready() -> void:
	_new_game_button.pressed.connect(_start_new_game)
	_quit_button.pressed.connect(func() -> void: get_tree().quit())
	_resolve_data_path()
	_maybe_start_ready_quit()
	call_deferred("_prepare_menu_data")


func _resolve_data_path() -> void:
	_data_path = SettingsManager.get_data_path()
	if _data_path.is_empty():
		_data_path = SettingsManager.auto_detect_installation()
		if not _data_path.is_empty():
			SettingsManager.set_data_path(_data_path)

	if _data_path.is_empty():
		_status_label.text = "Data path not configured"
		_path_label.text = "Set MORROWIND_DATA_PATH or configure SettingsManager."
		_new_game_button.disabled = true
		return

	_status_label.text = "Ready"
	_path_label.text = _data_path
	_new_game_button.disabled = false


func _prepare_menu_data() -> void:
	await get_tree().process_frame
	if _data_path.is_empty():
		return

	_status_label.text = "Checking mods..."
	await get_tree().process_frame
	var mod_registry: ModRegistry = ModRegistryScript.new()
	var mod_err := mod_registry.load_manifest()
	if mod_err != OK:
		_status_label.text = "Mod manifest warning: %s" % error_string(mod_err)
		return

	_status_label.text = "Indexing archives..."
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	var bsa_count := BSAManager.load_archives_from_directory(_data_path)
	for bsa_path: String in mod_registry.get_bsa_load_order():
		if BSAManager.load_archive(bsa_path) == OK:
			bsa_count += 1
	var elapsed := Time.get_ticks_msec() - t0
	_status_label.text = "Ready - %d archives indexed in %.1fs" % [BSAManager.get_archive_count(), elapsed / 1000.0]
	Log.info("loading", "[MAIN_MENU] indexed %d new archives, %d total in %d ms" % [
		bsa_count,
		BSAManager.get_archive_count(),
		elapsed,
	])


func _start_new_game() -> void:
	_new_game_button.disabled = true
	_status_label.text = "Starting world..."
	get_tree().change_scene_to_file(WORLD_SCENE)


func _maybe_start_ready_quit() -> void:
	var delay := -1.0
	for arg: String in _runtime_cmdline_args():
		if arg == "--quit-after-ready":
			delay = 1.0
		elif arg.begins_with("--quit-after-ready="):
			delay = maxf(0.1, float(arg.substr("--quit-after-ready=".length())))
	if delay < 0.0:
		return
	get_tree().create_timer(delay).timeout.connect(func() -> void: get_tree().quit())


func _runtime_cmdline_args() -> PackedStringArray:
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	return args
