## ShaderManager - Hot-swappable post-processing shader management
##
## Provides runtime loading, enabling/disabling, and configuration of
## post-processing effects. Inspired by OpenMW's post-processor system.
##
## Usage:
## [codeblock]
## # Get the autoload
## var shader_mgr := ShaderManager
##
## # Load and enable an effect
## shader_mgr.load_effect("res://src/core/shaders/effects/volumetric_fog.gd")
## shader_mgr.enable_effect("volumetric_fog")
##
## # Tweak parameters at runtime
## shader_mgr.set_effect_param("volumetric_fog", "fog_density", 0.5)
##
## # Toggle effects with hotkeys
## shader_mgr.toggle_effect("volumetric_fog")
## [/codeblock]
extends Node

## Emitted when an effect is loaded
signal effect_loaded(effect_name: String)

## Emitted when an effect is enabled
signal effect_enabled(effect_name: String)

## Emitted when an effect is disabled
signal effect_disabled(effect_name: String)

## Emitted when an effect parameter changes
signal effect_param_changed(effect_name: String, param_name: String, value: Variant)

## Emitted when the effect stack changes
signal stack_changed(effect_names: Array[String])

## All loaded effects (name -> PostProcessEffect)
var _effects: Dictionary = {}

## Active effect stack (order matters for rendering)
var _effect_stack: Array[String] = []

## The Compositor resource we manage
var _compositor: Compositor

## Reference to the WorldEnvironment or Camera3D we're attached to
var _target_node: Node

## Preset configurations (name -> Dictionary of effect states)
var _presets: Dictionary = {}

## Current preset name (empty if custom)
var _current_preset: String = ""

## Shared textures for inter-effect data passing (Phase 3: texture registry)
## Effects write intermediate results here; subsequent effects read them.
## Example: sky transmittance LUT written by SkyTransmittanceEffect, read by FogEffect.
var _shared_textures: Dictionary = {}  # name: String → RID

## Config file path for saving/loading settings
const CONFIG_PATH := "user://shader_settings.cfg"

## Effect search paths
var _effect_paths: Array[String] = [
	"res://src/core/shaders/effects/"
]


func _ready() -> void:
	_compositor = Compositor.new()
	_load_built_in_effects()
	_load_config()
	Log.info("shaders", "ShaderManager initialized with %d effects" % _effects.size())


## Attach the shader manager to a WorldEnvironment or Camera3D
func attach_to(node: Node) -> void:
	_target_node = node

	if node is WorldEnvironment:
		# WorldEnvironment has compositor as a direct property, NOT on Environment
		node.compositor = _compositor
		Log.info("shaders", "ShaderManager attached to WorldEnvironment")
	elif node is Camera3D:
		node.compositor = _compositor
		Log.info("shaders", "ShaderManager attached to Camera3D")
	else:
		push_warning("[ShaderManager] Can only attach to WorldEnvironment or Camera3D")


## Set the active sun on all effects that support it (fog, godrays, etc.)
func set_sun(sun: DirectionalLight3D) -> void:
	for effect_name in _effects:
		var effect: PostProcessEffect = _effects[effect_name]
		if effect.has_method("set_sun"):
			effect.set_sun(sun)


## Detach from current target
func detach() -> void:
	if _target_node is WorldEnvironment:
		_target_node.compositor = null
	elif _target_node is Camera3D:
		_target_node.compositor = null
	_target_node = null


## Load an effect from a script path
func load_effect(path: String) -> bool:
	var script := load(path) as GDScript
	if script == null:
		push_error("[ShaderManager] Failed to load effect script: %s" % path)
		return false

	var effect: PostProcessEffect = script.new()
	if effect == null:
		push_error("[ShaderManager] Script is not a PostProcessEffect: %s" % path)
		return false

	if effect.effect_name in _effects:
		push_warning("[ShaderManager] Effect '%s' already loaded, replacing" % effect.effect_name)
		unload_effect(effect.effect_name)

	_effects[effect.effect_name] = effect
	effect.enabled = false  # Start disabled until explicitly enabled
	effect.parameter_changed.connect(_on_effect_param_changed.bind(effect.effect_name))

	effect_loaded.emit(effect.effect_name)
	Log.info("shaders", "Loaded effect: %s" % effect.effect_name)
	return true


## Unload an effect
func unload_effect(effect_name: String) -> void:
	if effect_name not in _effects:
		return

	disable_effect(effect_name)
	var effect: PostProcessEffect = _effects[effect_name]
	effect.on_effect_removed()

	_effects.erase(effect_name)
	Log.info("shaders", "Unloaded effect: %s" % effect_name)


## Enable an effect (add to compositor)
func enable_effect(effect_name: String, transition_time: float = 0.0) -> bool:
	if effect_name not in _effects:
		push_error("[ShaderManager] Effect not found: %s" % effect_name)
		return false

	var effect: PostProcessEffect = _effects[effect_name]

	if effect_name in _effect_stack:
		# Already enabled
		return true

	# Add to stack in priority order
	var insert_idx := _effect_stack.size()
	for i in _effect_stack.size():
		var other: PostProcessEffect = _effects[_effect_stack[i]]
		if effect.render_priority < other.render_priority:
			insert_idx = i
			break

	_effect_stack.insert(insert_idx, effect_name)

	# Add to compositor — must get/modify/set because GDScript Array properties return copies
	effect.effect_enabled = true
	effect.on_effect_added()
	var effects := _compositor.compositor_effects
	effects.append(effect)
	_compositor.compositor_effects = effects

	# Handle transition
	if transition_time > 0.0:
		effect.blend_factor = 0.0
		_start_transition(effect_name, 1.0, transition_time)
	else:
		effect.blend_factor = 1.0

	effect_enabled.emit(effect_name)
	stack_changed.emit(_effect_stack.duplicate())
	Log.info("shaders", "Enabled effect: %s" % effect_name)
	return true


## Disable an effect (remove from compositor)
func disable_effect(effect_name: String, transition_time: float = 0.0) -> void:
	if effect_name not in _effects:
		return

	if effect_name not in _effect_stack:
		return

	var effect: PostProcessEffect = _effects[effect_name]

	if transition_time > 0.0:
		_start_transition(effect_name, 0.0, transition_time)
		# Actual removal happens when transition completes
	else:
		_remove_effect_from_compositor(effect_name)


func _remove_effect_from_compositor(effect_name: String) -> void:
	if effect_name not in _effects:
		return

	var effect: PostProcessEffect = _effects[effect_name]

	_effect_stack.erase(effect_name)
	effect.effect_enabled = false
	var effects := _compositor.compositor_effects
	effects.erase(effect)
	_compositor.compositor_effects = effects

	effect_disabled.emit(effect_name)
	stack_changed.emit(_effect_stack.duplicate())
	Log.info("shaders", "Disabled effect: %s" % effect_name)


## Toggle an effect on/off
func toggle_effect(effect_name: String, transition_time: float = 0.0) -> bool:
	if effect_name not in _effects:
		return false

	if effect_name in _effect_stack:
		disable_effect(effect_name, transition_time)
		return false
	else:
		enable_effect(effect_name, transition_time)
		return true


## Check if an effect is enabled
func is_effect_enabled(effect_name: String) -> bool:
	return effect_name in _effect_stack


## Get an effect by name
func get_effect(effect_name: String) -> PostProcessEffect:
	return _effects.get(effect_name)


## Get all loaded effect names
func get_loaded_effects() -> Array[String]:
	var names: Array[String] = []
	for name in _effects.keys():
		names.append(name)
	return names


## Get all enabled effect names (in render order)
func get_enabled_effects() -> Array[String]:
	return _effect_stack.duplicate()


## Get effects by category
func get_effects_by_category(category: String) -> Array[String]:
	var names: Array[String] = []
	for name in _effects:
		var effect: PostProcessEffect = _effects[name]
		if effect.category == category:
			names.append(name)
	return names


## Get all categories
func get_categories() -> Array[String]:
	var categories: Array[String] = []
	for name in _effects:
		var effect: PostProcessEffect = _effects[name]
		if effect.category not in categories:
			categories.append(effect.category)
	categories.sort()
	return categories


## Set an effect parameter
func set_effect_param(effect_name: String, param_name: String, value: Variant) -> void:
	if effect_name not in _effects:
		return

	var effect: PostProcessEffect = _effects[effect_name]
	effect.set_param(param_name, value)


## Get an effect parameter
func get_effect_param(effect_name: String, param_name: String) -> Variant:
	if effect_name not in _effects:
		return null

	var effect: PostProcessEffect = _effects[effect_name]
	return effect.get_param(param_name)


## Get all parameters for an effect
func get_effect_params(effect_name: String) -> Dictionary:
	if effect_name not in _effects:
		return {}

	var effect: PostProcessEffect = _effects[effect_name]
	return effect.get_all_params()


## Reset an effect's parameters to defaults
func reset_effect_params(effect_name: String) -> void:
	if effect_name not in _effects:
		return

	var effect: PostProcessEffect = _effects[effect_name]
	effect.reset_all_params()


## Get effect info for UI
func get_effect_info(effect_name: String) -> Dictionary:
	if effect_name not in _effects:
		return {}

	var effect: PostProcessEffect = _effects[effect_name]
	var info := effect.get_effect_info()
	info["enabled"] = effect_name in _effect_stack
	return info


## Save a preset
func save_preset(preset_name: String) -> void:
	var preset: Dictionary = {
		"enabled_effects": _effect_stack.duplicate(),
		"effect_params": {}
	}

	for effect_name in _effects:
		var effect: PostProcessEffect = _effects[effect_name]
		preset["effect_params"][effect_name] = effect.get_all_params()

	_presets[preset_name] = preset
	_current_preset = preset_name
	Log.info("shaders", "Saved preset: %s" % preset_name)


## Load a preset
func load_preset(preset_name: String) -> bool:
	if preset_name not in _presets:
		push_error("[ShaderManager] Preset not found: %s" % preset_name)
		return false

	var preset: Dictionary = _presets[preset_name]

	# Disable all effects first
	for effect_name in _effect_stack.duplicate():
		disable_effect(effect_name)

	# Load parameters
	for effect_name in preset.get("effect_params", {}):
		if effect_name in _effects:
			var effect: PostProcessEffect = _effects[effect_name]
			effect.set_all_params(preset["effect_params"][effect_name])

	# Enable effects in order
	for effect_name in preset.get("enabled_effects", []):
		enable_effect(effect_name)

	_current_preset = preset_name
	Log.info("shaders", "Loaded preset: %s" % preset_name)
	return true


## Get available preset names
func get_presets() -> Array[String]:
	var names: Array[String] = []
	for name in _presets.keys():
		names.append(name)
	return names


## Delete a preset
func delete_preset(preset_name: String) -> void:
	_presets.erase(preset_name)
	if _current_preset == preset_name:
		_current_preset = ""


## Save current configuration to file
func save_config() -> void:
	var config := ConfigFile.new()

	# Save enabled effects
	config.set_value("effects", "enabled", _effect_stack)

	# Save all effect parameters
	for effect_name in _effects:
		var effect: PostProcessEffect = _effects[effect_name]
		var params := effect.get_all_params()
		for param_name in params:
			config.set_value(effect_name, param_name, params[param_name])

	# Save presets
	for preset_name in _presets:
		config.set_value("presets", preset_name, _presets[preset_name])

	var err := config.save(CONFIG_PATH)
	if err != OK:
		push_error("[ShaderManager] Failed to save config: %d" % err)
	else:
		Log.info("shaders", "Config saved to %s" % CONFIG_PATH)


## Load configuration from file
func _load_config() -> void:
	var config := ConfigFile.new()
	var err := config.load(CONFIG_PATH)
	if err != OK:
		# No config file, use defaults
		return

	# Load presets first
	if config.has_section("presets"):
		for preset_name in config.get_section_keys("presets"):
			_presets[preset_name] = config.get_value("presets", preset_name)

	# Load effect parameters
	for effect_name in _effects:
		if config.has_section(effect_name):
			var effect: PostProcessEffect = _effects[effect_name]
			for param_name in config.get_section_keys(effect_name):
				var value = config.get_value(effect_name, param_name)
				effect.set_param(param_name, value)

	# Load and enable effects
	if config.has_section_key("effects", "enabled"):
		var enabled_effects: Array = config.get_value("effects", "enabled", [])
		for effect_name in enabled_effects:
			if effect_name in _effects:
				enable_effect(effect_name)

	Log.info("shaders", "Config loaded from %s" % CONFIG_PATH)


## Load built-in effects from the effects directory
func _load_built_in_effects() -> void:
	for path in _effect_paths:
		var dir := DirAccess.open(path)
		if dir == null:
			continue

		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".gd"):
				load_effect(path + file_name)
			file_name = dir.get_next()
		dir.list_dir_end()


## Transition support
var _active_transitions: Dictionary = {}

func _start_transition(effect_name: String, target_blend: float, duration: float) -> void:
	var effect: PostProcessEffect = _effects[effect_name]
	_active_transitions[effect_name] = {
		"start_blend": effect.blend_factor,
		"target_blend": target_blend,
		"duration": duration,
		"elapsed": 0.0
	}


## Store a shared texture RID for inter-effect data passing
func set_shared_texture(texture_name: String, rid: RID) -> void:
	_shared_textures[texture_name] = rid


## Retrieve a shared texture RID (returns invalid RID if not found)
func get_shared_texture(texture_name: String) -> RID:
	return _shared_textures.get(texture_name, RID())


## Remove a shared texture entry
func clear_shared_texture(texture_name: String) -> void:
	_shared_textures.erase(texture_name)


## Remove all shared texture entries
func clear_all_shared_textures() -> void:
	_shared_textures.clear()


func _process(delta: float) -> void:
	# Update weather caches on main thread for render-thread-safe access
	for effect_name in ["sky_transmittance", "volumetric_fog", "godrays", "light_glow"]:
		var effect: PostProcessEffect = _effects.get(effect_name)
		if effect and effect.has_method("update_weather_cache"):
			effect.update_weather_cache()

	# Process transitions
	var completed: Array[String] = []

	for effect_name in _active_transitions:
		var trans: Dictionary = _active_transitions[effect_name]
		trans["elapsed"] += delta

		var t := clampf(trans["elapsed"] / trans["duration"], 0.0, 1.0)
		# Smooth step for nice easing
		t = t * t * (3.0 - 2.0 * t)

		var effect: PostProcessEffect = _effects[effect_name]
		effect.blend_factor = lerpf(trans["start_blend"], trans["target_blend"], t)

		if t >= 1.0:
			completed.append(effect_name)
			# If transitioning to 0, remove from compositor
			if trans["target_blend"] == 0.0:
				_remove_effect_from_compositor(effect_name)

	for effect_name in completed:
		_active_transitions.erase(effect_name)


func _on_effect_param_changed(param_name: String, value: Variant, effect_name: String) -> void:
	effect_param_changed.emit(effect_name, param_name, value)
