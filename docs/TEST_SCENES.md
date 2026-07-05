# Visual Test Scenes Catalog

> Every scene under `tests/visual/`, what it demonstrates, how to drive it, and
> what data it needs. 56 scenes as of 2026-07-05. This doubles as the shot list
> for public posts (README, Godot forum/reddit, HN) — scenes tagged 🎬 are the
> photogenic ones worth a screenshot or recording.

## How to launch

- **From the editor:** open the `.tscn` and press F6 (Run Current Scene).
- **From the CLI:**
  ```
  Godot_v4.6-stable_mono_win64.exe --path . res://tests/visual/<scene>.tscn
  ```
- **C# must be built first** (`dotnet build Godotwind.sln`) — Godot does not
  auto-rebuild C# on scene launch.
- All interactive scenes use the unified `InputMap` actions from
  `project.godot` (AZERTY/QWERTY-safe). `ui_cancel` (Esc) releases the mouse.

## Data requirements legend

| Tag | Meaning |
|-----|---------|
| **None** | Runs on a fresh clone (engine + addons only) |
| **MW** | Needs a Morrowind installation configured in SettingsManager (ESM/BSA) |
| **Cache** | Needs prebaked caches (terrain / models / impostors / horizon maps) generated via the prebake tools |
| **Optional** | Loads MW/cache data if present, degrades gracefully without |

## Scene types

- 🎬 **Showcase** — photogenic, worth capturing for public posts
- 🔧 **Lab** — interactive testbed for tuning one system in isolation
- 🩺 **Diagnostic** — automated PASS/FAIL or data-gathering scene
- 💨 **Smoke** — auto-runs and quits; crash/regression guard

Suggested media location once captured: `docs/media/test_scenes/<scene_name>.png|mp4`.

---

## Sky & Atmosphere

### test_sky 🎬 🔧 — **None**
The GodotwindSky system standalone: no weather, no streaming, no ESM. Includes
a reflective sphere + ground plane to judge sky lighting contribution.
- **Controls:** T/Y time backward/forward · +/− turbidity · M multi-scatter · R realistic celestial mode · RMB look, WASD fly, scroll speed
- **Capture:** time-lapse recording sweeping T through a full day; sunset over the reflective sphere.

### test_weather 🎬 🔧 — **None**
Full weather stack standalone: SkyManager + SunshineClouds2 + weather-driven
atmosphere parameters, with a fog debug overlay showing fog sources and clock
status. Each subsystem can be toggled independently to isolate artifacts.
- **Controls:** 1–9, 0 weather presets (Clear → Blizzard) · T/Y time ±1h · +/− time scale · F depth fog · V volumetric fog · W weather system · K SkyManager · C clouds · P procedural sun · O ocean · RMB look, ZQSD move, Space/Shift up/down
- **Capture:** recording cycling weather presets 1→0; blizzard and thunderstorm stills.

### test_fog 🎬 🔧 — **Cache** (terrain)
Weather-driven fog on real Morrowind terrain: height fog pooling in valleys,
volumetric fog god rays, depth fog aerial perspective.
- **Controls:** 1–9, 0 weather presets · T/Y time · F depth fog · V volumetric fog · R god rays (compute) · G weather system · K SkyManager · ZQSD fly, RMB look, Space/Ctrl up/down, Shift fast
- **Capture:** dawn valley fog pooling between hills; god rays through morning mist.

### test_godrays_showcase 🎬 — **None**
Purpose-built godray demo — objects orbit in front of the sun so the rays are
always occluded by something moving.
- **Controls:** RMB + WASD/ZQSD fly · T/Y advance/rewind sun · R toggle godrays
- **Capture:** short recording of the orbiting occluders slicing the rays.

### test_clouds_lab 🔧 — **MW + Cache** (terrain textures)
Standalone SunshineClouds2 lab: isolates the cloud compositor from weather,
ocean, streaming, and SkyManager so cloud-resource values can be tuned
directly. Loads MW terrain + horizon maps for a realistic backdrop.
- **Controls:** RMB drag look · move_* fly · jump/crouch up/down · sprint fast · Esc release mouse · HUD parameter controls

### test_horizon_shadows ⚠ ZOMBIE — **Cache** (terrain)
Was: horizon-map terrain self-shadowing with a live sun-rotation control.
**The horizon-map system is parked** (`HorizonMapManager` keeps only the
wet-fallback shader plumbing; `set_enabled()`/`update_sun_direction()` are
no-op stubs) — the scene script-errors on a removed private field and can no
longer demonstrate anything. Verified broken at launch 2026-07-05. Delete or
park alongside the horizon-map revival.

### test_wet_map 🎬 🔧 — **Cache** (terrain + horizon maps)
Lagarde PBR wet surfaces + horizon self-shadowing (they share the
`terrain_horizon.gdshader` override) with interactive sliders.
- **Controls:** WASD move · RMB drag look · Space/Ctrl up/down · Esc mouse capture · sliders for wetness + sun parameters
- **Capture:** A/B still of dry vs rain-soaked terrain at the same camera pose.

---

## Ocean & Water

### test_ocean_lab 🎬 🔧 — **Optional** (terrain cache if present)
**The** combined interactive ocean testbed: FFT ocean visuals, shore behavior,
wetness, screen-space ocean optics (SSR, refraction, underwater compositor,
waterline), and CPU-vs-GPU buoyancy sync. Most ocean smokes below inherit this
scene. HUD exposes the full toggle set (mesh mode, surface shaders, underwater
features, debug modes, weather presets).
- **Controls:** fly camera (right-mouse look + move_* actions) · extensive HUD toggles
- **Capture:** hero shot of storm waves with spray; underwater half-submerged waterline shot; SSR reflections at sunset.

### test_ocean_setup — **None**
Minimal FFT ocean sanity scene: wave motion, shore-mask dampening, native SSR +
sky reflections, depth coloring, edge foam. Predecessor of the ocean lab; still
the fastest "is the ocean alive" check.

### test_ocean_shore 🔧 — **None**
Shore-specific behaviors: depth-buffer shore blending, FFT buoyancy sync
(floating cubes riding waves), foam distance fade, refraction at shore edges,
normal flattening at distance.
- **Controls:** WASD move · mouse look · Q/E up/down · 1–3 shore blend presets (1 m / 3 m / 10 m) · F fly to distant view

### test_buoyancy_debug 🔧 — **None**
Visualizes the CPU wave sampler (`WaterSystem.get_wave_height()`) against the
GPU FFT mesh: a 40×40 magenta marker grid should sit exactly on crests and
troughs. Minimal on purpose — ocean + fly camera + beach.
- **Controls:** B launch buoyant sphere from camera · V toggle debug grid · RMB + WASD/Space/Shift fly

### test_flowing_river 🎬 🔧 — **None**
Flowing river lab: straight and bend river segments with flow-driven current,
buoyant grabbable play balls, station presets and debug overlays via HUD
dropdowns, plus capture and freeze-time buttons.
- **Controls:** fly camera · HUD station/debug dropdowns · grab balls (interact)
- **Capture:** recording of balls drifting around the river bend.

### test_inland_water_lab 🔧 — **None**
Polygon/volume water for non-ocean bodies. Four stations: lake edge fade,
puddle shallows, pool ripples, slow inlet current, each with buoyancy props.
- **Controls:** fly camera · HUD station + debug-mode dropdowns

### test_water_interaction_ripples 🎬 🔧 — **None**
Standalone dynamic-ripple debug scene — shows the ripple atlas directly on
ocean/volume water. Includes grabbable props to make ripples with, and a GPU
cost budget check (2 ms limit).
- **Capture:** recording of dragging a prop through calm water leaving a ripple wake.

### test_morrowind_water_classification 🩺 🔧 — **MW**
GPU hydrology baker over real Morrowind terrain (Balmora region): classifies
water into ocean/river/lake, bakes flow speed + direction. Eight debug
overlays: classification, coverage, speed, direction, raw RGBA, wet mask,
ocean core, bank distance.
- **Controls:** fly camera · overlay cycling
- **Capture:** classification overlay over the Odai river — great "how it works" image for the HN post.

### test_godot_ssr_water_reference 🔧 — **None**
Vendored copy of the well-known Godot SSR water sample
(`tests/visual/godot_ssr_water/`) as a reference implementation to A/B against
our own water SSR. Useful when deciding whether an artifact is ours or
engine-inherent.

### test_reflections 🔧 — **None**
Water reflection matrix: engine SSR, ReflectionProbe fallback, omni lights,
emissive materials, distant-light billboards, and directional specular on the
ocean surface.
- **Controls:** WASD + mouse · 1 toggle SSR · 2 toggle ReflectionProbe · 3 toggle lights · 4 cycle time of day · Esc quit

---

## Streaming, LOD & Impostors

### test_hlod_benchmark 🩺 🔧 — **MW + Cache**
Full streaming pipeline on a 5×5 cell grid around Seyda Neen — no player,
no dialogue, no weather, just the LOD/HLOD/impostor tiers. Built for A/B
benchmarking HLOD on vs off; writes CSV + per-frame RS instance counts to
`user://benchmark_results/`.
- **Controls (InputMap):** move_* fly · mouse look · scroll speed · `hlod_toggle` A/B · `hlod_benchmark_toggle` CSV logging · `hlod_dump_stats` · `hlod_teleport_tier` jump to tier boundaries · Esc quit

### test_hlod_only 🩺 — **MW + Cache**
Drives ObjectPaging (runtime HLOD chunk merger) directly, without the NEAR/MID/
FAR scene representations — isolates chunk generation cost, publish cost, and
draw-call quality on the real ESM + model-cache path.

### test_impostor_v5 🎬 🔧 — **MW + Cache** (impostor atlas)
Octahedral impostor validation: tree and building impostors through the real
NativeImpostorRenderer, with the actual 3D models placed at the same positions
for direct overlap comparison — the impostor should align exactly with the mesh.
- **Controls:** WASD fly · mouse look · `impostor_sun_*` rotate sun · `impostor_toggle_models` show/hide real meshes · `impostor_debug_normals` · `impostor_bake_v6` batch-bake · Esc quit. Headless smoke mode: `-- --impostor-test-smoke`
- **Capture:** toggle recording real-mesh ↔ impostor at mid distance ("spot the difference").

### test_impostor_single_visualizer 🔧 — **MW**
Close-up, orbitable single-model impostor viewer through the production
renderer path — inspect origin, bounds, selected views, normals, and shadow
behavior on one model before any broad validation.
- **Controls:** orbit camera · `impostor_toggle_billboard` · `impostor_toggle_models` · `impostor_debug_normals` · model yaw keys

### test_impostor_stress 🎬 🩺 — **MW + Cache**
FAR-tier stress test: loads real ESM exterior refs for a 60-cell radius around
Seyda Neen and drives NativeImpostorRenderer directly — no terrain, MID, HLOD,
or CellManager.
- **Controls:** move_* fly · mouse drag look · wheel speed · `impostor_debug_normals` · `impostor_stress_toggle_bounds` page AABB wires · `impostor_stress_force_visible` · `impostor_stress_reload_area` · Esc quit
- **Capture:** wide aerial still of thousands of impostors to the horizon.

### test_distant_lights 🎬 🔧 — **MW**
Distant light billboard system at night from real ESM light records — much
faster to launch than the full world (no terrain, streaming, or models).
- **Controls:** WASD + mouse fly · T cycle night/day/dusk · +/− scan radius · F fire-only filter · Esc quit
- **Capture:** night aerial of settlement lights across the coast.

### test_lod_baseline 🩺 — **Cache**
LOD B-wide refactor baseline capture: loads a cached `.res` directly, walks the
prototype tree, measures per-LOD triangle counts/AABB/materials against seven
hypotheses (H1–H7) with PASS/FAIL markers, writes a report to
`user://lod_baselines/`, and spawns all LOD variants side-by-side for free-cam
inspection.

### test_lod_bwide_verify 🩺 — **Cache**
End-to-end B-wide pipeline verification: cached models with embedded LOD chains
registered through StaticObjectRenderer, camera moves on rails through the
distance tiers while logging RS primitive counts — verifies engine-driven LOD
selection actually reduces geometry with distance.

### test_lod_diagnostic 🔧 — **MW**
Three-way comparison of one model: raw NIF (no LODs) vs raw NIF with
`generate_lods` vs the cached `.res` — side-by-side spawn plus a full surface/
triangle/material/AABB report. Set `target_nif_path` in the inspector, F6.

### test_material_visual 🩺 — **Cache**
Isolates the RS-instance texture bug: same prototype rendered LEFT as a plain
MeshInstance3D and RIGHT as a raw RenderingServer instance via
StaticObjectRenderer. If LEFT is correct and RIGHT is wrong, the bug is in RS
instance creation. Model cache resolved via `SettingsManager.get_models_path()`.
- **Controls:** ←/→ switch model · ZQSD orbit

### test_mid_tier_diagnostic 🩺 — **MW + Cache**
Why do some areas have no MID-tier models? Runs 20 representative models
through the full pipeline (disk cache → prototype → LOD inspection → MID filter
→ batch pool) with color-coded floor planes: green = full pipeline, red =
MID-worthy but no LODs, orange = has LODs but filtered out, gray = correctly
rejected. F5 runs a full ESM audit to `user://mid_tier_audit.csv`.

---

## Terrain

### test_terrain_erosion_filter 🎬 🔧 — **MW + Cache**
Interactive erosion-filter shader lab on real Morrowind terrain — the
"terrain erosion shaders" experiment. Near-radius, fade-width and erosion-scale
parameters tuned live via HUD.
- **Controls:** move_* fly · jump/crouch vertical · sprint fast · RMB drag look · wheel speed · Esc mouse capture
- **Capture:** A/B still of raw vs eroded terrain silhouette; slider-sweep recording.

### test_terrain_alignment 🩺 — **MW + Cache**
Automated full-pipeline terrain audit: raw MW heights → heightmap → Terrain3D
query, import position correctness, object-Y vs terrain-height agreement, fresh
vs cached terrain. Logs PASS/FAIL per check; camera parked at Seyda Neen for
visual confirmation.

### test_terrain_baking 🩺 — **MW**
Automated terrain + horizon-map bake pipeline run — no manual clicking; logs
timing, region counts, and traps errors to pinpoint bake crashes.

### test_terrain_underground 🩺 💨 — **None**
Crash isolation: five automated phases moving the camera between Y=100 and
Y=−500 (the interior-pocket position) with Terrain3D visible/hidden, to prove
or acquit Terrain3D as the interior-transition segfault cause.

### test_terrain_api_probe 💨 — **None**
Console-only probe of every Terrain3D property/method the C# bindings expect —
run after a Terrain3D addon upgrade.

### test_terrain_vertex_spacing 💨 — **None**
Probes `vertex_spacing` and other newer Terrain3D APIs for crashes after DLL
swaps.

### extract_terrain_shader 🛠 — **None**
One-shot utility, not a test: extracts Terrain3D's actual runtime shader code
to `docs/audit/` for inspection.

---

## Interior / Exterior Transitions

### test_stencil_portal 🎬 🔧 — **None**
Pure stencil-buffer portal mechanics (Godot 4.6 BaseMaterial3D stencil API), no
Morrowind data: a wall with a doorframe opening, a stencil-write plane in the
opening, and colored cubes behind the wall that should only be visible through
the "window".
- **Controls:** WASD + mouse fly · SPACE toggle stencil on/off · RMB release mouse
- **Capture:** recording of walking past the doorframe — cubes appear only through the opening; SPACE toggle for the reveal.

### test_interior_transition 🎬 🔧 — **MW + Cache**
Seamless interior transitions, pocket mode: loads Seyda Neen exterior, registers
real doors with InteriorPocketManager, fly to any door and enter it.
- **Controls:** InputMap movement + mouse fly · E interact with door under crosshair · TAB cycle discovered doors + preload selected interior · Esc release mouse
- **Capture:** single-take recording: approach Arrille's Tradehouse, open door, walk in, walk out — no loading screen.

### test_classic_transition 🩺 — **MW + Cache**
Automated classic (teleport-style) transition: loads Seyda Neen, auto-enters
Arrille's Tradehouse, logs everything, auto-exits after 3 s. Optional manual
controls (WASD fly, E door, Esc quit).

### test_transition_crash_isolation 🩺 — **MW + Cache**
Two-phase proof of the transition crash root cause: transition WITH streaming
pause (should succeed) vs WITHOUT (streaming manager unloads exterior cells
mid-transition → use-after-free).

---

## Character, Interaction & Carry

### test_character_controller 🎬 🔧 — **MW + Cache**
Playable character controller sandbox with real animated Morrowind NPCs.
- **Controls:** WASD move · Shift sprint · Ctrl walk · Space jump · C crouch · mouse look · V 1st/3rd person · 1–5 spawn preset NPCs (Fargoth, Caius Cosades, Ranis Athrys, Arrille, Sugar-Lips Habasi) · F1 debug HUD · F2 bone comparison dump · Esc release mouse
- **Capture:** 3rd-person run past a line of spawned NPCs.

### test_interaction 🔧 — **MW**
End-to-end Phase B interaction pipeline in a minimal world: fly camera +
InteractionRaycaster, a fake NPC and a fake book on interaction layer 3, shared
DialogueUI/BookViewer, real MWDialogueProvider + quest wiring. E on NPC opens
dialogue; E on book opens the viewer; Esc closes.

### Interaction phase scenes I0–I7 🩺 — mostly **None**
One acceptance scene per phase of the interaction/carry build-out
(`docs/systems/interaction_system.md`). Each runs headless-friendly self-tests
on startup, then offers an interactive verification flow:

| Scene | Contract | Data |
|-------|----------|------|
| `test_interaction_phase_I0` | PlayerController as single input owner; tap/hold/release signals; modal UI gate | **MW** (real dialogue) |
| `test_interaction_phase_I1` | Carryable registry + static→rigid body factory (fake records inline) | None |
| `test_interaction_phase_I2` | PickupInteractable + InventoryService stub; refused-pickup path (R toggles a FORBIDDEN service) | None |
| `test_interaction_phase_I3` | CarryController: deferred reparent, mask flip/restore, roll lock, NaN guard | None |
| `test_interaction_phase_I4` | Throw + weight cap + wall pushback; time-keyed ring buffer | None |
| `test_interaction_phase_I5` | Auto-buoyancy: carryables float (apple/barrel/crate dropped into ocean) | None |
| `test_interaction_phase_I6` | Carried-object streaming safety: persistent-node evacuation on cell unload (fake cells) | None |
| `test_interaction_phase_I7` | Door/container/activator adapters + shutdown crash fix | None |

### test_carry_velocity_drive 🔧 — **None**
The HL2 physics-gun carry pattern: body stays dynamic, velocity commands chase
a camera-derived target pose each physics tick, Jolt integrates, engine
interpolation smooths. The canonical-pattern replacement for the old kinematic
carry loop (see CLAUDE.md "Simplicity Over Over-Engineering") — good HN story
material.

### test_carry_vibration_audit 🩺 — **None**
Numerical diagnostic for hold-pose vibration: flat floor, one 5 kg barrel, and
`carry_telemetry_logger.gd` sampling positions at both physics and render rate
to attribute stutter to physical, visual, or composition-jitter causes.
(`carry_telemetry_logger.gd` is a helper node, not a scene.)

### test_input_phase_K0 🩺 — **None**
Input-action acceptance board: live indicator for every required InputMap
action — press each key/button and watch it light up. Auto-verifies all
required actions exist on startup. The canonical example of the unified input
contract (AZERTY/QWERTY parity, gamepad).

---

## UI & Dialogue

### test_dialogue 🎬 🔧 — **MW**
DialogueUI panel against the real MWDialogueProvider: NPC selector dropdown
(Fargoth, Arrille, Caius Cosades, …), greetings, topics, response scripts,
goodbye — the full framework-panel-consumes-adapter loop.
- **Capture:** dialogue panel open on a known NPC with topic list visible (Pelagiad font).

### test_book_viewer 🎬 🔧 — **MW**
BookViewer with real richly-formatted Morrowind books.
- **Controls:** ←/→ cycle books · Esc close current book
- **Capture:** an open book spread with MW text formatting.

### test_journal 🎬 🔧 — **MW**
Quest journal: simulates quest progressions with real Morrowind journal
entries, toast notifications on updates.
- **Controls:** J toggle journal · simulate button steps quests forward
- **Capture:** journal open with several quest entries + a toast firing.

---

## Infrastructure

### test_fast_quit 🩺 — **None**
Verifies quit is near-instant (<100 ms) even with 5,000 dummy nodes + 500 RS
instances simulating loaded cells. Q = fast-path quit, Esc = menu quit; timing
printed to console.

---

## Related scenes outside `tests/visual/`

| Scene | Purpose |
|-------|---------|
| `tests/run_tests.tscn` | gdUnit4 runner for the unit/integration suites (exit code 0 = pass) |
| `tests/diagnostic/frozen_rb_tick_check.tscn` | Jolt frozen-RigidBody tick behavior probe |
| `tests/prebaking/test_impostor_baker_v3.tscn` | impostor baker pipeline test |
| `tests/prebaking/test_impostor_height_filter_smoke.tscn` | impostor height-filter smoke |
| `tests/tools/capture_screenshot.tscn` | manual screenshot helper tool |

---

## Maintenance notes (2026-07-05)

- The phase scenes (I0–I7, K0) are development acceptance gates, not
  showcases — for public posts, point readers at the 🎬 scenes.
- 2026-07-05 cleanup: removed `test_rs_lod_smoke` (self-marked delete-after-B.1)
  and the nine auto-quit ocean smoke scenes; fixed the hardcoded cache path in
  `test_material_visual.gd`.
