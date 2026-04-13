## Visual test for BookViewer
##
## Loads ESM data, picks several books with rich formatting, and displays them.
## Use left/right arrow keys to cycle between books.
## Press Escape to close the current book, then arrows to pick another.
##
## Run: godot --path . res://tests/visual/test_book_viewer.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node

const BookViewerScript := preload("res://src/core/ui/book_viewer.gd")
const MWTextFormatterScript := preload("res://src/core/dialogue/morrowind/mw_text_formatter.gd")

var _book_viewer
var _loading_screen: LoadingScreen
var _book_list: Array = []  # Array of BookRecord
var _current_index: int = 0
var _info_label: Label


func _ready() -> void:
	# Load game data first
	_loading_screen = LoadingScreen.new()
	add_child(_loading_screen)
	var success = await _loading_screen.load_game_data()
	_loading_screen.queue_free()

	if not success:
		_show_error("Failed to load ESM data. Check Morrowind data path in settings.")
		return

	# Setup MW text formatting (image loading, font sizes)
	MWTextFormatterScript.setup()

	# Collect interesting books (prefer ones with rich formatting)
	_collect_books()

	if _book_list.is_empty():
		_show_error("No books found in ESM data.")
		return

	# Create the book viewer
	_book_viewer = BookViewerScript.new()
	add_child(_book_viewer)

	# Info label at bottom of screen
	_info_label = Label.new()
	_info_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_info_label.offset_top = -40
	_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_label.add_theme_font_size_override("font_size", 14)
	_info_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	add_child(_info_label)

	# Show the first book
	_show_current_book()


func _unhandled_input(event: InputEvent) -> void:
	if _book_list.is_empty():
		return

	if event.is_action_pressed("ui_right"):
		_current_index = (_current_index + 1) % _book_list.size()
		_show_current_book()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_left"):
		_current_index = (_current_index - 1 + _book_list.size()) % _book_list.size()
		_show_current_book()
		get_viewport().set_input_as_handled()


func _show_current_book() -> void:
	var book: BookRecord = _book_list[_current_index]
	var title: String = book.name if not book.name.is_empty() else book.record_id
	_book_viewer.show_book(title, book.text)
	_info_label.text = "Book %d/%d — Left/Right arrows to browse, Escape to close" % [
		_current_index + 1, _book_list.size()
	]


func _collect_books() -> void:
	# Prioritize books with rich markup (images, formatting, colors)
	var priority_ids: Array = [
		"bookskill_enchant5",  # The 36 Lessons of Vivec — typically has formatting
		"bk_36lessons_sermon01",
		"bk_36lessons_sermon14",
		"bk_realarenziah1",   # The Real Barenziah — long, may have special chars
		"bk_boethiah",        # Boethiah's Pillow Book — has illustrations
		"bk_yellowbook",      # The Yellow Book of Riddles
		"bk_homiliesofblessedalotha",
		"bk_pilgrimsresolution",
		"bk_mixedunitoverrun",
		"bk_vivec_no1",
	]

	# Add priority books that exist
	for book_id in priority_ids:
		var book = ESMManager.get_book(book_id)
		if book != null and not book.text.is_empty():
			_book_list.append(book)

	# Fill up with any books that have non-trivial text
	var books_with_tags: Array = []
	var books_plain: Array = []

	for book_id in ESMManager.books:
		if _book_list.size() >= 30:
			break
		var book: BookRecord = ESMManager.books[book_id]
		if book.text.is_empty() or book.text.length() < 50:
			continue
		# Skip if already in priority list
		var already_added := false
		for existing in _book_list:
			if existing.record_id == book.record_id:
				already_added = true
				break
		if already_added:
			continue

		# Prefer books with HTML tags
		if book.text.find("<") >= 0:
			books_with_tags.append(book)
		else:
			books_plain.append(book)

	# Add tagged books first, then plain
	for book in books_with_tags:
		if _book_list.size() >= 30:
			break
		_book_list.append(book)

	for book in books_plain:
		if _book_list.size() >= 30:
			break
		_book_list.append(book)

	Log.info("ui", "BookViewer test: collected %d books (%d with markup)" % [
		_book_list.size(), books_with_tags.size()
	])


func _show_error(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	add_child(label)
