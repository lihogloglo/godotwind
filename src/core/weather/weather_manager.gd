## Weather Manager — Weather state machine and region tracking
##
## Autoload singleton. Owns the weather state machine, per-frame interpolated
## WeatherResult, and region tracking. Owns the single game clock — SkyManager
## reads time via update(game_hour), it does not advance time itself.
##
## Weather transitions follow Morrowind's model:
##   - Each region has probability weights for 10 weather types
##   - Weather changes roll every WEATHER_UPDATE_HOURS game hours
##   - Transitions blend smoothly using per-type transition_delta
class_name WeatherManagerClass
extends Node


#region Signals

## Emitted every frame with the interpolated weather result
signal weather_updated(result: WeatherTypes.WeatherResult)

## Emitted when a weather transition begins
signal weather_changed(from_type: int, to_type: int)

## Emitted when the player enters a new region
signal region_changed(region_id: String)

## Emitted every frame with the current game hour
signal game_hour_changed(hour: float)

#endregion


#region Configuration

## Whether the weather system is enabled
var enabled: bool = true

## Whether automatic weather changes are enabled
var auto_weather: bool = true

#endregion


#region Clock

## Game clock hour (0.0 - 24.0)
var _hour: float = 8.0
var _day: int = 1
var _time_scale: float = 30.0
var _paused: bool = false

## Current game hour (0.0 - 24.0)
var game_hour: float:
	get: return _hour
	set(value): set_game_hour(value)

## Current time scale (game-seconds per real-second)
var time_scale: float:
	get: return _time_scale
	set(value): set_time_scale(value)

## Whether time is paused
var time_paused: bool:
	get: return _paused
	set(value): _paused = value

#endregion


#region Weather State

## Current weather type
var _current_weather: int = WeatherTypes.Type.CLEAR

## Next weather type (target of transition)
var _next_weather: int = WeatherTypes.Type.CLEAR

## Transition progress: 1.0 = just started, 0.0 = complete
var _transition_factor: float = 0.0

## Whether we're currently transitioning between weather types
var _transitioning: bool = false

## Game hours remaining until next weather roll
var _hours_until_change: float = WeatherData.WEATHER_UPDATE_HOURS

## Cached weather parameters for all 10 types
var _all_params: Array = []

## Current frame's interpolated result
var _weather_result: WeatherTypes.WeatherResult = WeatherTypes.WeatherResult.new()

## Thunder flash state (decays per frame)
var _thunder_flash: float = 0.0

## RNG for weather rolls and thunder
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

## Previous frame's game hour (for detecting hour changes)
var _prev_hour: float = 8.0

#endregion


#region Region Tracking

## Current region ID (cached, updated on cell change)
var _current_region_id: String = ""

## Last known camera cell (to detect changes)
var _last_camera_cell: Vector2i = Vector2i(999999, 999999)

#endregion


func _ready() -> void:
	_all_params = WeatherData.get_all_weather_params()
	_rng.randomize()
	_hours_until_change = WeatherData.WEATHER_UPDATE_HOURS * (0.5 + _rng.randf() * 0.5)
	Log.info("weather", "WeatherManager initialized — starting at hour %.1f, weather: %s" % [game_hour, WeatherTypes.type_name(_current_weather)])


func _process(delta: float) -> void:
	if not enabled:
		return

	_advance_clock(delta)
	_update_region()

	if auto_weather:
		_advance_transition(delta)
		_check_weather_change(delta)

	_update_thunder(delta)
	_compute_result()

	weather_updated.emit(_weather_result)


#region Clock

func _advance_clock(delta: float) -> void:
	if _paused:
		return

	_hour += delta * _time_scale / 3600.0
	if _hour >= 24.0:
		_hour -= 24.0
		_day += 1

	game_hour_changed.emit(_hour)

#endregion


#region Weather State Machine

func _advance_transition(delta: float) -> void:
	if not _transitioning:
		return

	var params: WeatherTypes.WeatherParams = _all_params[_next_weather]
	_transition_factor -= params.transition_delta * delta

	if _transition_factor <= 0.0:
		_transition_factor = 0.0
		_transitioning = false
		_current_weather = _next_weather
		Log.info("weather", "Weather transition complete: %s" % WeatherTypes.type_name(_current_weather))


func _check_weather_change(delta: float) -> void:
	if _transitioning:
		return

	var delta_hours: float = delta * time_scale / 3600.0
	_hours_until_change -= delta_hours

	if _hours_until_change <= 0.0:
		_hours_until_change = WeatherData.WEATHER_UPDATE_HOURS
		_roll_new_weather()


func _roll_new_weather() -> void:
	if _current_region_id == "":
		return

	var region: RegionRecord = ESMManager.get_region(_current_region_id)
	if region == null:
		return

	var probs: Array[int] = WeatherData.get_region_probabilities(region)
	var total: int = 0
	for p: int in probs:
		total += p

	if total <= 0:
		return

	var roll: int = _rng.randi_range(0, total - 1)
	var cumulative: int = 0
	var new_weather: int = WeatherTypes.Type.CLEAR

	for i: int in probs.size():
		cumulative += probs[i]
		if roll < cumulative:
			new_weather = i
			break

	if new_weather != _current_weather:
		_begin_transition(new_weather)


func _begin_transition(to_type: int) -> void:
	_next_weather = to_type
	_transition_factor = 1.0
	_transitioning = true
	Log.info("weather", "Weather transitioning: %s -> %s (region: %s)" % [
		WeatherTypes.type_name(_current_weather), WeatherTypes.type_name(_next_weather), _current_region_id])
	weather_changed.emit(_current_weather, _next_weather)

#endregion


#region Thunder

func _update_thunder(delta: float) -> void:
	if _thunder_flash > 0.0:
		var params: WeatherTypes.WeatherParams = _all_params[_current_weather]
		_thunder_flash = maxf(0.0, _thunder_flash - params.flash_decrement * delta)

	var active_params: WeatherTypes.WeatherParams
	if _transitioning:
		active_params = _all_params[_next_weather]
		if _transition_factor > active_params.thunder_threshold:
			return
	else:
		active_params = _all_params[_current_weather]

	if active_params.thunder_frequency > 0.0:
		if _rng.randf() < active_params.thunder_frequency * delta:
			_thunder_flash = 1.0

#endregion


#region Region Tracking

func _update_region() -> void:
	var manager: NativeStreamingManager = NativeStreamingManager.instance
	if manager == null:
		return

	var cell: Vector2i = manager.get_camera_cell()
	_check_cell_region(cell)


func _check_cell_region(cell: Vector2i) -> void:
	if cell == _last_camera_cell:
		return

	_last_camera_cell = cell

	var cell_record: CellRecord = ESMManager.get_exterior_cell(cell.x, cell.y)
	if cell_record == null:
		return

	var new_region: String = cell_record.region_id
	if new_region != "" and new_region != _current_region_id:
		_current_region_id = new_region
		Log.info("weather", "Entered region: %s" % _current_region_id)
		region_changed.emit(_current_region_id)

#endregion


#region Result Computation

func _compute_result() -> void:
	var params_a: WeatherTypes.WeatherParams = _all_params[_current_weather]
	var params_b: WeatherTypes.WeatherParams
	var blend: float

	if _transitioning:
		params_b = _all_params[_next_weather]
		blend = 1.0 - _transition_factor
	else:
		params_b = params_a
		blend = 0.0

	_weather_result = WeatherInterpolator.interpolate_weather(params_a, params_b, blend, game_hour)
	_weather_result.game_hour = game_hour
	_weather_result.current_type = _current_weather
	_weather_result.next_type = _next_weather
	_weather_result.thunder_flash = _thunder_flash

#endregion


#region Public API

## Get the current interpolated weather result
func get_weather_result() -> WeatherTypes.WeatherResult:
	return _weather_result


## Get current weather type
func get_current_weather() -> int:
	return _current_weather


## Get current region ID
func get_current_region() -> String:
	return _current_region_id


## Is a weather transition in progress?
func is_transitioning() -> bool:
	return _transitioning


## Set weather immediately (no transition)
func set_weather(type: int) -> void:
	if type < 0 or type >= WeatherTypes.Type.COUNT:
		Log.warn("weather", "Invalid weather type: %d" % type)
		return
	_current_weather = type
	_next_weather = type
	_transitioning = false
	_transition_factor = 0.0
	Log.info("weather", "Weather set to: %s" % WeatherTypes.type_name(type))


## Begin transition to a new weather type
func transition_to(type: int) -> void:
	if type < 0 or type >= WeatherTypes.Type.COUNT:
		Log.warn("weather", "Invalid weather type: %d" % type)
		return
	if type == _current_weather and not _transitioning:
		return
	_begin_transition(type)


## Set game hour directly (0-24)
func set_game_hour(hour: float) -> void:
	_hour = fmod(absf(hour), 24.0)
	Log.info("weather", "Game hour set to: %.1f" % _hour)


## Set time scale (game-seconds per real-second)
func set_time_scale(scale: float) -> void:
	_time_scale = maxf(0.0, scale)
	Log.info("weather", "Time scale set to: %.1f" % _time_scale)


## Get a summary string for debug/console display
func get_status_string() -> String:
	var status: String = "Weather: %s" % WeatherTypes.type_name(_current_weather)
	if _transitioning:
		status += " -> %s (%.0f%%)" % [WeatherTypes.type_name(_next_weather), (1.0 - _transition_factor) * 100.0]
	status += " | Hour: %.1f | Region: %s" % [game_hour, _current_region_id if _current_region_id != "" else "none"]
	status += " | Next change in: %.1f hrs" % _hours_until_change
	return status

#endregion
