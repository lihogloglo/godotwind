## NIF Feature Audit Tool
##
## Scans all NIF files in Morrowind BSA archives and counts:
## - Texture slot usage (base, dark, detail, gloss, glow, bump, decal)
## - Apply modes (REPLACE, DECAL, MODULATE, HILIGHT, HILIGHT2)
## - Animation controller types
## - Environment map (NiTextureEffect) usage
## - Specular/stencil/zbuffer property usage
##
## Run as scene: res://src/tools/nif_audit.tscn
## Results printed to console and saved to docs/NIF_AUDIT_RESULTS.md
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node

## Use NIFDefs directly — can't const-alias class_name in GDScript

var _reader := NIFReader.new()

# Counters
var total_nifs: int = 0
var parse_errors: int = 0

# Texture slot counts (how many NIFs use each slot)
var tex_base: int = 0
var tex_dark: int = 0
var tex_detail: int = 0
var tex_gloss: int = 0
var tex_glow: int = 0
var tex_bump: int = 0
var tex_decal: int = 0

# Apply mode counts
var am_replace: int = 0
var am_decal: int = 0
var am_modulate: int = 0
var am_hilight: int = 0
var am_hilight2: int = 0

# Controller type counts
var ctrl_keyframe: int = 0
var ctrl_vis: int = 0
var ctrl_uv: int = 0
var ctrl_alpha: int = 0
var ctrl_material_color: int = 0
var ctrl_flip: int = 0
var ctrl_morph: int = 0
var ctrl_path: int = 0
var ctrl_roll: int = 0
var ctrl_lookat: int = 0
## NiLightColorController not in our defs — count via record type string
var ctrl_light_color: int = 0
var ctrl_particle: int = 0

# Property counts
var prop_specular: int = 0
var prop_specular_enabled: int = 0
var prop_stencil: int = 0
var prop_stencil_ops: int = 0  # Actual stencil test, not just draw_mode
var prop_zbuffer: int = 0
var prop_zbuffer_nondefault: int = 0
var prop_wireframe: int = 0
var prop_fog: int = 0

# Effect counts
var env_maps: int = 0
var env_sphere_map: int = 0
var env_cube_map: int = 0

# NIF files with each feature (for examples)
var example_glow: Array[String] = []
var example_bump: Array[String] = []
var example_dark: Array[String] = []
var example_detail: Array[String] = []
var example_decal: Array[String] = []
var example_env: Array[String] = []
var example_hilight: Array[String] = []
var example_morph: Array[String] = []


func _ready() -> void:
	Log.info("tools", "=== NIF Feature Audit Starting ===")
	# Run audit on next frame so autoloads are fully initialized
	call_deferred("_run_audit")


func _run_audit() -> void:
	# Initialize BSA archives
	var data_path := SettingsManager.get_data_path()
	if data_path.is_empty():
		Log.error("tools", "No Morrowind data path configured! Set morrowind/data_path in settings.")
		get_tree().quit(1)
		return

	var bsa_count := BSAManager.load_archives_from_directory(data_path)
	Log.info("tools", "Loaded %d BSA archives from: %s" % [bsa_count, data_path])

	if bsa_count == 0:
		Log.error("tools", "No BSA archives found!")
		get_tree().quit(1)
		return

	var start_time := Time.get_ticks_msec()

	# Get all NIF files from BSA
	var nif_files := BSAManager.get_files_by_extension("nif")
	Log.info("tools", "Found %d NIF files in BSA archives" % nif_files.size())

	for i in range(nif_files.size()):
		var file_info: Dictionary = nif_files[i]
		var path: String = file_info["path"]

		if i % 500 == 0:
			Log.info("tools", "Auditing NIF %d / %d ..." % [i, nif_files.size()])

		_audit_nif(path)

	var elapsed := Time.get_ticks_msec() - start_time
	_print_results(elapsed)
	_save_results(elapsed)

	Log.info("tools", "=== NIF Feature Audit Complete (%.1fs) ===" % (elapsed / 1000.0))
	get_tree().quit()


func _audit_nif(path: String) -> void:
	var data := BSAManager.extract_file(path)
	if data.is_empty():
		return

	total_nifs += 1

	if _reader.load_buffer(data, path) != OK:
		parse_errors += 1
		return

	var records = _reader.records
	if records.is_empty():
		parse_errors += 1
		return

	# Track per-NIF features (avoid double-counting)
	var has_glow := false
	var has_bump := false
	var has_dark := false
	var has_detail := false
	var has_decal := false
	var has_env := false
	var has_hilight := false

	for record in records:
		# Texture slots and apply modes
		if record is NIFDefs.NiTexturingProperty:
			var tex_prop := record as NIFDefs.NiTexturingProperty

			# Apply mode
			match tex_prop.apply_mode:
				NIFDefs.ApplyMode.REPLACE: am_replace += 1
				NIFDefs.ApplyMode.DECAL: am_decal += 1
				NIFDefs.ApplyMode.MODULATE: am_modulate += 1
				NIFDefs.ApplyMode.HILIGHT:
					am_hilight += 1
					has_hilight = true
				NIFDefs.ApplyMode.HILIGHT2: am_hilight2 += 1

			# Texture slots
			for j in range(tex_prop.textures.size()):
				var tex_desc: NIFDefs.TextureDesc = tex_prop.textures[j]
				if not tex_desc.has_texture:
					continue
				match j:
					0: tex_base += 1
					1:
						tex_dark += 1
						has_dark = true
					2:
						tex_detail += 1
						has_detail = true
					3: tex_gloss += 1
					4:
						tex_glow += 1
						has_glow = true
					5:
						tex_bump += 1
						has_bump = true
					6:
						tex_decal += 1
						has_decal = true

		# Controllers
		elif record is NIFDefs.NiKeyframeController:
			ctrl_keyframe += 1
		elif record is NIFDefs.NiVisController:
			ctrl_vis += 1
		elif record is NIFDefs.NiUVController:
			ctrl_uv += 1
		elif record is NIFDefs.NiAlphaController:
			ctrl_alpha += 1
		elif record is NIFDefs.NiMaterialColorController:
			ctrl_material_color += 1
		elif record is NIFDefs.NiFlipController:
			ctrl_flip += 1
		elif record is NIFDefs.NiGeomMorpherController:
			ctrl_morph += 1
			if example_morph.size() < 5:
				example_morph.append(path)
		elif record is NIFDefs.NiPathController:
			ctrl_path += 1
		elif record is NIFDefs.NiRollController:
			ctrl_roll += 1
		elif record is NIFDefs.NiLookAtController:
			ctrl_lookat += 1
		elif record is NIFDefs.NiParticleSystemController:
			ctrl_particle += 1

		# Properties
		elif record is NIFDefs.NiSpecularProperty:
			prop_specular += 1
			if (record as NIFDefs.NiSpecularProperty).enabled:
				prop_specular_enabled += 1
		elif record is NIFDefs.NiStencilProperty:
			prop_stencil += 1
			if (record as NIFDefs.NiStencilProperty).enabled:
				prop_stencil_ops += 1
		elif record is NIFDefs.NiZBufferProperty:
			prop_zbuffer += 1
			var zb := record as NIFDefs.NiZBufferProperty
			if not zb.test_enabled() or not zb.write_enabled():
				prop_zbuffer_nondefault += 1
		elif record is NIFDefs.NiWireframeProperty:
			prop_wireframe += 1
		elif record is NIFDefs.NiFogProperty:
			prop_fog += 1

		# Effects
		elif record is NIFDefs.NiTextureEffect:
			env_maps += 1
			has_env = true
			var eff := record as NIFDefs.NiTextureEffect
			if eff.coord_gen_type == 2:  # SphereMap
				env_sphere_map += 1
			elif eff.coord_gen_type >= 3:  # Cube map variants
				env_cube_map += 1

	# Collect examples (max 5 per feature)
	if has_glow and example_glow.size() < 5:
		example_glow.append(path)
	if has_bump and example_bump.size() < 5:
		example_bump.append(path)
	if has_dark and example_dark.size() < 5:
		example_dark.append(path)
	if has_detail and example_detail.size() < 5:
		example_detail.append(path)
	if has_decal and example_decal.size() < 5:
		example_decal.append(path)
	if has_env and example_env.size() < 5:
		example_env.append(path)
	if has_hilight and example_hilight.size() < 5:
		example_hilight.append(path)


func _print_results(elapsed_ms: int) -> void:
	Log.info("tools", "")
	Log.info("tools", "========== NIF FEATURE AUDIT RESULTS ==========")
	Log.info("tools", "Total NIFs: %d | Parse errors: %d | Time: %.1fs" % [total_nifs, parse_errors, elapsed_ms / 1000.0])
	Log.info("tools", "")
	Log.info("tools", "--- TEXTURE SLOTS ---")
	Log.info("tools", "  Base (0):   %d" % tex_base)
	Log.info("tools", "  Dark (1):   %d" % tex_dark)
	Log.info("tools", "  Detail (2): %d" % tex_detail)
	Log.info("tools", "  Gloss (3):  %d" % tex_gloss)
	Log.info("tools", "  Glow (4):   %d" % tex_glow)
	Log.info("tools", "  Bump (5):   %d" % tex_bump)
	Log.info("tools", "  Decal (6):  %d" % tex_decal)
	Log.info("tools", "")
	Log.info("tools", "--- APPLY MODES ---")
	Log.info("tools", "  REPLACE:  %d" % am_replace)
	Log.info("tools", "  DECAL:    %d" % am_decal)
	Log.info("tools", "  MODULATE: %d" % am_modulate)
	Log.info("tools", "  HILIGHT:  %d" % am_hilight)
	Log.info("tools", "  HILIGHT2: %d" % am_hilight2)
	Log.info("tools", "")
	Log.info("tools", "--- ANIMATION CONTROLLERS ---")
	Log.info("tools", "  NiKeyframeController:      %d" % ctrl_keyframe)
	Log.info("tools", "  NiVisController:           %d" % ctrl_vis)
	Log.info("tools", "  NiUVController:            %d" % ctrl_uv)
	Log.info("tools", "  NiAlphaController:         %d" % ctrl_alpha)
	Log.info("tools", "  NiMaterialColorController: %d" % ctrl_material_color)
	Log.info("tools", "  NiFlipController:          %d" % ctrl_flip)
	Log.info("tools", "  NiGeomMorpherController:   %d" % ctrl_morph)
	Log.info("tools", "  NiPathController:          %d" % ctrl_path)
	Log.info("tools", "  NiRollController:          %d" % ctrl_roll)
	Log.info("tools", "  NiLookAtController:        %d" % ctrl_lookat)
	Log.info("tools", "  NiParticleSystemController:%d" % ctrl_particle)
	Log.info("tools", "")
	Log.info("tools", "--- PROPERTIES ---")
	Log.info("tools", "  NiSpecularProperty:  %d (enabled: %d)" % [prop_specular, prop_specular_enabled])
	Log.info("tools", "  NiStencilProperty:   %d (stencil ops: %d)" % [prop_stencil, prop_stencil_ops])
	Log.info("tools", "  NiZBufferProperty:   %d (non-default: %d)" % [prop_zbuffer, prop_zbuffer_nondefault])
	Log.info("tools", "  NiWireframeProperty: %d" % prop_wireframe)
	Log.info("tools", "  NiFogProperty:       %d" % prop_fog)
	Log.info("tools", "")
	Log.info("tools", "--- EFFECTS ---")
	Log.info("tools", "  NiTextureEffect (env maps): %d (sphere: %d, cube: %d)" % [env_maps, env_sphere_map, env_cube_map])
	Log.info("tools", "")
	Log.info("tools", "--- ROUTING ESTIMATE ---")
	var multi_tex: int = tex_dark + tex_detail + tex_glow + tex_bump + tex_decal
	var pct_multi: float = (float(multi_tex) / float(maxi(tex_base, 1))) * 100.0
	Log.info("tools", "  Objects needing ShaderMaterial: ~%.1f%% (multi-texture slots used %d times vs %d base)" % [pct_multi, multi_tex, tex_base])
	Log.info("tools", "================================================")


func _save_results(elapsed_ms: int) -> void:
	var lines := PackedStringArray()
	lines.append("# NIF Feature Audit Results")
	lines.append("")
	lines.append("Generated: %s | Total NIFs: %d | Parse errors: %d | Time: %.1fs" % [
		Time.get_datetime_string_from_system(), total_nifs, parse_errors, elapsed_ms / 1000.0
	])
	lines.append("")
	lines.append("## Texture Slot Usage")
	lines.append("")
	lines.append("| Slot | Count | % of Base | Examples |")
	lines.append("|------|-------|-----------|----------|")
	lines.append("| Base (0) | %d | 100%% | — |" % tex_base)
	lines.append("| Dark (1) | %d | %.1f%% | %s |" % [tex_dark, _pct(tex_dark), ", ".join(example_dark)])
	lines.append("| Detail (2) | %d | %.1f%% | %s |" % [tex_detail, _pct(tex_detail), ", ".join(example_detail)])
	lines.append("| Gloss (3) | %d | %.1f%% | — |" % [tex_gloss, _pct(tex_gloss)])
	lines.append("| Glow (4) | %d | %.1f%% | %s |" % [tex_glow, _pct(tex_glow), ", ".join(example_glow)])
	lines.append("| Bump (5) | %d | %.1f%% | %s |" % [tex_bump, _pct(tex_bump), ", ".join(example_bump)])
	lines.append("| Decal (6) | %d | %.1f%% | %s |" % [tex_decal, _pct(tex_decal), ", ".join(example_decal)])
	lines.append("")
	lines.append("## Apply Modes")
	lines.append("")
	lines.append("| Mode | Count |")
	lines.append("|------|-------|")
	lines.append("| REPLACE (0) | %d |" % am_replace)
	lines.append("| DECAL (1) | %d |" % am_decal)
	lines.append("| MODULATE (2) | %d |" % am_modulate)
	lines.append("| HILIGHT (3) | %d |" % am_hilight)
	lines.append("| HILIGHT2 (4) | %d |" % am_hilight2)
	lines.append("")
	lines.append("HILIGHT examples: %s" % ", ".join(example_hilight))
	lines.append("")
	lines.append("## Animation Controllers")
	lines.append("")
	lines.append("| Controller | Count |")
	lines.append("|-----------|-------|")
	lines.append("| NiKeyframeController | %d |" % ctrl_keyframe)
	lines.append("| NiUVController | %d |" % ctrl_uv)
	lines.append("| NiAlphaController | %d |" % ctrl_alpha)
	lines.append("| NiMaterialColorController | %d |" % ctrl_material_color)
	lines.append("| NiFlipController | %d |" % ctrl_flip)
	lines.append("| NiVisController | %d |" % ctrl_vis)
	lines.append("| NiGeomMorpherController | %d |" % ctrl_morph)
	lines.append("| NiPathController | %d |" % ctrl_path)
	lines.append("| NiRollController | %d |" % ctrl_roll)
	lines.append("| NiLookAtController | %d |" % ctrl_lookat)
	lines.append("| NiParticleSystemController | %d |" % ctrl_particle)
	lines.append("")
	lines.append("Morph examples: %s" % ", ".join(example_morph))
	lines.append("")
	lines.append("## Properties")
	lines.append("")
	lines.append("| Property | Count | Notes |")
	lines.append("|----------|-------|-------|")
	lines.append("| NiSpecularProperty | %d | enabled: %d |" % [prop_specular, prop_specular_enabled])
	lines.append("| NiStencilProperty | %d | stencil ops: %d |" % [prop_stencil, prop_stencil_ops])
	lines.append("| NiZBufferProperty | %d | non-default: %d |" % [prop_zbuffer, prop_zbuffer_nondefault])
	lines.append("| NiWireframeProperty | %d | |" % prop_wireframe)
	lines.append("| NiFogProperty | %d | |" % prop_fog)
	lines.append("")
	lines.append("## Environment Maps")
	lines.append("")
	lines.append("| Type | Count |")
	lines.append("|------|-------|")
	lines.append("| Total NiTextureEffect | %d |" % env_maps)
	lines.append("| Sphere map | %d |" % env_sphere_map)
	lines.append("| Cube map | %d |" % env_cube_map)
	lines.append("")
	lines.append("Env map examples: %s" % ", ".join(example_env))
	lines.append("")
	lines.append("## Routing Decision")
	lines.append("")
	var multi_tex: int = tex_dark + tex_detail + tex_glow + tex_bump + tex_decal
	var pct_multi: float = (float(multi_tex) / float(maxi(tex_base, 1))) * 100.0
	lines.append("Multi-texture slot usage: %d instances across %d base textures (%.1f%%)" % [multi_tex, tex_base, pct_multi])
	lines.append("")
	if pct_multi > 50.0:
		lines.append("**Recommendation:** All-ShaderMaterial approach (>50% of objects need multi-texture)")
	else:
		lines.append("**Recommendation:** Hybrid SM3D + ShaderMaterial (%.1f%% need multi-texture)" % pct_multi)

	var file := FileAccess.open("res://docs/NIF_AUDIT_RESULTS.md", FileAccess.WRITE)
	if file:
		file.store_string("\n".join(lines))
		file.close()
		Log.info("tools", "Results saved to docs/NIF_AUDIT_RESULTS.md")
	else:
		Log.error("tools", "Failed to save audit results")


func _pct(count: int) -> float:
	if tex_base == 0:
		return 0.0
	return (float(count) / float(tex_base)) * 100.0
