# DeformationConfig.gd
# Configuration class for RTT deformation system
# Allows users to enable/disable and tune the deformation system
class_name DeformationConfig
extends RefCounted

# Master enable/disable
static var enabled: bool = false  # Disabled by default for safety

# Feature flags
static var enable_terrain_integration: bool = true
static var enable_recovery: bool = false
static var enable_persistence: bool = true
static var enable_streaming: bool = true

# Camera settings
static var camera_follow_player: bool = false
static var camera_follow_radius: float = 40.0  # Meters (only used when camera_follow_player = true)

# Performance settings
static var update_budget_ms: float = 2.0
static var max_active_regions: int = 9
static var texture_size: int = 1024

# Recovery settings
static var recovery_rate: float = 0.01
static var recovery_update_interval: float = 1.0

# Persistence settings
static var save_format: String = "exr"  # "exr" or "png"
static var auto_save_on_unload: bool = true

# Debug settings
static var debug_mode: bool = false
static var show_region_bounds: bool = false

# Load configuration from project settings
static func load_from_project_settings() -> void:
	enabled = _get_project_setting("deformation/enabled", false)
	enable_terrain_integration = _get_project_setting("deformation/enable_terrain_integration", true)
	enable_recovery = _get_project_setting("deformation/enable_recovery", false)
	enable_persistence = _get_project_setting("deformation/enable_persistence", true)
	enable_streaming = _get_project_setting("deformation/enable_streaming", true)

	camera_follow_player = _get_project_setting("deformation/camera/follow_player", false)
	camera_follow_radius = _get_project_setting("deformation/camera/follow_radius", 40.0)

	update_budget_ms = _get_project_setting("deformation/performance/update_budget_ms", 2.0)
	max_active_regions = _get_project_setting("deformation/performance/max_active_regions", 9)
	texture_size = _get_project_setting("deformation/performance/texture_size", 1024)

	recovery_rate = _get_project_setting("deformation/recovery/rate", 0.01)
	recovery_update_interval = _get_project_setting("deformation/recovery/update_interval", 1.0)

	save_format = _get_project_setting("deformation/persistence/format", "exr")
	auto_save_on_unload = _get_project_setting("deformation/persistence/auto_save", true)

	debug_mode = _get_project_setting("deformation/debug/enabled", false)
	show_region_bounds = _get_project_setting("deformation/debug/show_region_bounds", false)

	if debug_mode:
		print("[DeformationConfig] Configuration loaded:")
		print("  - Enabled: ", enabled)
		print("  - Terrain Integration: ", enable_terrain_integration)
		print("  - Recovery: ", enable_recovery)
		print("  - Persistence: ", enable_persistence)
		print("  - Streaming: ", enable_streaming)
		print("  - Texture Size: ", texture_size)
		print("  - Max Regions: ", max_active_regions)

static func _get_project_setting(setting_name: String, default_value):
	if ProjectSettings.has_setting(setting_name):
		return ProjectSettings.get_setting(setting_name)
	return default_value

# Register project settings (call this once to add settings to project)
static func register_project_settings() -> void:
	_register_setting("deformation/enabled", false, TYPE_BOOL,
		"Enable RTT deformation system globally")

	_register_setting("deformation/enable_terrain_integration", true, TYPE_BOOL,
		"Enable integration with Terrain3D")

	_register_setting("deformation/enable_recovery", false, TYPE_BOOL,
		"Enable time-based recovery (deformations fade over time)")

	_register_setting("deformation/enable_persistence", true, TYPE_BOOL,
		"Enable save/load of deformation data")

	_register_setting("deformation/enable_streaming", true, TYPE_BOOL,
		"Enable automatic region streaming with terrain")

	_register_setting("deformation/camera/follow_player", false, TYPE_BOOL,
		"Make RTT camera follow the player instead of using static region cameras")

	_register_setting("deformation/camera/follow_radius", 40.0, TYPE_FLOAT,
		"Camera viewport radius when following player (meters, only used if camera_follow_player = true)")

	_register_setting("deformation/performance/update_budget_ms", 2.0, TYPE_FLOAT,
		"Time budget per frame for deformation updates (milliseconds)")

	_register_setting("deformation/performance/max_active_regions", 9, TYPE_INT,
		"Maximum number of active deformation regions (higher = more memory)")

	_register_setting("deformation/performance/texture_size", 1024, TYPE_INT,
		"Deformation texture resolution per region (1024, 512, or 256)")

	_register_setting("deformation/recovery/rate", 0.01, TYPE_FLOAT,
		"Recovery rate (units per second, 0.01 = 1% per second)")

	_register_setting("deformation/recovery/update_interval", 1.0, TYPE_FLOAT,
		"How often to update recovery (seconds, higher = better performance)")

	_register_setting("deformation/persistence/format", "exr", TYPE_STRING,
		"Save format for deformation data (exr=lossless, png=lossy)")

	_register_setting("deformation/persistence/auto_save", true, TYPE_BOOL,
		"Automatically save deformation data when regions unload")

	_register_setting("deformation/debug/enabled", false, TYPE_BOOL,
		"Enable debug logging for deformation system")

	_register_setting("deformation/debug/show_region_bounds", false, TYPE_BOOL,
		"Visualize deformation region boundaries (requires DebugDraw)")

static func _register_setting(name: String, default_value, type: int, hint: String) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default_value)
		ProjectSettings.set_initial_value(name, default_value)

		var property_info = {
			"name": name,
			"type": type,
			"hint_string": hint
		}
		ProjectSettings.add_property_info(property_info)

# Quick enable/disable methods
static func enable_system() -> void:
	enabled = true
	ProjectSettings.set_setting("deformation/enabled", true)

static func disable_system() -> void:
	enabled = false
	ProjectSettings.set_setting("deformation/enabled", false)

# Validate configuration
static func validate() -> bool:
	if texture_size not in [256, 512, 1024, 2048]:
		push_warning("[DeformationConfig] Invalid texture_size: ", texture_size, " (using 1024)")
		texture_size = 1024
		return false

	if max_active_regions < 1 or max_active_regions > 25:
		push_warning("[DeformationConfig] Invalid max_active_regions: ", max_active_regions, " (using 9)")
		max_active_regions = 9
		return false

	if update_budget_ms < 0.1 or update_budget_ms > 16.0:
		push_warning("[DeformationConfig] Invalid update_budget_ms: ", update_budget_ms, " (using 2.0)")
		update_budget_ms = 2.0
		return false

	return true
