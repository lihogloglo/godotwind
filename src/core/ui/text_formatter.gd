## TextFormatter — Converts HTML-like markup to Godot BBCode
##
## Generic framework class for converting simple HTML markup to BBCode.
## Supports: <BR>, <P>, <DIV ALIGN>, <FONT COLOR SIZE>, <IMG SRC>, <B>, <I>, <HR>
##
## Game-specific behavior (image loading, font size mapping) is injected
## via callables. See MWTextFormatter for the Morrowind implementation.
class_name TextFormatter
extends RefCounted


## Result of formatting text that contains images
class FormattedText:
	var bbcode: String = ""
	var images: Array[Dictionary] = []  # [{placeholder: String, texture: ImageTexture}]


## Optional callable for loading images: func(src: String) -> ImageTexture
## Set this before calling to_formatted_text() if you need image support
static var image_loader: Callable = Callable()

## Optional callable for mapping font sizes: func(size: int) -> int
## Maps markup font size numbers to pixel sizes
static var font_size_mapper: Callable = Callable()


## Convert markup to BBCode (no image support — images become [placeholder])
static func to_bbcode(mw_text: String) -> String:
	var result := _convert_markup(mw_text)
	return result.bbcode


## Convert markup to FormattedText with image data for programmatic insertion
static func to_formatted_text(mw_text: String) -> FormattedText:
	return _convert_markup(mw_text)


## Core conversion: HTML-like tags → BBCode
static func _convert_markup(mw_text: String) -> FormattedText:
	var result := FormattedText.new()
	var text := mw_text
	var output := ""
	var pos := 0
	while pos < text.length():
		# Look for a tag
		var tag_start := text.find("<", pos)

		if tag_start < 0:
			# No more tags — append remainder
			output += text.substr(pos)
			break

		# Append text before the tag
		if tag_start > pos:
			output += text.substr(pos, tag_start - pos)

		# Find end of tag
		var tag_end := text.find(">", tag_start)
		if tag_end < 0:
			# Unclosed tag — treat as literal text
			output += text.substr(tag_start)
			break

		# Extract the full tag content (without < >)
		var tag_content := text.substr(tag_start + 1, tag_end - tag_start - 1).strip_edges()
		var tag_upper := tag_content.to_upper()

		# Process the tag
		var bbcode_replacement: Variant = _process_tag(tag_content, tag_upper, result)
		if bbcode_replacement != null:
			output += str(bbcode_replacement)
		# else: tag was consumed silently (e.g. unknown tag — skip it)

		pos = tag_end + 1

	result.bbcode = output
	return result


## Process a single HTML tag and return its BBCode equivalent (or null to skip)
static func _process_tag(tag_content: String, tag_upper: String, result: FormattedText) -> Variant:
	# Self-closing / void tags
	if tag_upper == "BR" or tag_upper == "BR/":
		return "\n"

	if tag_upper == "HR" or tag_upper == "HR/":
		return "\n[color=#666666]────────────────────────────[/color]\n"

	if tag_upper == "P" or tag_upper.begins_with("P "):
		return "\n"

	if tag_upper == "/P":
		return "\n"

	# Bold
	if tag_upper == "B":
		return "[b]"
	if tag_upper == "/B":
		return "[/b]"

	# Italic
	if tag_upper == "I":
		return "[i]"
	if tag_upper == "/I":
		return "[/i]"

	# DIV with alignment
	if tag_upper.begins_with("DIV"):
		var align := _extract_attribute(tag_content, "ALIGN")
		if not align.is_empty():
			match align.to_upper():
				"CENTER":
					return "[center]"
				"RIGHT":
					return "[right]"
				"LEFT":
					return ""  # Left is default
		return ""

	if tag_upper == "/DIV":
		# Close any alignment — BBCode auto-closes at newline, but be explicit
		return "[/center][/right]\n"

	# FONT with COLOR and/or SIZE
	if tag_upper.begins_with("FONT"):
		var bbcode := ""
		var color := _extract_attribute(tag_content, "COLOR")
		var size_str := _extract_attribute(tag_content, "SIZE")

		if not color.is_empty():
			# Common format: "RRGGBB" without #, or sometimes with #
			if not color.begins_with("#"):
				color = "#" + color
			bbcode += "[color=%s]" % color

		if not size_str.is_empty():
			var size_val := size_str.to_int()
			var pixel_size := _map_font_size(size_val)
			bbcode += "[font_size=%d]" % pixel_size

		return bbcode

	if tag_upper == "/FONT":
		# Close both color and font_size (BBCode is tolerant of extra closes)
		return "[/font_size][/color]"

	# IMG — needs special handling (can't embed in-memory textures via BBCode)
	if tag_upper.begins_with("IMG"):
		var src := _extract_attribute(tag_content, "SRC")
		if not src.is_empty():
			# Try to load via the injected image loader
			if image_loader.is_valid():
				var texture: ImageTexture = image_loader.call(src)
				if texture != null:
					var placeholder := "[IMG_%d]" % result.images.size()
					result.images.append({
						"placeholder": placeholder,
						"texture": texture,
					})
					return placeholder
			return "[color=#888888][missing image: %s][/color]" % src
		return ""

	# Unknown tag — skip silently
	return null


## Map a markup font size to pixel size
## Uses the injected font_size_mapper if available, otherwise uses sensible defaults
static func _map_font_size(size_val: int) -> int:
	if font_size_mapper.is_valid():
		return font_size_mapper.call(size_val)
	# Generic defaults
	match size_val:
		1: return 12
		2: return 14
		3: return 16
		4: return 20
		5: return 24
		6: return 28
		_:
			if size_val <= 0:
				return 16
			return 28 + (size_val - 6) * 4


## Extract an attribute value from an HTML tag string
## e.g. _extract_attribute('FONT COLOR="FF0000"', "COLOR") → "FF0000"
static func _extract_attribute(tag_content: String, attr_name: String) -> String:
	var upper := tag_content.to_upper()
	var attr_upper := attr_name.to_upper()

	# Find attribute name
	var attr_pos := upper.find(attr_upper)
	if attr_pos < 0:
		return ""

	# Find = sign after attribute name
	var eq_pos := upper.find("=", attr_pos + attr_upper.length())
	if eq_pos < 0:
		return ""

	# Skip whitespace after =
	var val_start := eq_pos + 1
	while val_start < tag_content.length() and tag_content[val_start] == " ":
		val_start += 1

	if val_start >= tag_content.length():
		return ""

	# Check for quotes
	var quote_char := tag_content[val_start]
	if quote_char == '"' or quote_char == "'":
		var val_end := tag_content.find(str(quote_char), val_start + 1)
		if val_end < 0:
			return tag_content.substr(val_start + 1)
		return tag_content.substr(val_start + 1, val_end - val_start - 1)
	else:
		# Unquoted — read until space or end
		var val_end := tag_content.find(" ", val_start)
		if val_end < 0:
			return tag_content.substr(val_start)
		return tag_content.substr(val_start, val_end - val_start)
