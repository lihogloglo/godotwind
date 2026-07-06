## InteriorGICache - path + metadata conventions for prebaked interior VoxelGI.
##
## Why VoxelGI and not LightmapGI: LightmapGI.bake() is not exposed to
## scripting, not even in editor builds (godot-proposals#8656, verified
## 2026-07-06), so batch-baking ~1000 MW interiors with lightmaps is impossible
## in stock Godot. VoxelGI.bake() IS scriptable, its data saves to a plain
## Resource, and — unlike a lightmap — the baked voxel field is re-lit every
## frame from live lights, so flickering torches actually bounce.
##
## Shared by the offline baker (src/tools/prebaking/interior_gi_bake_runner.gd)
## and the runtime loader (interior_pocket_manager._add_interior_gi) so the two
## sides can never disagree on file naming or placement metadata.
class_name InteriorGICache
extends RefCounted

const SUBDIR := "interior_gi"

## Resource metadata keys stored on the baked VoxelGIData. The VoxelGI node's
## size/position must match the bake exactly; these carry that placement
## (cell-local space) from baker to runtime.
const META_SIZE := "voxelgi_size"
const META_CENTER := "voxelgi_center"


## [param settings] SettingsManager autoload (passed in — static context).
static func gi_dir(settings: Object) -> String:
	return str(settings.call("get_cache_base_path")).path_join(SUBDIR)


static func file_for_cell(dir: String, cell_name: String) -> String:
	return dir.path_join(sanitize_cell_name(cell_name) + ".res")


## MW interior names contain spaces, commas, apostrophes ("Balmora, Caius
## Cosades' House") — collapse to [a-z0-9_] for a filesystem-safe stem.
static func sanitize_cell_name(cell_name: String) -> String:
	var out := ""
	for i: int in cell_name.length():
		var c := cell_name.unicode_at(i)
		var is_digit := c >= 48 and c <= 57
		var is_lower := c >= 97 and c <= 122
		var is_upper := c >= 65 and c <= 90
		if is_digit or is_lower:
			out += char(c)
		elif is_upper:
			out += char(c + 32)
		else:
			out += "_"
	return out
