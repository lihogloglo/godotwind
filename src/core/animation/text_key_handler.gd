## TextKeyHandler - Handles Morrowind animation text key events
##
## Morrowind animations contain text markers (NiTextKeyExtraData) that signal
## important events during animation playback:
## - "sound: <sound_id>" - Play a sound effect
## - "soundgen: <type>" - Play generated sound (footstep based on surface)
## - "hit" - Attack connects (deal damage)
## - "start" / "stop" - Animation boundaries
## - "loop start" / "loop stop" - Loop section markers
##
## Based on OpenMW's animation.cpp TextKeyListener implementation
class_name TextKeyHandler
extends RefCounted

# Signals for game systems to connect to
signal sound_triggered(sound_id: String, position: Vector3)
signal soundgen_triggered(sound_type: String, position: Vector3)
signal hit_triggered(position: Vector3)
signal attack_start()
signal attack_stop()
signal loop_start(animation_name: String, time: float)
signal loop_stop(animation_name: String, time: float)
signal custom_key(key_name: String, value: String, time: float)

# Text key types (matches OpenMW conventions)
enum KeyType {
	UNKNOWN,
	SOUND,
	SOUNDGEN,
	HIT,
	START,
	STOP,
	LOOP_START,
	LOOP_STOP,
	EQUIP_START,
	EQUIP_STOP,
	UNEQUIP_START,
	UNEQUIP_STOP,
	CHOP_HIT,      # Chop attack hit
	SLASH_HIT,     # Slash attack hit
	THRUST_HIT,    # Thrust attack hit
}

# Sound generation types (for footsteps, etc.)
enum SoundGenType {
	LEFT_FOOT,
	RIGHT_FOOT,
	SWIM_LEFT,
	SWIM_RIGHT,
	MOAN,
	ROAR,
	SCREAM,
	LAND,
}

# Current animation state
var _current_animation: String = ""
var _animation_player: AnimationPlayer = null
var _character_node: Node3D = null

# Parsed text keys: animation_name -> Array[{time: float, key: String, type: KeyType}]
var _text_keys: Dictionary = {}

# Active markers for tracking
var _last_processed_time: float = 0.0
var _is_processing: bool = false

# Debug mode
var debug_mode: bool = false


## Initialize with animation player
func setup(animation_player: AnimationPlayer, character_node: Node3D = null) -> void:
	_animation_player = animation_player
	_character_node = character_node

	if _animation_player:
		# Connect to animation signals
		if not _animation_player.animation_started.is_connected(_on_animation_started):
			_animation_player.animation_started.connect(_on_animation_started)
		if not _animation_player.animation_finished.is_connected(_on_animation_finished):
			_animation_player.animation_finished.connect(_on_animation_finished)


## Parse text keys from NIF animation data and store them
## text_keys: Array of {time: float, name: String}
func register_text_keys(animation_name: String, text_keys: Array) -> void:
	var parsed: Array = []

	for key: Dictionary in text_keys:
		var time: float = key.get("time", 0.0)
		var name: String = key.get("name", "")

		if name.is_empty():
			continue

		var parsed_key := _parse_text_key(name)
		parsed_key["time"] = time
		parsed_key["raw"] = name
		parsed.append(parsed_key)

		if debug_mode:
			print("TextKeyHandler: Registered key '%s' at %.3fs for '%s'" % [
				name, time, animation_name
			])

	# Sort by time
	parsed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["time"] < b["time"]
	)

	_text_keys[animation_name] = parsed


## Parse a single text key string into components
func _parse_text_key(key_text: String) -> Dictionary:
	var result := {
		"type": KeyType.UNKNOWN,
		"key": key_text,
		"value": "",
	}

	var lower := key_text.to_lower().strip_edges()

	# Check for "key: value" format
	var colon_pos := key_text.find(":")
	if colon_pos > 0:
		var key_part := key_text.substr(0, colon_pos).strip_edges().to_lower()
		var value_part := key_text.substr(colon_pos + 1).strip_edges()

		result["key"] = key_part
		result["value"] = value_part

		# Identify key type
		match key_part:
			"sound":
				result["type"] = KeyType.SOUND
			"soundgen":
				result["type"] = KeyType.SOUNDGEN
			_:
				# Check for animation name patterns like "idle: start"
				if value_part.to_lower() == "start":
					result["type"] = KeyType.START
				elif value_part.to_lower() == "stop":
					result["type"] = KeyType.STOP
				elif value_part.to_lower() == "loop start":
					result["type"] = KeyType.LOOP_START
				elif value_part.to_lower() == "loop stop":
					result["type"] = KeyType.LOOP_STOP
	else:
		# Single word keys
		match lower:
			"hit":
				result["type"] = KeyType.HIT
			"chop hit":
				result["type"] = KeyType.CHOP_HIT
			"slash hit":
				result["type"] = KeyType.SLASH_HIT
			"thrust hit":
				result["type"] = KeyType.THRUST_HIT
			"start":
				result["type"] = KeyType.START
			"stop":
				result["type"] = KeyType.STOP
			"loop start":
				result["type"] = KeyType.LOOP_START
			"loop stop":
				result["type"] = KeyType.LOOP_STOP
			"equip start":
				result["type"] = KeyType.EQUIP_START
			"equip stop":
				result["type"] = KeyType.EQUIP_STOP
			"unequip start":
				result["type"] = KeyType.UNEQUIP_START
			"unequip stop":
				result["type"] = KeyType.UNEQUIP_STOP

	return result


## Process text keys for current animation time
## Call this each frame during animation playback
func process_animation_time(animation_name: String, current_time: float) -> void:
	if not _text_keys.has(animation_name):
		return

	var keys: Array = _text_keys[animation_name]
	var position := _get_character_position()

	for key: Dictionary in keys:
		var key_time: float = key["time"]

		# Check if this key should trigger (crossed threshold since last frame)
		if key_time > _last_processed_time and key_time <= current_time:
			_trigger_key(key, position)

	_last_processed_time = current_time


## Trigger a text key event
func _trigger_key(key: Dictionary, position: Vector3) -> void:
	var key_type: int = key["type"]
	var value: String = key.get("value", "")
	var raw: String = key.get("raw", "")
	var time: float = key.get("time", 0.0)

	if debug_mode:
		print("TextKeyHandler: Triggering '%s' at %.3fs (type=%d)" % [raw, time, key_type])

	match key_type:
		KeyType.SOUND:
			sound_triggered.emit(value, position)

		KeyType.SOUNDGEN:
			soundgen_triggered.emit(value, position)

		KeyType.HIT, KeyType.CHOP_HIT, KeyType.SLASH_HIT, KeyType.THRUST_HIT:
			hit_triggered.emit(position)

		KeyType.START:
			attack_start.emit()

		KeyType.STOP:
			attack_stop.emit()

		KeyType.LOOP_START:
			loop_start.emit(_current_animation, time)

		KeyType.LOOP_STOP:
			loop_stop.emit(_current_animation, time)

		_:
			# Emit generic custom key for unknown types
			custom_key.emit(key["key"], value, time)


## Get character position for sound emission
func _get_character_position() -> Vector3:
	if _character_node:
		return _character_node.global_position
	return Vector3.ZERO


## Animation started callback
func _on_animation_started(anim_name: StringName) -> void:
	_current_animation = str(anim_name)
	_last_processed_time = 0.0
	_is_processing = true

	if debug_mode:
		print("TextKeyHandler: Animation started '%s'" % anim_name)


## Animation finished callback
func _on_animation_finished(anim_name: StringName) -> void:
	_is_processing = false

	if debug_mode:
		print("TextKeyHandler: Animation finished '%s'" % anim_name)


## Get loop points for an animation (returns {start: float, end: float} or null)
func get_loop_points(animation_name: String) -> Variant:
	if not _text_keys.has(animation_name):
		return null

	var keys: Array = _text_keys[animation_name]
	var loop_start_time: float = -1.0
	var loop_stop_time: float = -1.0

	for key: Dictionary in keys:
		var key_type: int = key["type"]
		if key_type == KeyType.LOOP_START:
			loop_start_time = key["time"]
		elif key_type == KeyType.LOOP_STOP:
			loop_stop_time = key["time"]

	if loop_start_time >= 0.0 and loop_stop_time > loop_start_time:
		return {"start": loop_start_time, "end": loop_stop_time}

	return null


## Get hit timing for an attack animation
func get_hit_time(animation_name: String) -> float:
	if not _text_keys.has(animation_name):
		return -1.0

	var keys: Array = _text_keys[animation_name]

	for key: Dictionary in keys:
		var key_type: int = key["type"]
		if key_type == KeyType.HIT or key_type == KeyType.CHOP_HIT or \
		   key_type == KeyType.SLASH_HIT or key_type == KeyType.THRUST_HIT:
			return key["time"]

	return -1.0


## Check if an animation has text keys
func has_text_keys(animation_name: String) -> bool:
	return _text_keys.has(animation_name) and not _text_keys[animation_name].is_empty()


## Get all text keys for an animation
func get_text_keys(animation_name: String) -> Array:
	return _text_keys.get(animation_name, [])


## Clear all registered text keys
func clear() -> void:
	_text_keys.clear()
	_current_animation = ""
	_last_processed_time = 0.0
	_is_processing = false


## Parse sound gen type from string
static func parse_soundgen_type(type_str: String) -> int:
	match type_str.to_lower().strip_edges():
		"left", "left foot":
			return SoundGenType.LEFT_FOOT
		"right", "right foot":
			return SoundGenType.RIGHT_FOOT
		"swim left":
			return SoundGenType.SWIM_LEFT
		"swim right":
			return SoundGenType.SWIM_RIGHT
		"moan":
			return SoundGenType.MOAN
		"roar":
			return SoundGenType.ROAR
		"scream":
			return SoundGenType.SCREAM
		"land":
			return SoundGenType.LAND
		_:
			return -1
