## DeformationPreset - Material behavior configuration for deformation system
## Defines how different surfaces (snow, mud, ash) respond to deformation
class_name DeformationPreset
extends Resource

## Material identification
@export var material_name: String = "Snow"

## Physical properties
@export_group("Physical Properties")
@export_range(0.0, 1.0) var max_depth: float = 0.3  ## Maximum deformation depth in meters
@export_range(0.0, 1.0) var compression_factor: float = 0.7  ## How much material compresses (1.0 = full, 0.0 = none)

## Accumulation (permanent deformation)
@export_group("Accumulation")
@export var enable_accumulation: bool = true  ## Enable permanent deformation
@export_range(0.0, 1.0) var accumulation_rate: float = 0.5  ## How fast deformation becomes permanent
@export_range(0.0, 1.0) var accumulation_threshold: float = 0.3  ## Minimum depth to start accumulating

## Decay (temporary deformation fade)
@export_group("Decay")
@export var enable_decay: bool = false  ## Enable deformation fade over time
@export var decay_rate: float = 0.1  ## Units per second
@export var decay_delay: float = 5.0  ## Seconds before decay starts

## Visual properties
@export_group("Visual")
@export_range(0.0, 1.0) var normal_strength: float = 0.8  ## How much deformation affects normals
@export_range(0.0, 1.0) var edge_sharpness: float = 0.6  ## Sharpness of deformation edges (0=soft, 1=sharp)
@export var color_tint: Color = Color.WHITE  ## Tint for deformed areas

## Behavior constraints
@export_group("Behavior")
@export_range(0.0, 90.0) var max_slope_angle: float = 45.0  ## Maximum slope angle for deformation (degrees)
@export var displacement_curve: Curve  ## Optional curve for non-linear depth mapping


## Create a snow preset
static func create_snow_preset() -> DeformationPreset:
	var preset := DeformationPreset.new()
	preset.material_name = "Snow"
	preset.max_depth = 0.4
	preset.compression_factor = 0.85
	preset.enable_accumulation = true
	preset.accumulation_rate = 0.6
	preset.accumulation_threshold = 0.25
	preset.enable_decay = true
	preset.decay_rate = 0.02  # Very slow melting
	preset.decay_delay = 30.0
	preset.edge_sharpness = 0.3  # Soft edges
	preset.color_tint = Color(0.95, 0.95, 1.0)  # Slight blue tint
	preset.max_slope_angle = 45.0
	return preset


## Create a mud preset
static func create_mud_preset() -> DeformationPreset:
	var preset := DeformationPreset.new()
	preset.material_name = "Mud"
	preset.max_depth = 0.25
	preset.compression_factor = 0.6
	preset.enable_accumulation = true
	preset.accumulation_rate = 0.8
	preset.accumulation_threshold = 0.15
	preset.enable_decay = false  # Permanent tracks
	preset.edge_sharpness = 0.7  # Sharp edges
	preset.color_tint = Color(0.6, 0.5, 0.4)  # Brown tint
	preset.max_slope_angle = 30.0
	return preset


## Create an ash preset
static func create_ash_preset() -> DeformationPreset:
	var preset := DeformationPreset.new()
	preset.material_name = "Ash"
	preset.max_depth = 0.5
	preset.compression_factor = 0.9
	preset.enable_accumulation = true
	preset.accumulation_rate = 0.7
	preset.accumulation_threshold = 0.2
	preset.enable_decay = true
	preset.decay_rate = 0.05  # Medium decay
	preset.decay_delay = 15.0
	preset.edge_sharpness = 0.2  # Very soft edges
	preset.color_tint = Color(0.7, 0.7, 0.7)  # Gray tint
	preset.max_slope_angle = 35.0
	return preset
