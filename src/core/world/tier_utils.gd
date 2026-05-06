## TierUtils - Shared tier utilities for the streaming system
##
## Canonical definitions for tier enum, tier naming, and fade calculations.
## All systems should use these utilities to avoid duplication.
##
## Usage:
##   var name := TierUtils.get_tier_name(tier)
##   var tier := TierUtils.get_tier_for_distance(distance)
##   var fade := TierUtils.calculate_boundary_fade(dist, 150.0, 50.0, true)
class_name TierUtils
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")

## Canonical tier enum - use this as reference for tier values
## Note: DistanceTierManager uses HORIZON/NONE for cell-level visibility,
## ObjectStreamer uses HIDDEN for object-level visibility. Both map to value 3+.
enum Tier {
	NEAR = 0,    # 0-150m: Full Node3D with physics
	MID = 1,     # 150-400m: cell-local static buckets
	HLOD = 2,    # optional merged chunk proxies
	FAR = 3,     # 400m-5km: impostors
	HIDDEN = 4   # Beyond FAR or not loaded
}

## Tier stat keys for array-based lookup (matches Tier enum order)
const TIER_STAT_KEYS := ["near_visible", "mid_visible", "hlod_visible", "far_visible", "hidden"]


## Get human-readable tier name
static func get_tier_name(tier: int) -> String:
	match tier:
		Tier.NEAR: return "NEAR"
		Tier.MID: return "MID"
		Tier.HLOD: return "HLOD"
		Tier.FAR: return "FAR"
		Tier.HIDDEN: return "HIDDEN"
		_: return "T%d" % tier


## Get tier for a given distance (uses DistanceUtils thresholds)
static func get_tier_for_distance(distance: float) -> int:
	if distance < DU.NEAR_END:
		return Tier.NEAR
	elif distance < DU.MID_END:
		return Tier.MID
	elif distance < DU.FAR_END:
		return Tier.FAR
	else:
		return Tier.HIDDEN


## Calculate fade amount at tier boundary
##
## Returns 0.0-1.0 where:
##   - entering=true: 0.0 = at boundary-margin, 1.0 = at boundary+margin (fading INTO higher tier)
##   - entering=false: 1.0 = at boundary-margin, 0.0 = at boundary+margin (fading OUT of lower tier)
##
## Example: NEAR->MID transition at 150m with 50m margin
##   At 100m: entering=true returns 0.0, entering=false returns 1.0
##   At 150m: both return 0.5
##   At 200m: entering=true returns 1.0, entering=false returns 0.0
static func calculate_boundary_fade(distance: float, boundary: float, margin: float, entering: bool) -> float:
	if entering:
		# Fading IN to higher-distance tier (e.g., NEAR->MID)
		return clampf((distance - (boundary - margin)) / (2.0 * margin), 0.0, 1.0)
	else:
		# Fading OUT of lower-distance tier (e.g., exiting NEAR)
		return clampf((boundary + margin - distance) / (2.0 * margin), 0.0, 1.0)
