# Copyright (c) 2023-2025 Cory Petkovsek and Contributors
# Volumetric cloud extension for Sky3D

## Sky3DVolumetric extends [Sky3D] with volumetric raymarched clouds.
##
## This class is a drop-in replacement for Sky3D that uses the volumetric
## cloud shader instead of the standard 2D cloud shader.
##
## To use:
## 1. Replace your Sky3D node with Sky3DVolumetric
## 2. Configure volumetric cloud settings in the SkyDomeVolumetric child node

@tool
class_name Sky3DVolumetric
extends Sky3D

const VOLUMETRIC_SKY_SHADER: String = "res://addons/sky_3d/shaders/SkyMaterialVolumetric.gdshader"


func _initialize() -> void:
	# Create default environment
	if environment == null:
		environment = Environment.new()
		environment.background_mode = Environment.BG_SKY
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		environment.ambient_light_sky_contribution = 0.7
		environment.ambient_light_energy = 1.0
		environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
		environment.tonemap_mode = Environment.TONE_MAPPER_ACES
		environment.tonemap_white = 6
		# Screen-Space Reflections for water
		environment.ssr_enabled = true
		environment.ssr_max_steps = 64
		environment.ssr_fade_in = 0.15
		environment.ssr_fade_out = 2.0
		environment.ssr_depth_tolerance = 0.2
		emit_signal("environment_changed", environment)

	# Setup Sky material with VOLUMETRIC shader
	if environment.sky == null or environment.sky.sky_material is PhysicalSkyMaterial:
		environment.sky = Sky.new()
		environment.sky.sky_material = ShaderMaterial.new()
		environment.sky.sky_material.shader = load(VOLUMETRIC_SKY_SHADER)
	elif environment.sky.sky_material is ShaderMaterial:
		# Upgrade existing shader to volumetric if using old one
		var current_shader: Shader = environment.sky.sky_material.shader
		if current_shader and current_shader.resource_path == SKY_SHADER:
			environment.sky.sky_material.shader = load(VOLUMETRIC_SKY_SHADER)

	# Set a reference to the sky material for easy access.
	sky_material = environment.sky.sky_material

	# Create default camera attributes
	if camera_attributes == null:
		camera_attributes = CameraAttributesPractical.new()

	# Assign children nodes

	if has_node("SunLight"):
		sun = $SunLight
	elif is_inside_tree():
		sun = DirectionalLight3D.new()
		sun.name = "SunLight"
		add_child(sun, true)
		sun.owner = get_tree().edited_scene_root
		sun.shadow_enabled = true

	if has_node("MoonLight"):
		moon = $MoonLight
	elif is_inside_tree():
		moon = DirectionalLight3D.new()
		moon.name = "MoonLight"
		add_child(moon, true)
		moon.owner = get_tree().edited_scene_root
		moon.shadow_enabled = true

	# Use SkyDomeVolumetric instead of SkyDome
	if has_node("Skydome"):
		$Skydome.name = "SkyDome"
	if has_node("SkyDome"):
		sky = $SkyDome
		sky.environment = environment
	elif is_inside_tree():
		# Create SkyDomeVolumetric instead of regular SkyDome
		sky = SkyDomeVolumetric.new()
		sky.name = "SkyDome"
		add_child(sky, true)
		sky.owner = get_tree().edited_scene_root
		sky.sun_light_path = "../SunLight"
		sky.moon_light_path = "../MoonLight"
		sky.environment = environment

	if has_node("TimeOfDay"):
		tod = $TimeOfDay
	elif is_inside_tree():
		tod = TimeOfDay.new()
		tod.name = "TimeOfDay"
		add_child(tod, true)
		tod.owner = get_tree().edited_scene_root
		tod.dome_path = "../SkyDome"
	if sky and not sky.day_night_changed.is_connected(_start_sky_contrib_tween):
		sky.day_night_changed.connect(_start_sky_contrib_tween)


## Enable/disable volumetric clouds
@export var volumetric_clouds: bool = true :
	set(value):
		volumetric_clouds = value
		if sky and sky is SkyDomeVolumetric:
			sky.volumetric_clouds_enabled = value
	get:
		if sky and sky is SkyDomeVolumetric:
			return sky.volumetric_clouds_enabled
		return volumetric_clouds
