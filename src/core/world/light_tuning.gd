## LightTuning — runtime-tunable lighting knobs, single source of truth.
##
## Static vars so the light systems (reference_instantiator, distant_light_manager)
## and the Lighting UI tab share ONE set of values without a new autoload. The
## Lighting tab writes these live via set_param(); the light systems read them:
##   - Aggregate town-glow + distant-real ENERGY: read live every 0.5 s tick →
##     instant feedback.
##   - Real light RANGE (radius_multiplier) + aggregate range: applied at light
##     creation / page rebuild, so DistantLightManager.refresh_tunables() frees +
##     recreates them on change.
##   - NEAR (0-60 m) lights: read at cell spawn, so they pick up new values as
##     cells restream while flying around a town (not instant for a light you're
##     standing under — the aerial-tuning view is fully covered by the live layers).
##
## Accessed via `const LightTuning := preload(...)` in each consumer (NOT a global
## class_name — a freshly-added class_name isn't reliably in Godot's global class
## cache when the game launches outside the editor).
extends RefCounted

## Multiplier on EVERY real light's RANGE (near + distant). A "light bounds
## multiplier" — bigger pools overlap into a warm town wash.
static var radius_multiplier: float = 2.5
## Energy scale on NEAR (0-60 m) lights (base 0.8 non-fire / 1.2 fire).
static var near_energy_multiplier: float = 1.6
## Energy scale on distant real lights (55-350 m).
static var distant_energy_multiplier: float = 1.6
## Aggregate town-glow (250 m-1.2 km) base brightness — the "warm city from afar".
static var aggregate_energy_base: float = 1.2
## Distance at which the aggregate glow fully takes over from individual lights.
static var aggregate_near_full_m: float = 400.0
## Aggregate proxy range = a town's light spread + this margin.
static var aggregate_range_margin_m: float = 60.0


## String-keyed setter for the UI sliders (mirrors the ground-fog param pattern).
static func set_param(param: String, value: float) -> void:
	match param:
		"radius_multiplier": radius_multiplier = value
		"near_energy_multiplier": near_energy_multiplier = value
		"distant_energy_multiplier": distant_energy_multiplier = value
		"aggregate_energy_base": aggregate_energy_base = value
		"aggregate_near_full_m": aggregate_near_full_m = value
		"aggregate_range_margin_m": aggregate_range_margin_m = value
		_: Log.warn("streaming", "LightTuning: unknown param '%s'" % param)
