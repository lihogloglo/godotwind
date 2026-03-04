## WaveCascadeParameters — Configuration for a single FFT wave cascade
## Each cascade covers a different tile length (scale) of ocean detail.
## Ported from GodotOceanWaves with Godotwind conventions.
class_name WaveCascadeParameters
extends Resource

signal scale_changed

## Distance the cascade's tile covers in meters
@export var tile_length := Vector2(50, 50):
	set(value):
		tile_length = value
		should_generate_spectrum = true
		scale_changed.emit()

## Displacement amplitude multiplier (reduce for many cascades)
@export_range(0, 2) var displacement_scale := 1.0:
	set(value):
		displacement_scale = value
		scale_changed.emit()

## Normal map strength multiplier
@export_range(0, 2) var normal_scale := 1.0:
	set(value):
		normal_scale = value
		scale_changed.emit()

## Average wind speed above water in m/s — higher = steeper, more chaotic
@export var wind_speed := 20.0:
	set(value):
		wind_speed = max(0.0001, value)
		should_generate_spectrum = true

## Wind direction in degrees
@export_range(-360, 360) var wind_direction := 0.0:
	set(value):
		wind_direction = value
		should_generate_spectrum = true

## Distance from shoreline in km — higher = steeper but less choppy
@export var fetch_length := 550.0:
	set(value):
		fetch_length = max(0.0001, value)
		should_generate_spectrum = true

## Elongation of waves along wind direction
@export_range(0, 2) var swell := 0.8:
	set(value):
		swell = value
		should_generate_spectrum = true

## Directional spreading of waves (0=uniform, 1=omnidirectional)
@export_range(0, 1) var spread := 0.2:
	set(value):
		spread = value
		should_generate_spectrum = true

## High-frequency wave attenuation (0=smooth, 1=full detail)
@export_range(0, 1) var detail := 1.0:
	set(value):
		detail = value
		should_generate_spectrum = true

## Steepness threshold before foam accumulates (lower = more foam)
@export_range(0, 2) var whitecap := 0.5:
	set(value):
		whitecap = value
		should_generate_spectrum = true

## Foam density (0=none, 10=maximum)
@export_range(0, 10) var foam_amount := 5.0:
	set(value):
		foam_amount = value
		should_generate_spectrum = true

# Runtime state (not exported)
var spectrum_seed := Vector2i.ZERO
var should_generate_spectrum := true
var time: float
var foam_grow_rate: float
var foam_decay_rate: float
