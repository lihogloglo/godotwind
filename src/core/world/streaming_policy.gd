## StreamingPolicy — Single source of truth for MID-tier filtering and LOD generation
##
## Consolidates two filters:
## - `is_mid_worthy()` — runtime: decides if object renders at 150-500m. Post-S.1
##   (near_tier_refactor.md 2026-04-19), runtime callers are gone; kept for the
##   prebake path + future S.7 MID re-enable where the per-cell tier FSM reads it.
## - `should_generate_lods()` (used by nif_converter.gd) — prebake: decides if
##   LODs are generated.
##
## Usage:
##   StreamingPolicy.is_mid_worthy("static", "x\\ex_hlaalu_b_01.nif")
##   StreamingPolicy.should_generate_lods("x\\ex_hlaalu_b_01.nif")
class_name StreamingPolicy
extends RefCounted


## Check if a model is visually significant enough for MID-tier rendering (150-500m).
## Objects that fail this check are deferred to NEAR range only.
##
## Parameters:
##   type_name: ESM record type ("static", "door", "container", "weapon", etc.)
##   model_path: NIF model path (e.g., "x\\ex_hlaalu_b_01.nif")
static func is_mid_worthy(type_name: String, model_path: String) -> bool:
	# Level 1: Record type fast-reject — small items never visible at 150m+
	if type_name in ["weapon", "armor", "clothing", "book", "potion",
			"ingredient", "misc", "apparatus", "lockpick", "probe",
			"repair", "leveled_item", "body_part"]:
		return false

	# Level 2: Doors are always MID-worthy (entrance markers)
	if type_name == "door":
		return true

	# Level 3: Model path significance check
	return _is_significant_model(model_path)


## Check if a model should have LODs generated during prebaking.
## This is the union of MID-worthy models + any additional categories worth LOD-ing.
##
## Parameters:
##   model_path: NIF model path (e.g., "x\\ex_hlaalu_b_01.nif")
static func should_generate_lods(model_path: String) -> bool:
	# All significant models get LODs (covers MID-worthy path-based checks)
	if _is_significant_model(model_path):
		return true

	# Additional LOD-worthy categories NOT in MID filter:
	# Doors don't pass _is_significant_model but are MID-worthy and benefit from LODs
	var lower := model_path.to_lower()
	if "door" in lower:
		return true

	return false


## Core model significance check — shared between is_mid_worthy and should_generate_lods.
## A model is "significant" if it's large enough to be visible at 150m+.
static func _is_significant_model(model_path: String) -> bool:
	var lower := model_path.to_lower()

	# Architecture (exterior and interior pieces)
	if "ex_" in lower or "in_" in lower:
		return true

	# Trees, large flora, and mushrooms — ALL tree/mushroom variants
	if "flora_tree" in lower or "flora_ashtree" in lower or \
			"flora_emp_tree" in lower or "flora_bc_" in lower or \
			"flora_t_mushroom" in lower or "flora_mushroom" in lower or \
			"flora_plant" in lower:
		return true

	# Terrain features (rocks, cliffs, boulders, arches — skip small rocks)
	if "terrain_" in lower:
		return "_small" not in lower

	# Large structural objects
	if "bridge" in lower or "ship" in lower or "boat" in lower or \
			"platform" in lower or "dock_" in lower:
		return true

	# Containers: barrels and crates visible at distance
	if "barrel" in lower or "crate" in lower or "contain_" in lower:
		return true

	# Dwemer ruins and Daedric architecture (large structural)
	if "dwrv_" in lower or "dae_" in lower:
		return true

	# Furniture (larger pieces only — skip small items)
	if "furn_" in lower:
		if "de_p" in lower or "misc_" in lower:
			return false
		return true

	return false
