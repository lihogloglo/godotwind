## LightAnimator — Flicker/pulse energy modulation for Morrowind lights
##
## Attach as child of a cell container node. Scans children for OmniLight3D
## with "mw_flags" metadata and animates their energy based on light flags.
##
## Animation types (from OpenMW LightController):
##   Flicker:     random brightness targets in [0.25, 1.0], speed 0.1
##   FlickerSlow: same range, speed 0.05
##   Pulse:       triangle wave between 0.25 and 1.0, speed 0.1
##   PulseSlow:   same wave, speed 0.05
##
## Runs at effective 15 FPS with temporal smoothing (matches OpenMW).
class_name LightAnimator
extends Node

# Morrowind light flag constants
const FLAG_FLICKER: int = 0x0008
const FLAG_FLICKER_SLOW: int = 0x0040
const FLAG_PULSE: int = 0x0080
const FLAG_PULSE_SLOW: int = 0x0100

# Animation state per light
class LightState:
	var light: OmniLight3D
	var base_energy: float
	var brightness: float = 1.0
	var phase: float = 1.0       # Target brightness
	var speed: float = 0.1
	var is_pulse: bool = false    # true = pulse (triangle wave), false = flicker (random)
	var phase_direction: bool = true  # For pulse: true = going up

# All animated lights
var _lights: Array[LightState] = []
var _tick_accumulator: float = 0.0
var _prev_ticks: float = 0.0


func _ready() -> void:
	# Defer scan to next frame so all children are added
	_scan_lights.call_deferred()


## Scan all descendant OmniLight3D nodes for animation flags
func _scan_lights() -> void:
	_lights.clear()
	_scan_node(get_parent())


func _scan_node(node: Node) -> void:
	if node is OmniLight3D:
		var omni: OmniLight3D = node as OmniLight3D
		var flags: int = omni.get_meta("mw_flags", 0)
		if flags == 0:
			return

		var state: LightState = null

		if flags & FLAG_FLICKER:
			state = LightState.new()
			state.speed = 0.1
			state.is_pulse = false
		elif flags & FLAG_FLICKER_SLOW:
			state = LightState.new()
			state.speed = 0.05
			state.is_pulse = false
		elif flags & FLAG_PULSE:
			state = LightState.new()
			state.speed = 0.1
			state.is_pulse = true
		elif flags & FLAG_PULSE_SLOW:
			state = LightState.new()
			state.speed = 0.05
			state.is_pulse = true

		if state:
			state.light = omni
			state.base_energy = omni.get_meta("base_energy", omni.light_energy)
			state.brightness = 1.0
			state.phase = randf_range(0.25, 1.0)  # Randomize start phase
			_lights.append(state)

	for child in node.get_children():
		_scan_node(child)


func _process(delta: float) -> void:
	if _lights.is_empty():
		return

	# Effective 15 FPS with temporal smoothing (matches OpenMW)
	var raw_ticks: float = delta * 15.0
	var smoothed_ticks: float = raw_ticks * 0.25 + _prev_ticks * 0.75
	_prev_ticks = smoothed_ticks
	_tick_accumulator += smoothed_ticks

	# Process at ~15 FPS intervals
	if _tick_accumulator < 1.0:
		return
	_tick_accumulator -= 1.0

	for state: LightState in _lights:
		if not is_instance_valid(state.light):
			continue

		# Move brightness toward phase target
		if state.brightness < state.phase:
			state.brightness = minf(state.brightness + state.speed, state.phase)
		elif state.brightness > state.phase:
			state.brightness = maxf(state.brightness - state.speed, state.phase)

		# Pick new target when reached
		if absf(state.brightness - state.phase) < 0.01:
			if state.is_pulse:
				# Triangle wave: alternate between 0.25 and 1.0
				state.phase = 1.0 if state.phase_direction else 0.25
				state.phase_direction = not state.phase_direction
			else:
				# Flicker: random target in [0.25, 1.0]
				state.phase = 0.25 + randf() * 0.75

		# Apply to light energy
		state.light.light_energy = state.base_energy * state.brightness
