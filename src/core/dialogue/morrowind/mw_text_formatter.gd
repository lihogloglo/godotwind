## MWTextFormatter — Morrowind-specific text formatting
##
## Configures the generic TextFormatter with MW-specific image loading (BSA)
## and font size mapping. Call setup() once at startup to inject MW handlers.
class_name MWTextFormatter
extends RefCounted


## Initialize TextFormatter with MW-specific handlers
## Call this once before any text formatting (e.g. in world_explorer startup)
static func setup() -> void:
	TextFormatter.image_loader = MWTextFormatter._load_book_image
	TextFormatter.font_size_mapper = MWTextFormatter._mw_font_size_to_pixels


## Map Morrowind font size numbers to pixel sizes
## MW sizes: 1-3 = small, 4 = normal, 5+ = large
static func _mw_font_size_to_pixels(mw_size: int) -> int:
	match mw_size:
		1: return 12
		2: return 14
		3: return 16
		4: return 20
		5: return 24
		6: return 28
		_:
			if mw_size <= 0:
				return 16
			return 28 + (mw_size - 6) * 4


## Load a book image texture from BSA
## MW book images reference textures like "tx_boethiah_128.tga"
static func _load_book_image(src: String) -> ImageTexture:
	# MW book images are in the textures folder
	# Try with and without "textures/" prefix
	var paths_to_try: Array[String] = []

	if src.find("/") >= 0 or src.find("\\") >= 0:
		paths_to_try.append(src)
	else:
		paths_to_try.append("textures/" + src)
		paths_to_try.append(src)

	for path in paths_to_try:
		var texture := TextureLoader.load_texture(path)
		# TextureLoader returns an 8x8 fallback on failure — real textures are larger
		if texture != null and texture.get_width() > 8:
			return texture

	return null
