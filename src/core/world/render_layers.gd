class_name RenderLayers
extends RefCounted

const EXTERIOR_WORLD: int = 0x3
const INTERIOR_WORLD: int = 0xC
const COMBINED_WORLD: int = EXTERIOR_WORLD | INTERIOR_WORLD

const WATER_SURFACE_LAYER_NUMBER: int = 20
const WATER_SURFACE: int = 1 << (WATER_SURFACE_LAYER_NUMBER - 1)


static func replace_world_layers(current_mask: int, world_mask: int) -> int:
	return (current_mask & ~COMBINED_WORLD) | (world_mask & COMBINED_WORLD)


static func with_water_surface(current_mask: int) -> int:
	return current_mask | WATER_SURFACE


static func has_exterior_world(mask: int) -> bool:
	return (mask & EXTERIOR_WORLD) == EXTERIOR_WORLD


static func has_interior_world(mask: int) -> bool:
	return (mask & INTERIOR_WORLD) == INTERIOR_WORLD


static func has_water_surface(mask: int) -> bool:
	return (mask & WATER_SURFACE) != 0
