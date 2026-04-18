# LOD Pipeline Over-Engineering — Session Wrap-Up 2026-04-08

## TL;DR

Session started as a "fix Vivec canton missing-faces bug in LODs" task. Midway through, the user (correctly) called out that the fix was over-engineering. Stopped work, self-evaluated against the new CLAUDE.md "Simplicity Over Over-Engineering" principle, reverted the session's GDExt diffs, and discovered during downstream scoping that the entire hand-rolled LOD scaffolding is a **17-file bespoke replacement for Godot 4.6's built-in `ImporterMesh.generate_lods()`**. Final decision deferred to the next session. This doc captures the state so the next agent inherits the reasoning, not just the code.

---

## Original session goal

User report (#prebaking msg 53, 2026-04-08 18:04): Vivec cantons have LODs with **missing faces** — entire wall sides disappearing when seen from afar. Pre-existing issue, predates the session's NIF parser refactor. User asked whether the prebaking pipeline was doing things the right way, and (later) whether we could also fix the 64 NIF parse failures to reach 100% model import.

The session kicked off by identifying that:
1. A recent commit (`8bf17e4`) had added `NiZBufferProperty` / `NiSpecularProperty` / apply-mode / glow-slot parsing to `src/native/NativeNIFReader.cs` + `NativeNIFConverter.cs`, so **the C# needed rebuilding** before the next run.
2. The prebaked `.res` cache at `C:/Users/metzo/Documents/Godotwind/cache/models/` was stale relative to those material-parsing changes.
3. The missing-faces bug was a **separate, older issue** in the LOD simplification step, not caused by the recent NIF parser changes.

---

## What was attempted (and why it was wrong)

### Attempt 1 — Layer 1: tighter error budget + vertex cache opt

**File:** `src/core/nif/nif_converter.gd::_add_visibility_range_lods`

**Change:** inside the per-LOD-level simplification loop, passed `target_error = 0.001` (was `0.01`) to `MeshOptimizer.simplify_arrays()` and added a post-pass `simplifier.optimize_vertex_cache()` call.

**Reasoning:** meshoptimizer's `target_error` is relative to the mesh bbox extent. On a ~50 m Vivec canton that meant the simplifier had ~50 cm of deformation budget — enough to collapse entire wall panels before reaching the triangle target. Tightening to 0.001 caps deformation at ~5 cm.

**Result:** user re-baked, visually verified, **still saw missing faces**. The error-budget tightening wasn't enough on its own.

### Attempt 2 — Layer 1+2: welding + `meshopt_SimplifyLockBorder`

**Files:**
- `addons/meshoptimizer/src/meshoptimizer_gdext.h` — signature changes, new `weld_mesh_arrays` method
- `addons/meshoptimizer/src/meshoptimizer_gdext.cpp` — new `weld_mesh_arrays` implementation (~200 lines), `options` param plumbing on `simplify` / `simplify_with_attributes` / `simplify_mesh_arrays`, internal `_apply_remap_f32` helper wrapping `meshopt_remapVertexBuffer` for each attribute stream (VERTEX, NORMAL, TANGENT, COLOR, TEX_UV, TEX_UV2, BONES, WEIGHTS), safe bailout on ARRAY_CUSTOM when format is unknown
- `addons/meshoptimizer/mesh_optimizer.gd` — `LOCK_BORDER` / `SPARSE` / `ERROR_ABSOLUTE` constants, `weld_mesh_arrays` wrapper passthrough, `simplify_arrays` extended with `options` + `uv_weight` params, once-per-process banner guard, deprecated old broken `weld_vertices` wrapper
- `src/core/nif/nif_converter.gd` — class-scope `LOD_UV_WEIGHT` const + escalation-ladder comment, pre-weld loop via `weld_mesh_arrays` before the LOD reduction loop, `simplify_arrays` call updated to pass `MeshOptimizer.LOCK_BORDER` + `LOD_UV_WEIGHT`

**Reasoning:**
1. **Weld before simplify** — `_convert_merged()` glues multiple `NiTriShape` patches into one `ArrayMesh` surface without welding shared corner vertices, so neighbouring wall pieces look like disjoint islands with fake silhouette borders. Welding collapses position-duplicate vertices so meshopt treats the merged building as a continuous manifold.
2. **`meshopt_SimplifyLockBorder` flag** — per the meshoptimizer.h comment on `meshopt_simplify` options: *"Useful for simplifying portions of the larger mesh."* Prevents collapse of genuine silhouette edges when the QEM error budget would otherwise allow it.
3. **Proper attribute-aware weld in C++** — the GDExt's original `weld_vertices` only remapped `ARRAY_VERTEX` + `ARRAY_INDEX`, leaving `ARRAY_NORMAL` / `ARRAY_TEX_UV` / etc. at their pre-weld length (a latent bug — calling it on attributed meshes would produce length-mismatched arrays and crash `ArrayMesh.add_surface_from_arrays`). New `weld_mesh_arrays` remaps all streams in C++ using `meshopt_remapVertexBuffer` per stream.

**Build:** clean SCons build, 0 warnings 0 errors. DLL rebuilt at `addons/meshoptimizer/bin/libmeshoptimizer.windows.template_debug.x86_64.dll`.

**Result:** user targeted-rebaked 217 files matching `ex_hlaalu_canton_*` / `ex_velothi_*` / `ex_vivec_*` / `in_vivec_*` / `ex_t_*` / `ex_dwrv_*` / `ex_ashl_*` / `ex_ald_*`. Launched the main scene for visual verification. **Called it off** before completing the visual pass, asked whether the whole approach was over-engineered, pointed at the new CLAUDE.md "Simplicity Over Over-Engineering" section.

---

## Key discovery — the actual canonical pattern

Godot 4.6 ships `ImporterMesh.generate_lods(normal_merge_angle, normal_split_angle, bone_transform_array)`. Verified:

- **API exposed in `godot-cpp`** at `godot-cpp/gen/include/godot_cpp/classes/importer_mesh.hpp:75`
- **Used by every Godot built-in importer** — glTF (`scene_importer_mesh.cpp`), FBX (via Assimp wrapper), OBJ
- **Internally calls `meshoptimizer` with the right flags** — does the weld + `meshopt_simplifyWithAttributes(LockBorder)` + attribute remap + vertex cache optimization
- **Output format** — an `ArrayMesh` with `surface_lod_indices` embedded per surface; the renderer picks which LOD to draw per-frame by screen-space coverage + `lod_bias` at `RenderingServer` level

**The entire 376-line session diff (C++ + GDScript + nif_converter rewiring) was a hand-rolled reimplementation of that one engine method call.** This is the exact pattern CLAUDE.md's new "Simplicity Over Over-Engineering" principle describes — three attempts patching a bespoke replacement for an engine feature, when the right move was always "delete the bespoke replacement, call the engine API."

---

## The wider discovery — bespoke scaffolding goes much deeper than this session

During the scoping grep for the rewrite, discovered that the sibling-LOD-name convention (`_LOD1` / `_LOD2` / `_LOD3`) is referenced **127 times across 17 files** in `src/`. The pattern is a load-bearing contract between:

**Prebake side:**
- `nif_converter.gd::_add_visibility_range_lods` — creates sibling `MeshInstance3D` nodes named `<parent>_LOD1/2/3`
- `model_prebaker.gd::_count_lod_nodes` + `_collect_lod_nodes_for_removal` + `_verify_no_lod_nodes_remain` — prebaker tooling that inspects the sibling structure
- `targeted_rebake.gd::_cache_has_lods` — targeted rebake detects missing LODs by walking the cached scene for sibling nodes

**Cache format:**
- `.res` files literally contain `MergedMesh_0_LOD1`, `_LOD2`, `_LOD3` child nodes as part of the PackedScene

**Runtime streaming / rendering:**
- `cell_manager.gd::_find_first_mesh_instance` — walks prototype scene tree, **skips** nodes ending in `_LOD*` to find the "main" mesh; LOD nodes are reserved for MID-tier extraction
- `static_object_renderer.gd::RenderableData` — has `lod_meshes: Dictionary = {}` mapping `lod_level → Array[LodMeshEntry]`, creates per-LOD `RenderingServer` instances with manual `visibility_range_*` cascades per LOD level, allocates one RS RID per LOD per object (`lod_rids: Array[RID]` + `lod0_count` marker)
- `native_streaming_manager.gd` — the per-instance LOD visibility_range pipeline
- `native_impostor_renderer.gd` — FAR tier impostor handoff consumes the LOD structure
- `reference_instantiator.gd` — instantiation path
- `lod_configurator.gd` — ~250 lines dedicated to setting `visibility_range_begin/end/begin_margin/end_margin` on the sibling LOD nodes per the NEAR / MID / FAR tier scheme
- `mesh_visibility_utils.gd::is_lod_node_name` — helper
- `distance_utils.gd` — constants `FADE_MARGIN_NEAR_LOD1`, `FADE_MARGIN_LOD1_LOD2`, `FADE_MARGIN_LOD2_LOD3`, `FADE_MARGIN_LOD3_FAR` named after the manual tier handoffs
- `streaming_config.gd` — configuration

**Debug + test tooling:**
- `debug_overlay.gd`, `lod_debug_commands.gd`, `lod_overlap_test.gd`, `lod_transition_test.gd`

**The entire NEAR / MID / FAR 3-tier rendering scheme is a bespoke implementation of Godot's built-in mesh-LOD system.** Godot's `RenderingServer` already:
- Picks LOD level per-frame from screen-space size + `lod_bias` per `MeshInstance3D`
- Handles the cascade of LOD levels embedded in a single `ArrayMesh` via `surface_lod_indices`
- Uses one RS instance per object, not N-RS-instances-per-N-LOD-levels

The hand-rolled version has three extra moving parts: the sibling node structure, the per-LOD RS instance creation in `static_object_renderer`, and the per-LOD visibility_range cascade in `lod_configurator`. All of these could in principle collapse into "one `MeshInstance3D` + one `ArrayMesh` with `surface_lod_indices` set + `lod_bias` tweak."

**Scope estimate for a full refactor:** ~700 lines deleted from the 17 files, roughly 1000–2000 lines of churn total when accounting for downstream cleanup. Multi-session project, not a one-shot fix.

---

## The three options left open at session close

### Option B-narrow / D — Surgical fix

Use `ImporterMesh.generate_lods()` **only inside `_add_visibility_range_lods`** for the simplification math. Keep the sibling-LOD-naming convention and everything downstream untouched.

- **Scope:** ~30 lines in `nif_converter.gd` only
- **Bug fix:** YES — the engine handles the weld + `LockBorder` + attribute remap + UV preservation correctly, so Vivec cantons get correct LOD geometry
- **Architectural improvement:** zero — the 250-line `_add_visibility_range_lods` + 250-line `lod_configurator.gd` + 17-file consumer web all stays
- **Honest framing:** "we used the engine for the math, kept the bespoke pipeline because the streaming layer depends on it"
- **Next-session cost:** small, a few hours including rebake + verify

### Option B-wide — Canonical rewrite

Replace the entire sibling-LOD scheme with Godot's native `ArrayMesh.surface_lod_indices` + automatic `RenderingServer` LOD selection.

- **Scope:** 17 files touched, ~1000–2000 lines of churn (mostly delete)
- **Major simplification:** the per-LOD RID lifecycle, the manual visibility_range cascades, the sibling-node construction, the `_find_first_mesh_instance` LOD skip, the `lod_configurator.gd` module, the FADE_MARGIN constants — most of it collapses
- **Risk:** very high blast radius. The 3-tier NEAR / MID / FAR streaming scheme is load-bearing for the game's performance target. Breaking the MID-tier MultiMesh extraction or the FAR-tier impostor handoff would cascade into streaming regressions
- **Test scope:** full streaming pipeline verification, both visual and performance
- **Next-session cost:** multi-session project

### Option E — Pause and think

Leave the bug unfixed, document the architectural debt, rotate to the NIF parser work (the 30 real parser failures in `docs/audit/NIF_UNSUPPORTED.md`) which is independent of the LOD issue.

---

## Recommendation for next session

**Start with B-narrow.** It lands the visual fix today with minimal risk. It does not pay off the architectural debt, but it unblocks the user's ability to visually verify Vivec without staring at missing wall panels. The wider B-wide refactor should be its own dedicated session with explicit planning in `docs/audit/` first.

**Concrete next steps for B-narrow:**

1. Read `addons/meshoptimizer/` — confirm the GDExt is back at HEAD (already done this session, see "Working tree state" below)
2. In `nif_converter.gd::_add_visibility_range_lods`, replace the per-LOD `simplifier.simplify_arrays(...)` loop with a single `ImporterMesh` pass:
   ```gdscript
   var importer := ImporterMesh.new()
   importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, surf_arrays, [], {}, surf_mat)
   importer.generate_lods(60.0, 25.0, [])  # gltf importer defaults
   var lod_mesh_full := importer.get_mesh()
   # Extract each LOD level via surface_lod_indices to build the sibling MeshInstance3D
   for lod_idx in range(lod_levels):
       var lod_indices_raw = lod_mesh_full.surface_get_lod_indices(0, lod_idx)
       # ... construct sibling LOD mesh wrapping the base vertices with these indices
   ```
3. Keep the sibling-LOD-naming convention (`<parent>_LOD1/2/3`) so nothing downstream breaks
4. Test on ONE canton with `debug_lod = true`, dump per-LOD tri counts, confirm the cascade looks sane
5. Targeted rebake (same 217 files used last time — `ex_hlaalu_canton_*`, `ex_velothi_*`, `ex_vivec_*`, `in_vivec_*`, `ex_t_*`, `ex_dwrv_*`, `ex_ashl_*`, `ex_ald_*`)
6. User visual verify — **static camera** (sit on a rooftop, scroll-zoom back slowly through 150 / 250 / 375 / 500 m boundaries) to avoid the streaming-side shutdown crash race that fires on rapid fly-cam traversal
7. If clean → close the LOD ticket, rotate to the NIF parser fix
8. If still missing faces → tune `(60.0, 25.0)` angle params or `lod_bias`, rebake again; do not escalate to a bespoke re-patch

**Caveat on B-narrow:** ImporterMesh may not perfectly match the exact LOD count / reduction ratios the bespoke pipeline produces. The current `lod_reduction_ratios = [0.50, 0.25, 0.10]` maps to the manual 3-level cascade; ImporterMesh produces its own cascade (typically 4 levels) with engine-default ratios. The sibling-LOD extraction step needs to either (a) map ImporterMesh LOD levels 1/2/3 to our `_LOD1/2/3` slots, or (b) accept that the LOD count may change and adjust the downstream consumers to read N LODs instead of exactly 3. **Resolve this mapping question in the first 15 minutes of the next session** — it determines whether B-narrow is truly ~30 lines or closer to ~100.

---

## Working tree state at session close

### Reverted cleanly (back at HEAD):

- `addons/meshoptimizer/src/meshoptimizer_gdext.h`
- `addons/meshoptimizer/src/meshoptimizer_gdext.cpp`
- `addons/meshoptimizer/mesh_optimizer.gd`
- `src/core/nif/nif_converter.gd`

### Retained session changes (unrelated to LOD pipeline, legitimate improvements):

- `src/tools/prebaking/model_prebaker.gd` — 3 lines of `Log.warn("prebaking", "FAIL (<reason>): <path>")` on the three previously-silent failure branches (`NIF not in BSA`, `conversion failed`, `no meshes to save`). This is the instrumentation that let us categorise the 64 NIF failures in `docs/audit/NIF_UNSUPPORTED.md` — keep it permanently.

### Build artefacts modified but functionally at HEAD:

- `addons/meshoptimizer/bin/libmeshoptimizer.windows.template_debug.x86_64.dll` — rebuilt twice this session (once with Layer 1+2 changes, once after revert). Current on-disk binary matches HEAD source bytewise-functionally but has a different build hash, so git reports it as `M`. Either `git checkout HEAD --` it or leave it — next clean SCons build will regenerate it either way.
- `addons/meshoptimizer/.sconsign.dblite` — SCons build state cache, `M` for the same reason.

### New files created this session (untracked):

- `docs/audit/NIF_UNSUPPORTED.md` — **keep, high value.** Full catalog of the 64 NIF bake failures, categorised into 30 real parser bugs (`FAIL (conversion)` — single shared `0x53694E00` 4-byte under-read in `nif_reader.gd::_read_record`), 28 particle-only "no meshes" NIFs (magic effects, vfx patterns — not actually broken, just shouldn't be in the prebake candidate list), and 6 orphaned ESM references to NIFs missing from the BSA (Akula effect placeholders, `magic_target_L/S` variants).
- `src/tools/nif_debug_dump.gd` + `.tscn` + `.uid` — standalone diagnostic scene for parser investigation. Reads a specific NIF from BSA, enables `debug_mode = true` on `NIFReader`, prints the full record trace + hex dump of the first 64 bytes. Used to identify the under-reading handler when the parser fix starts. **Keep for the parser session.**
- `docs/audit/LOD_OVER_ENGINEERING.md` — this document.

### Pre-existing user work in flight (NOT touched this session):

- `src/core/interaction/carry_controller.gd` + related `.uid` files
- `src/core/world/impostor_candidates.gd`
- `src/core/world/native_impostor_renderer.gd`
- `src/tools/prebaking/impostor_baker_v3.gd` (untracked)
- Various `tests/visual/test_carry_*` files
- `tests/unit/test_octahedral_encoding.gd`
- `tests/prebaking/` subdirectory
- `reports/report_19/`, `reports/report_20/`

All left as-is.

### Prebaked cache state:

`C:/Users/metzo/Documents/Godotwind/cache/models/` contains **4884 `.res` files** in a mixed state:
- **4667 files** baked with the original (buggy, missing-faces) pipeline from before this session
- **217 files** baked with the Layer 1+2 pipeline (weld + LockBorder + tighter error + uv_weight=1.0) — these cover `ex_hlaalu_canton_*` / `ex_velothi_*` / `ex_vivec_*` / `in_vivec_*` / `ex_t_*` / `ex_dwrv_*` / `ex_ashl_*` / `ex_ald_*`

The cache is NOT wiped. Next session should decide whether to:
- Wipe and re-bake fully once B-narrow lands — guarantees all files use the engine pipeline
- Leave the 217 mixed files in place as "free prior work" — fine if the Layer 1+2 pipeline produced acceptable geometry, but the visual verification never completed so we don't actually know

Safer default: wipe and re-bake once B-narrow compiles cleanly. Full bake takes ~10 minutes and eliminates the mixed-pipeline state.

---

## Related docs

- `docs/audit/NIF_UNSUPPORTED.md` — 64-failure parser catalog (session artefact, carry forward)
- `.claude/CLAUDE.md` — "Simplicity Over Over-Engineering" principle locked 2026-04-08, see the "carry-vibration saga" example which this session reproduces almost exactly
- `src/core/world/distance_utils.gd` — NEAR / MID / FAR tier constants, touched by the wider refactor if B-wide happens
- `src/core/world/streaming_policy.gd` — decides which models get LODs; stays unchanged regardless of B-narrow vs B-wide

---

## Open questions for next session

1. **B-narrow or B-wide?** — user's call. Recommendation in this doc is B-narrow.
2. **ImporterMesh LOD count vs our 3-level cascade** — the mapping question flagged in the B-narrow recommendation, resolve in the first 15 minutes.
3. **After LOD fix lands, the NIF parser fix** — 30 real failures sharing a `0x53694E00` 4-byte under-read. Best reproducer: the 10 `i\active_port_*.NIF` files (all abort at record index 4, identical authored template). Use `src/tools/nif_debug_dump.tscn` to dump the trace. See `docs/audit/NIF_UNSUPPORTED.md` for the full list and investigation notes.
4. **Should the particle-only NIF filter (`should_bake_as_mesh`) land in the same patch as the parser fix, or separately?** — 28 of the 64 failures are particle-only NIFs that shouldn't be routed through the mesh prebaker at all. Trivial to filter at `_collect_unique_models` time once we know the discriminator (either header peek or pattern match).
5. **The shutdown crash** — exit-139 / signal-11 during main scene quit, misidentified as a runtime crash early in the session. Confirmed by user to be a Godot mono + GDExtension teardown race firing during normal quit, not a runtime issue. Not blocking, but worth a separate investigation session since it corrupts exit codes and makes background-task automation harder to trust.

---

## Process notes for the next agent

- **Read CLAUDE.md "Simplicity Over Over-Engineering" BEFORE touching the LOD code.** That section was added in response to this exact saga. The carry-vibration example in that section is the canonical reference — this session is almost a line-by-line replay of it: inherited bespoke replacement, patched it twice, second patch "almost worked", stepped back, realised the engine ships the feature.
- **First reviewer question on any non-trivial fix in this codebase: "is this patching a bespoke replacement for an engine feature?"** If yes, step back and evaluate the delete+engine-API path before touching the bespoke code.
- **When the implementer frames a problem as "fix system X" and X is hand-rolled, the framing itself is a trap.** Reframe to "should we use the engine's equivalent of X?" before agreeing to the fix.
