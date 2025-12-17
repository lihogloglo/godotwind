## WaveCascadeParameters - Configuration for a single wave cascade
## Based on: https://github.com/2Retr0/GodotOceanWaves (MIT License)
class_name WaveCascadeParameters
extends Resource

signal scale_changed

## Distance the cascade's tile covers (in meters)
@export var tile_length := Vector2(50, 50):
	set(value):
		tile_length = value
		should_generate_spectrum = true
		scale_changed.emit()

## Displacement scale (reduce for more cascades)
@export_range(0, 2) var displacement_scale := 1.0:
	set(value):
		displacement_scale = value
		scale_changed.emit()

## Normal scale (reduce for more cascades)
@export_range(0, 2) var normal_scale := 1.0:
	set(value):
		normal_scale = value
		scale_changed.emit()

## Average wind speed above water (m/s). Higher = steeper, choppier waves
@export var wind_speed := 20.0:
	set(value):
		wind_speed = max(0.0001, value)
		should_generate_spectrum = true

## Wind direction in degrees
@export_range(-360, 360) var wind_direction := 0.0:
	set(value):
		wind_direction = value
		should_generate_spectrum = true

## Distance from shoreline (km). Higher = steeper but less choppy
@export var fetch_length := 550.0:
	set(value):
		fetch_length = max(0.0001, value)
		should_generate_spectrum = true

## How much waves clump in elongated, parallel manner
@export_range(0, 2) var swell := 0.8:
	set(value):
		swell = value
		should_generate_spectrum = true

## How much wind/swell affect wave direction
@export_range(0, 1) var spread := 0.2:
	set(value):
		spread = value
		should_generate_spectrum = true

## High frequency wave attenuation
@export_range(0, 1) var detail := 1.0:
	set(value):
		detail = value
		should_generate_spectrum = true

## How steep waves must be for foam
@export_range(0, 2) var whitecap := 0.5:
	set(value):
		whitecap = value
		should_generate_spectrum = true

## Foam amount
@export_range(0, 10) var foam_amount := 5.0:
	set(value):
		foam_amount = value
		should_generate_spectrum = true

# Internal state
var spectrum_seed := Vector2i.ZERO
var should_generate_spectrum := true
var time: float = 0.0
var foam_grow_rate: float = 0.0
var foam_decay_rate: float = 0.0
