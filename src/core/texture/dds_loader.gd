## DDS Loader - Custom DDS file loader that handles malformed Morrowind textures
## Supports DXT1/DXT3/DXT5 compressed formats and uncompressed formats
## Can load base mip level only, bypassing truncated mipmap chain issues
class_name DDSLoader
extends RefCounted

# DDS file magic number
const DDS_MAGIC := 0x20534444  # "DDS "

# DDS header flags
const DDSD_CAPS := 0x1
const DDSD_HEIGHT := 0x2
const DDSD_WIDTH := 0x4
const DDSD_PITCH := 0x8
const DDSD_PIXELFORMAT := 0x1000
const DDSD_MIPMAPCOUNT := 0x20000
const DDSD_LINEARSIZE := 0x80000

# Pixel format flags
const DDPF_ALPHAPIXELS := 0x1
const DDPF_FOURCC := 0x4
const DDPF_RGB := 0x40

# FourCC codes
const FOURCC_DXT1 := 0x31545844  # "DXT1"
const FOURCC_DXT3 := 0x33545844  # "DXT3"
const FOURCC_DXT5 := 0x35545844  # "DXT5"


## Load DDS from buffer, optionally loading only base mip level
## Returns Image or null on failure
static func load_from_buffer(data: PackedByteArray, base_mip_only: bool = false) -> Image:
	if data.size() < 128:  # Minimum DDS header size
		return null

	var reader := StreamPeerBuffer.new()
	reader.data_array = data
	reader.big_endian = false

	# Read and verify magic number
	var magic := reader.get_32()
	if magic != DDS_MAGIC:
		return null

	# Read DDS header (124 bytes)
	var header_size := reader.get_32()
	if header_size != 124:
		return null

	var flags := reader.get_32()
	var height := reader.get_32()
	var width := reader.get_32()
	var pitch_or_linear_size := reader.get_32()
	var _depth := reader.get_32()
	var mipmap_count := reader.get_32()

	# Skip reserved bytes (11 * 4 = 44 bytes)
	reader.seek(reader.get_position() + 44)

	# Read pixel format (32 bytes)
	var pf_size := reader.get_32()
	if pf_size != 32:
		return null

	var pf_flags := reader.get_32()
	var fourcc := reader.get_32()
	var rgb_bit_count := reader.get_32()
	var r_mask := reader.get_32()
	var g_mask := reader.get_32()
	var b_mask := reader.get_32()
	var a_mask := reader.get_32()

	# Skip caps (16 bytes) and reserved (4 bytes)
	reader.seek(reader.get_position() + 20)

	# Determine format and load
	if pf_flags & DDPF_FOURCC:
		return _load_compressed(reader, width, height, mipmap_count, fourcc, base_mip_only)
	elif pf_flags & DDPF_RGB:
		var has_alpha := (pf_flags & DDPF_ALPHAPIXELS) != 0
		return _load_uncompressed(reader, width, height, rgb_bit_count, has_alpha, r_mask, g_mask, b_mask, a_mask)

	return null


## Load DXT compressed texture
static func _load_compressed(reader: StreamPeerBuffer, width: int, height: int, mipmap_count: int, fourcc: int, base_mip_only: bool) -> Image:
	var block_size: int
	var godot_format: Image.Format

	match fourcc:
		FOURCC_DXT1:
			block_size = 8
			godot_format = Image.FORMAT_DXT1
		FOURCC_DXT3:
			block_size = 16
			godot_format = Image.FORMAT_DXT3
		FOURCC_DXT5:
			block_size = 16
			godot_format = Image.FORMAT_DXT5
		_:
			push_warning("DDSLoader: Unsupported FourCC: 0x%X" % fourcc)
			return null

	# Calculate size for base mip level
	var blocks_x := maxi(1, (width + 3) / 4)
	var blocks_y := maxi(1, (height + 3) / 4)
	var base_size := blocks_x * blocks_y * block_size

	var data_start := reader.get_position()
	var remaining := reader.data_array.size() - data_start

	if base_mip_only or mipmap_count <= 1:
		# Load only base mip level
		if remaining < base_size:
			push_warning("DDSLoader: Not enough data for base mip level (need %d, have %d)" % [base_size, remaining])
			return null

		var pixel_data := reader.data_array.slice(data_start, data_start + base_size)
		return Image.create_from_data(width, height, false, godot_format, pixel_data)
	else:
		# Try to load all mipmaps, fall back to base only if data is truncated
		var total_size := _calculate_mipmap_chain_size(width, height, mipmap_count, block_size)

		if remaining >= total_size:
			# Full mipmap chain available
			var pixel_data := reader.data_array.slice(data_start, data_start + total_size)
			return Image.create_from_data(width, height, true, godot_format, pixel_data)
		else:
			# Truncated chain - load base only
			if remaining < base_size:
				push_warning("DDSLoader: Data truncated, not enough for base mip")
				return null

			var pixel_data := reader.data_array.slice(data_start, data_start + base_size)
			return Image.create_from_data(width, height, false, godot_format, pixel_data)


## Calculate total size for mipmap chain
static func _calculate_mipmap_chain_size(width: int, height: int, mip_count: int, block_size: int) -> int:
	var total := 0
	var w := width
	var h := height

	for i in range(mip_count):
		var blocks_x := maxi(1, (w + 3) / 4)
		var blocks_y := maxi(1, (h + 3) / 4)
		total += blocks_x * blocks_y * block_size
		w = maxi(1, w / 2)
		h = maxi(1, h / 2)

	return total


## Load uncompressed texture
static func _load_uncompressed(reader: StreamPeerBuffer, width: int, height: int, bit_count: int, has_alpha: bool, r_mask: int, g_mask: int, b_mask: int, a_mask: int) -> Image:
	var bytes_per_pixel := bit_count / 8
	var data_size := width * height * bytes_per_pixel
	var data_start := reader.get_position()

	if reader.data_array.size() - data_start < data_size:
		push_warning("DDSLoader: Not enough data for uncompressed texture")
		return null

	# Common formats
	if bit_count == 32 and r_mask == 0x00FF0000 and g_mask == 0x0000FF00 and b_mask == 0x000000FF:
		# BGRA8
		var raw_data := reader.data_array.slice(data_start, data_start + data_size)
		var rgba_data := PackedByteArray()
		rgba_data.resize(width * height * 4)

		for i in range(width * height):
			var src := i * 4
			var dst := i * 4
			rgba_data[dst + 0] = raw_data[src + 2]  # R
			rgba_data[dst + 1] = raw_data[src + 1]  # G
			rgba_data[dst + 2] = raw_data[src + 0]  # B
			rgba_data[dst + 3] = raw_data[src + 3] if has_alpha else 255  # A

		return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, rgba_data)

	elif bit_count == 24 and r_mask == 0x00FF0000 and g_mask == 0x0000FF00 and b_mask == 0x000000FF:
		# BGR8
		var raw_data := reader.data_array.slice(data_start, data_start + data_size)
		var rgb_data := PackedByteArray()
		rgb_data.resize(width * height * 3)

		for i in range(width * height):
			var src := i * 3
			var dst := i * 3
			rgb_data[dst + 0] = raw_data[src + 2]  # R
			rgb_data[dst + 1] = raw_data[src + 1]  # G
			rgb_data[dst + 2] = raw_data[src + 0]  # B

		return Image.create_from_data(width, height, false, Image.FORMAT_RGB8, rgb_data)

	push_warning("DDSLoader: Unsupported uncompressed format: %d-bit, R=0x%X G=0x%X B=0x%X" % [bit_count, r_mask, g_mask, b_mask])
	return null
