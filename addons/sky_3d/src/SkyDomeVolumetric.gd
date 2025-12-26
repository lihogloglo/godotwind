# Copyright (c) 2023-2025 Cory Petkovsek and Contributors
# Volumetric cloud extension for Sky3D

## SkyDomeVolumetric extends [SkyDome] with volumetric raymarched clouds.
##
## This class replaces the simple 2D cumulus clouds with volumetric raymarched
## clouds inspired by the Sky++ shader. It maintains full compatibility with
## the existing Sky3D time-of-day system.
##
## To use:
## 1. Replace your SkyDome node with SkyDomeVolumetric
## 2. Assign the SkyMaterialVolumetric shader to your sky material
## 3. Configure the volumetric cloud settings in the inspector

@tool
class_name SkyDomeVolumetric
extends SkyDome

const VOLUMETRIC_SHADER: String = "res://addons/sky_3d/shaders/SkyMaterialVolumetric.gdshader"

#####################
## Volumetric Clouds
#####################

@export_group("Volumetric Clouds")

## Enable/disable volumetric raymarched clouds (replaces cumulus)
@export var volumetric_clouds_enabled: bool = true :
	set(value):
		volumetric_clouds_enabled = value
		if is_scene_built:
			sky_material.set_shader_parameter("volumetric_clouds_enabled", value)
			_check_cloud_processing()


@export_subgroup("Colors")

## Base color of lit cloud surfaces
@export var vol_cloud_base_color := Color(0.95, 0.95, 1.0) :
	set(value):
		vol_cloud_base_color = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_base_color", Vector3(value.r, value.g, value.b))

## Color of shadowed cloud areas
@export var vol_cloud_shadow_color := Color(0.4, 0.45, 0.55) :
	set(value):
		vol_cloud_shadow_color = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_shadow_color", Vector3(value.r, value.g, value.b))

## Daytime tint applied to clouds
@export var vol_cloud_day_tint := Color(1.0, 1.0, 1.0) :
	set(value):
		vol_cloud_day_tint = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_day_tint", value)

## Sunrise/sunset tint applied to clouds
@export var vol_cloud_horizon_tint := Color(1.0, 0.85, 0.7) :
	set(value):
		vol_cloud_horizon_tint = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_horizon_tint", value)

## Nighttime tint applied to clouds
@export var vol_cloud_night_tint := Color(0.12, 0.14, 0.18) :
	set(value):
		vol_cloud_night_tint = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_night_tint", value)


@export_subgroup("Density")

## How much of the sky is covered by clouds (0 = clear, 1 = overcast)
## 0.5 gives nice visible clouds, 0.35 for partly cloudy
@export_range(0.0, 1.0, 0.01) var vol_cloud_coverage: float = 0.5 :
	set(value):
		vol_cloud_coverage = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_coverage", value)

## Overall density multiplier for clouds
@export_range(0.1, 3.0, 0.1) var vol_cloud_density: float = 1.0 :
	set(value):
		vol_cloud_density = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_density_mult", value)

## Smoothness of cloud edges
@export_range(0.0, 0.2, 0.01) var vol_cloud_smoothness: float = 0.05 :
	set(value):
		vol_cloud_smoothness = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_smoothness", value)


@export_subgroup("Shape")

## Base height of cloud layer (affects perspective)
@export_range(1.0, 20.0, 0.5) var vol_cloud_base_height: float = 3.0 :
	set(value):
		vol_cloud_base_height = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_base_height", value)

## Vertical thickness of cloud layer
@export_range(1.0, 20.0, 0.5) var vol_cloud_thickness: float = 10.0 :
	set(value):
		vol_cloud_thickness = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_layer_thickness", value)

## Scale of cloud formations (smaller = larger clouds)
## 0.8-1.2 works well for visible clouds
@export_range(0.1, 5.0, 0.1) var vol_cloud_scale: float = 1.0 :
	set(value):
		vol_cloud_scale = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_scale", value)

## Strength of detail noise erosion
@export_range(0.0, 1.0, 0.05) var vol_cloud_detail_strength: float = 0.2 :
	set(value):
		vol_cloud_detail_strength = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_detail_strength", value)


@export_subgroup("Raymarching")

## Number of raymarching steps (higher = better quality, lower performance)
## 16 is a good balance for real-time, 32+ for quality screenshots
@export_range(8, 64, 1) var vol_cloud_march_steps: int = 16 :
	set(value):
		vol_cloud_march_steps = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_march_steps", value)

## Number of light marching steps (higher = better shadows)
## 4 is good for real-time, 6+ for quality
@export_range(2, 12, 1) var vol_cloud_light_steps: int = 4 :
	set(value):
		vol_cloud_light_steps = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_light_steps", value)

## Falloff power for horizon blending
@export_range(0.1, 1.0, 0.05) var vol_cloud_falloff: float = 0.4 :
	set(value):
		vol_cloud_falloff = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_falloff_power", value)

## Enable temporal jitter to reduce banding (can cause shimmer when camera moves)
@export var vol_cloud_temporal_jitter: bool = false :
	set(value):
		vol_cloud_temporal_jitter = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_temporal_jitter", value)


@export_subgroup("Lighting")

## Strength of direct sunlight on clouds
@export_range(0.0, 30.0, 0.5) var vol_cloud_light_strength: float = 10.0 :
	set(value):
		vol_cloud_light_strength = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_light_strength", value)

## Strength of ambient sky lighting
@export_range(0.0, 1.0, 0.05) var vol_cloud_ambient: float = 0.35 :
	set(value):
		vol_cloud_ambient = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_ambient_strength", value)

## Anisotropy of light scattering (0 = uniform, 0.95 = forward scattering)
## Sky++ uses 0.25 for softer, more diffuse cloud lighting
@export_range(0.0, 0.95, 0.05) var vol_cloud_anisotropy: float = 0.25 :
	set(value):
		vol_cloud_anisotropy = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_anisotropy", value)

## Light absorption coefficient inside clouds
@export_range(0.1, 2.0, 0.1) var vol_cloud_absorption: float = 0.7 :
	set(value):
		vol_cloud_absorption = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_absorption_coeff", value)

## Powder effect strength (darkens thin cloud edges)
@export_range(0.0, 1.0, 0.1) var vol_cloud_powder: float = 0.5 :
	set(value):
		vol_cloud_powder = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_powder_strength", value)


@export_subgroup("Textures")

## Use procedural noise instead of 3D textures.
## Procedural noise is SLOW - only use for testing without prebaked textures.
## For production, run the prebake script and disable this option.
## Prebake: res://addons/sky_3d/tools/prebake_cloud_noise.gd (Script > Run in editor)
@export var vol_use_procedural_noise: bool = false :
	set(value):
		vol_use_procedural_noise = value
		if is_scene_built:
			sky_material.set_shader_parameter("use_procedural_noise", value)

## 3D Shape noise texture (only used when procedural noise is disabled)
## Generate using CloudNoiseGenerator.generate_shape_noise()
@export var vol_cloud_shape_texture: Texture3D :
	set(value):
		vol_cloud_shape_texture = value
		if is_scene_built and value:
			sky_material.set_shader_parameter("cloud_shape_texture", value)

## 3D Detail noise texture (only used when procedural noise is disabled)
## Generate using CloudNoiseGenerator.generate_detail_noise()
@export var vol_cloud_detail_texture: Texture3D :
	set(value):
		vol_cloud_detail_texture = value
		if is_scene_built and value:
			sky_material.set_shader_parameter("cloud_detail_texture", value)

## Scale of shape noise sampling (Sky++ default: 1.0)
@export_range(0.1, 3.0, 0.1) var vol_cloud_shape_scale: float = 1.0 :
	set(value):
		vol_cloud_shape_scale = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_shape_scale", value)

## Scale of detail noise sampling (Sky++ default: 2.0)
@export_range(0.5, 10.0, 0.5) var vol_cloud_detail_scale: float = 2.0 :
	set(value):
		vol_cloud_detail_scale = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_detail_scale", value)

## Blend factor between shape and detail noise (Sky++ default: 0.5)
@export_range(0.0, 1.0, 0.05) var vol_cloud_noise_blend: float = 0.5 :
	set(value):
		vol_cloud_noise_blend = value
		if is_scene_built:
			sky_material.set_shader_parameter("cloud_noise_blend", value)


# Internal cloud position for wind movement
var _vol_cloud_offset := Vector3.ZERO

# Volumetric cloud speed factor - converts wind speed (m/s) to shader offset units.
# Real cumulus clouds at ~2000m altitude with 10 m/s wind move very slowly relative
# to their apparent size. This factor scales down the base WIND_SPEED_FACTOR (0.01)
# to match the volumetric shader's coordinate space where cloud_offset is added
# after position is already scaled by 0.01 in the shader.
# Value of 0.001 means: 1 m/s wind = 0.00001 units/second offset in shader space,
# which results in clouds drifting slowly and naturally.
const VOLUMETRIC_CLOUD_SPEED_FACTOR: float = 0.001


func _ready() -> void:
	super._ready()
	_setup_volumetric_clouds()


func _setup_volumetric_clouds() -> void:
	if not is_scene_built:
		return

	# Initialize all volumetric cloud shader parameters
	# (The base SkyDome._build_scene() only triggers setters for SkyDome properties,
	# not SkyDomeVolumetric properties, so we must do it here)
	_init_volumetric_shader_params()

	# If not using procedural noise, load or generate 3D textures
	if not vol_use_procedural_noise:
		if not vol_cloud_shape_texture or not vol_cloud_detail_texture:
			_load_or_generate_noise_textures()


## Initialize all volumetric cloud shader parameters
func _init_volumetric_shader_params() -> void:
	# Enable flag
	sky_material.set_shader_parameter("volumetric_clouds_enabled", volumetric_clouds_enabled)

	# Colors
	sky_material.set_shader_parameter("cloud_base_color", Vector3(vol_cloud_base_color.r, vol_cloud_base_color.g, vol_cloud_base_color.b))
	sky_material.set_shader_parameter("cloud_shadow_color", Vector3(vol_cloud_shadow_color.r, vol_cloud_shadow_color.g, vol_cloud_shadow_color.b))
	sky_material.set_shader_parameter("cloud_day_tint", vol_cloud_day_tint)
	sky_material.set_shader_parameter("cloud_horizon_tint", vol_cloud_horizon_tint)
	sky_material.set_shader_parameter("cloud_night_tint", vol_cloud_night_tint)

	# Density
	sky_material.set_shader_parameter("cloud_coverage", vol_cloud_coverage)
	sky_material.set_shader_parameter("cloud_density_mult", vol_cloud_density)
	sky_material.set_shader_parameter("cloud_smoothness", vol_cloud_smoothness)

	# Shape
	sky_material.set_shader_parameter("cloud_base_height", vol_cloud_base_height)
	sky_material.set_shader_parameter("cloud_layer_thickness", vol_cloud_thickness)
	sky_material.set_shader_parameter("cloud_scale", vol_cloud_scale)
	sky_material.set_shader_parameter("cloud_detail_strength", vol_cloud_detail_strength)

	# Raymarching
	sky_material.set_shader_parameter("cloud_march_steps", vol_cloud_march_steps)
	sky_material.set_shader_parameter("cloud_light_steps", vol_cloud_light_steps)
	sky_material.set_shader_parameter("cloud_falloff_power", vol_cloud_falloff)
	sky_material.set_shader_parameter("cloud_temporal_jitter", vol_cloud_temporal_jitter)

	# Lighting
	sky_material.set_shader_parameter("cloud_light_strength", vol_cloud_light_strength)
	sky_material.set_shader_parameter("cloud_ambient_strength", vol_cloud_ambient)
	sky_material.set_shader_parameter("cloud_anisotropy", vol_cloud_anisotropy)
	sky_material.set_shader_parameter("cloud_absorption_coeff", vol_cloud_absorption)
	sky_material.set_shader_parameter("cloud_powder_strength", vol_cloud_powder)

	# Textures
	sky_material.set_shader_parameter("use_procedural_noise", vol_use_procedural_noise)
	sky_material.set_shader_parameter("cloud_shape_scale", vol_cloud_shape_scale)
	sky_material.set_shader_parameter("cloud_detail_scale", vol_cloud_detail_scale)
	sky_material.set_shader_parameter("cloud_noise_blend", vol_cloud_noise_blend)
	if vol_cloud_shape_texture:
		sky_material.set_shader_parameter("cloud_shape_texture", vol_cloud_shape_texture)
	if vol_cloud_detail_texture:
		sky_material.set_shader_parameter("cloud_detail_texture", vol_cloud_detail_texture)

	# Initial offset
	sky_material.set_shader_parameter("cloud_offset", _vol_cloud_offset)


## Load pre-generated 3D noise textures, or generate them if not found
func _load_or_generate_noise_textures() -> void:
	# Check if prebaked slices exist
	var slice_dir := "res://addons/sky_3d/assets/resources/cloud_noise/"
	var shape_meta_path := slice_dir + "shape_meta.json"
	var detail_meta_path := slice_dir + "detail_meta.json"

	if FileAccess.file_exists(shape_meta_path) and FileAccess.file_exists(detail_meta_path):
		print("Sky3D: Loading prebaked cloud noise from slices...")
		vol_cloud_shape_texture = _load_texture_from_slices(slice_dir, "shape")
		vol_cloud_detail_texture = _load_texture_from_slices(slice_dir, "detail")
		if vol_cloud_shape_texture and vol_cloud_detail_texture:
			print("Sky3D: Loaded prebaked cloud noise textures")
			return

	# Fallback: check for binary .res format
	var shape_path := "res://addons/sky_3d/assets/resources/cloud_shape_noise.res"
	var detail_path := "res://addons/sky_3d/assets/resources/cloud_detail_noise.res"
	if ResourceLoader.exists(shape_path) and ResourceLoader.exists(detail_path):
		vol_cloud_shape_texture = load(shape_path)
		vol_cloud_detail_texture = load(detail_path)
		print("Sky3D: Loaded pre-generated cloud noise textures (.res)")
		return

	# No prebaked textures found - fall back to procedural (slower but works)
	push_warning("Sky3D: No prebaked cloud textures found. Using procedural noise (slower).")
	push_warning("Sky3D: Run 'godot --headless --script res://prebake_clouds.gd' to prebake textures.")
	vol_use_procedural_noise = true
	sky_material.set_shader_parameter("use_procedural_noise", true)


## Load a 3D texture from prebaked image slices
func _load_texture_from_slices(dir: String, name: String) -> ImageTexture3D:
	var meta_path := dir + name + "_meta.json"
	if not FileAccess.file_exists(meta_path):
		return null

	var meta_file := FileAccess.open(meta_path, FileAccess.READ)
	var meta_json := JSON.parse_string(meta_file.get_as_text())
	meta_file.close()

	if not meta_json:
		push_error("Sky3D: Failed to parse %s" % meta_path)
		return null

	var size: int = meta_json.get("size", 0)
	var slices: int = meta_json.get("slices", 0)

	if size == 0 or slices == 0:
		push_error("Sky3D: Invalid metadata in %s" % meta_path)
		return null

	var images: Array[Image] = []
	for z in range(slices):
		var slice_path := dir + "%s_%03d.exr" % [name, z]
		if not FileAccess.file_exists(slice_path):
			push_error("Sky3D: Missing slice %s" % slice_path)
			return null

		var img := Image.load_from_file(slice_path)
		if not img:
			push_error("Sky3D: Failed to load %s" % slice_path)
			return null

		images.append(img)

	var tex := ImageTexture3D.new()
	tex.create(images[0].get_format(), size, size, slices, false, images)
	return tex


## Override cloud processing to also update volumetric cloud offset
func process_tick(delta: float) -> void:
	super.process_tick(delta)

	if not volumetric_clouds_enabled:
		return

	# Update volumetric cloud wind offset using the volumetric-specific speed factor.
	# We use wind_speed directly (m/s) and apply our own factor, rather than using
	# _cloud_speed which already has WIND_SPEED_FACTOR applied for 2D clouds.
	var vol_speed: float = wind_speed * VOLUMETRIC_CLOUD_SPEED_FACTOR
	var wind_velocity := _cloud_direction * vol_speed * delta
	_vol_cloud_offset.x += wind_velocity.x
	_vol_cloud_offset.z += wind_velocity.y

	if is_scene_built:
		sky_material.set_shader_parameter("cloud_offset", _vol_cloud_offset)


## Check if any cloud type needs processing
func _check_cloud_processing() -> void:
	var enable: bool = (cirrus_visible or cumulus_visible or volumetric_clouds_enabled) and wind_speed != 0.0
	_cloud_velocity = _cloud_direction * _cloud_speed
	match process_method:
		PHYSICS_PROCESS:
			set_physics_process(enable)
			set_process(!enable)
		PROCESS:
			set_physics_process(!enable)
			set_process(enable)
		MANUAL, _:
			set_physics_process(false)
			set_process(false)
