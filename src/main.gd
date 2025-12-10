## Main Test Scene for ESM Reader
extends Node

@onready var path_edit: LineEdit = $UI/VBoxContainer/LoadSection/PathEdit
@onready var browse_button: Button = $UI/VBoxContainer/LoadSection/BrowseButton
@onready var load_button: Button = $UI/VBoxContainer/LoadSection/LoadButton
@onready var status_label: Label = $UI/VBoxContainer/StatusLabel
@onready var progress_bar: ProgressBar = $UI/VBoxContainer/ProgressBar
@onready var output_text: RichTextLabel = $UI/VBoxContainer/OutputText
@onready var file_dialog: FileDialog = $UI/FileDialog

func _ready() -> void:
	browse_button.pressed.connect(_on_browse_pressed)
	load_button.pressed.connect(_on_load_pressed)
	file_dialog.file_selected.connect(_on_file_selected)

	# Connect to ESM manager signals
	ESMManager.loading_started.connect(_on_loading_started)
	ESMManager.loading_progress.connect(_on_loading_progress)
	ESMManager.loading_completed.connect(_on_loading_completed)
	ESMManager.loading_failed.connect(_on_loading_failed)

	# Try to find Morrowind data path from common locations
	_try_find_morrowind()

func _try_find_morrowind() -> void:
	# Common Morrowind installation paths
	var common_paths := [
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files/Morrowind.esm",
		"C:/Program Files (x86)/Bethesda Softworks/Morrowind/Data Files/Morrowind.esm",
		"C:/GOG Games/Morrowind/Data Files/Morrowind.esm",
	]

	for p in common_paths:
		if FileAccess.file_exists(p):
			path_edit.text = p
			_log("Found Morrowind at: %s" % p)
			return

	_log("Morrowind not found in common locations. Please browse to your Morrowind.esm file.")

func _on_browse_pressed() -> void:
	file_dialog.popup_centered()

func _on_file_selected(path: String) -> void:
	path_edit.text = path

func _on_load_pressed() -> void:
	var path := path_edit.text.strip_edges()
	if path.is_empty():
		_log("[color=red]Error: Please enter a file path[/color]")
		return

	if not FileAccess.file_exists(path):
		_log("[color=red]Error: File not found: %s[/color]" % path)
		return

	output_text.clear()
	_log("Loading: %s" % path)

	# Load in a thread to avoid blocking UI
	var err := ESMManager.load_file(path)
	if err != OK:
		_log("[color=red]Failed to load file: %s[/color]" % error_string(err))

func _on_loading_started(file_path: String) -> void:
	status_label.text = "Status: Loading %s..." % file_path.get_file()
	progress_bar.value = 0
	load_button.disabled = true

func _on_loading_progress(file_path: String, progress: float) -> void:
	progress_bar.value = progress * 100

func _on_loading_completed(file_path: String, record_count: int) -> void:
	status_label.text = "Status: Loaded %d records" % record_count
	progress_bar.value = 100
	load_button.disabled = false

	_log("[color=green]Successfully loaded %d records![/color]" % record_count)
	_log("")

	# Print statistics
	var stats := ESMManager.get_stats()
	_log("[b]Statistics:[/b]")
	_log("  Files loaded: %d" % stats.files)
	_log("  Total records: %d" % stats.total_records)
	_log("  Load time: %.2f seconds" % (stats.load_time_ms / 1000.0))
	_log("")
	_log("[b]Record Counts:[/b]")
	_log("  Statics: %d" % stats.statics)
	_log("  Cells: %d (exterior: %d)" % [stats.cells, stats.exterior_cells])
	_log("  Game settings: %d" % stats.game_settings)
	_log("  Globals: %d" % stats.globals)
	_log("  Activators: %d" % stats.activators)
	_log("  Doors: %d" % stats.doors)
	_log("  Lights: %d" % stats.lights)
	_log("  Containers: %d" % stats.containers)
	_log("  Weapons: %d" % stats.weapons)
	_log("  Armors: %d" % stats.armors)
	_log("  NPCs: %d" % stats.npcs)
	_log("  Creatures: %d" % stats.creatures)
	_log("")

	# Show some sample data
	_print_samples()

func _on_loading_failed(file_path: String, error: String) -> void:
	status_label.text = "Status: Failed to load"
	progress_bar.value = 0
	load_button.disabled = false
	_log("[color=red]Failed to load %s: %s[/color]" % [file_path, error])

func _print_samples() -> void:
	_log("[b]Sample Data:[/b]")

	# Sample statics
	_log("\n[u]First 5 Statics:[/u]")
	var static_keys := ESMManager.statics.keys().slice(0, 5)
	for key in static_keys:
		var rec: StaticRecord = ESMManager.statics[key]
		_log("  %s: model=%s" % [rec.record_id, rec.model])

	# Sample cells
	_log("\n[u]First 5 Interior Cells:[/u]")
	var interior_count := 0
	for key in ESMManager.cells:
		var cell: CellRecord = ESMManager.cells[key]
		if cell.is_interior():
			_log("  %s" % cell.get_description())
			interior_count += 1
			if interior_count >= 5:
				break

	# Sample exterior cells around Seyda Neen
	_log("\n[u]Exterior Cells near (0,0):[/u]")
	for y in range(-2, 3):
		for x in range(-2, 3):
			var cell := ESMManager.get_exterior_cell(x, y)
			if cell:
				_log("  (%d,%d): %s" % [x, y, cell.name if not cell.name.is_empty() else "(wilderness)"])

	# Sample game settings
	_log("\n[u]First 10 Game Settings:[/u]")
	var gmst_keys := ESMManager.game_settings.keys().slice(0, 10)
	for key in gmst_keys:
		var rec: GameSettingRecord = ESMManager.game_settings[key]
		_log("  %s = %s" % [rec.record_id, rec.get_value()])

	# Sample weapons
	_log("\n[u]First 10 Weapons:[/u]")
	var weapon_keys := ESMManager.weapons.keys().slice(0, 10)
	for key in weapon_keys:
		var rec: WeaponRecord = ESMManager.weapons[key]
		_log("  %s: %s (type=%d, damage=%d-%d)" % [rec.record_id, rec.name, rec.weapon_type, rec.chop_min, rec.chop_max])

	# Sample armors
	_log("\n[u]First 10 Armors:[/u]")
	var armor_keys := ESMManager.armors.keys().slice(0, 10)
	for key in armor_keys:
		var rec: ArmorRecord = ESMManager.armors[key]
		_log("  %s: %s (%s, AR=%d)" % [rec.record_id, rec.name, rec.get_armor_type_name(), rec.armor_rating])

	# Sample NPCs
	_log("\n[u]First 10 NPCs:[/u]")
	var npc_keys := ESMManager.npcs.keys().slice(0, 10)
	for key in npc_keys:
		var rec: NPCRecord = ESMManager.npcs[key]
		var gender := "F" if rec.is_female() else "M"
		_log("  %s: %s (%s, L%d, %s)" % [rec.record_id, rec.name, gender, rec.level, rec.race_id])

	# Sample creatures
	_log("\n[u]First 10 Creatures:[/u]")
	var creature_keys := ESMManager.creatures.keys().slice(0, 10)
	for key in creature_keys:
		var rec: CreatureRecord = ESMManager.creatures[key]
		_log("  %s: %s (%s, L%d, HP=%d)" % [rec.record_id, rec.name, rec.get_creature_type_name(), rec.level, rec.health])

func _log(text: String) -> void:
	output_text.append_text(text + "\n")
	print(text.replace("[b]", "").replace("[/b]", "").replace("[u]", "").replace("[/u]", "").replace("[color=red]", "").replace("[color=green]", "").replace("[/color]", ""))
