## HardwareDetection - Detects GPU capabilities and selects appropriate water quality
## Provides fallbacks for systems without dedicated GPU or with limited shader support
class_name HardwareDetection
extends RefCounted

enum WaterQuality {
	ULTRA_LOW,  # Flat plane with basic material (no shader)
	LOW,        # Simple vertex waves, basic fragment
	MEDIUM,     # Gerstner waves, no screen sampling
	HIGH,       # Full shader with all effects
}

# Cached detection results
static var _detected: bool = false
static var _has_compute: bool = false
static var _has_depth_texture: bool = false
static var _has_screen_texture: bool = false
static var _has_texture_arrays: bool = false
static var _gpu_name: String = ""
static var _renderer_name: String = ""
static var _is_integrated_gpu: bool = false
static var _recommended_quality: WaterQuality = WaterQuality.HIGH

# Known integrated GPU patterns
const INTEGRATED_GPU_PATTERNS: Array[String] = [
	"intel",
	"mesa",
	"llvmpipe",  # Software renderer
	"swiftshader",
	"softpipe",
	"virgl",  # Virtual GPU
	"virtio",
	"vmware",
	"virtualbox",
	"parallels",
	"integrated",
	"igpu",
	"uhd graphics",
	"hd graphics",
	"iris",
	"adreno",  # Mobile GPU
	"mali",   # Mobile GPU
	"powervr",  # Mobile GPU
	"apple m",  # Apple Silicon (capable but conservative)
]

# Known low-end dedicated GPUs
const LOW_END_GPU_PATTERNS: Array[String] = [
	"geforce gt",
	"geforce 9",
	"geforce 8",
	"radeon hd 5",
	"radeon hd 4",
	"radeon r5",
	"radeon r7 2",
]


static func detect() -> void:
	if _detected:
		return

	_detected = true

	# Get GPU info from RenderingServer
	var info := RenderingServer.get_video_adapter_name()
	var vendor := RenderingServer.get_video_adapter_vendor()
	_gpu_name = info
	_renderer_name = vendor + " " + info

	print("[HardwareDetection] GPU: %s" % _renderer_name)

	# Check for integrated GPU
	var gpu_lower := _gpu_name.to_lower()
	var vendor_lower := vendor.to_lower()
	var combined := (gpu_lower + " " + vendor_lower)

	for pattern in INTEGRATED_GPU_PATTERNS:
		if combined.contains(pattern):
			_is_integrated_gpu = true
			break

	# Check for compute shader support
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	_has_compute = rd != null

	# Check rendering features
	# These are typically available on any modern GPU, but may fail on software renderers
	_has_depth_texture = true  # Usually available
	_has_screen_texture = true  # Usually available
	_has_texture_arrays = true  # Usually available

	# Software renderers have limited support
	if combined.contains("llvmpipe") or combined.contains("softpipe") or combined.contains("swiftshader"):
		_has_compute = false
		_has_depth_texture = false
		_has_screen_texture = false
		_has_texture_arrays = false

	# Determine recommended quality
	_recommended_quality = _calculate_recommended_quality()

	print("[HardwareDetection] Integrated GPU: %s" % _is_integrated_gpu)
	print("[HardwareDetection] Has compute: %s" % _has_compute)
	print("[HardwareDetection] Recommended water quality: %s" % WaterQuality.keys()[_recommended_quality])


static func _calculate_recommended_quality() -> WaterQuality:
	var gpu_lower := _gpu_name.to_lower()

	# Software renderer = ultra low
	if gpu_lower.contains("llvmpipe") or gpu_lower.contains("softpipe") or gpu_lower.contains("swiftshader"):
		return WaterQuality.ULTRA_LOW

	# Check for very old/low-end GPUs
	for pattern in LOW_END_GPU_PATTERNS:
		if gpu_lower.contains(pattern):
			return WaterQuality.LOW

	# Integrated GPU = medium (skip expensive screen effects)
	if _is_integrated_gpu:
		return WaterQuality.MEDIUM

	# Dedicated GPU with compute = high
	if _has_compute:
		return WaterQuality.HIGH

	# Default to medium for safety
	return WaterQuality.MEDIUM


## Get the recommended water quality level
static func get_recommended_quality() -> WaterQuality:
	detect()
	return _recommended_quality


## Check if GPU has compute shader support
static func has_compute_support() -> bool:
	detect()
	return _has_compute


## Check if GPU can sample depth texture efficiently
static func has_depth_texture_support() -> bool:
	detect()
	return _has_depth_texture


## Check if GPU can sample screen texture efficiently
static func has_screen_texture_support() -> bool:
	detect()
	return _has_screen_texture


## Check if this is an integrated GPU
static func is_integrated_gpu() -> bool:
	detect()
	return _is_integrated_gpu


## Get GPU name for display
static func get_gpu_name() -> String:
	detect()
	return _gpu_name


## Get full renderer info
static func get_renderer_info() -> String:
	detect()
	return _renderer_name


## Get quality level name as string
static func quality_name(quality: WaterQuality) -> String:
	match quality:
		WaterQuality.ULTRA_LOW:
			return "Ultra Low (Flat)"
		WaterQuality.LOW:
			return "Low (Basic Waves)"
		WaterQuality.MEDIUM:
			return "Medium (Gerstner)"
		WaterQuality.HIGH:
			return "High (Full Effects)"
	return "Unknown"


## Get a description of what each quality level does
static func quality_description(quality: WaterQuality) -> String:
	match quality:
		WaterQuality.ULTRA_LOW:
			return "Flat water plane with basic color. Best for software renderers."
		WaterQuality.LOW:
			return "Simple animated waves with basic lighting. For old/low-end GPUs."
		WaterQuality.MEDIUM:
			return "Gerstner waves with foam. No depth/screen effects. For integrated GPUs."
		WaterQuality.HIGH:
			return "Full ocean simulation with all effects. Requires dedicated GPU."
	return ""
