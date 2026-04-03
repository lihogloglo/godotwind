## BuoyancyProbe3D — Lightweight wave sampling point for buoyancy.
## Place as children of a BuoyancyBody3D. Each probe samples wave height
## at its world position and contributes a buoyancy force to the parent body.
##
## For small objects (crates, barrels): 1-4 probes at corners.
## For boats/ships: 6-12 probes along the hull.
class_name BuoyancyProbe3D
extends Marker3D

## Multiplier for this probe's buoyancy force (default 1.0).
## Use < 1.0 for probes near the waterline, > 1.0 for deep hull probes.
@export var buoyancy_multiplier: float = 1.0

## Whether this probe is currently submerged.
var is_submerged: bool = false

## Depth below water surface (positive = submerged, negative = above).
var depth: float = 0.0
