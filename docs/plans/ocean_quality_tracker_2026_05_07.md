# Ocean Quality Tracker

Date: 2026-05-07
Status: Ocean Lab active, Phase 0 stabilization in progress
Owner: current ocean session

Goal: make the Godotwind ocean look excellent while staying performant enough
for the open-world runtime. This tracker supersedes scattered ocean to-do notes
for session ordering, but does not replace the detailed subsystem docs.

---

## North Star

Godotwind should have a modern open-world ocean:

- FFT displacement with clipmap or projected-grid surface coverage.
- Jacobian foam and storm-scaled whitecaps.
- Sea spray on wave tops, Sea of Thieves style.
- Opaque water with depth-buffer refraction, Beer-Lambert absorption, custom SSR,
  and visible wave-tip translucency.
- Shore waves that run up beaches without blocky mask artifacts.
- Wet terrain and objects where water has been.
- Buoyancy that matches the visual wave surface and does not tank frame time.

The acceptance bar is not "the shader compiles." Each phase must be checked in
an interactive ocean testbed and, where possible, with a repeatable perf/crash
smoke.

---

## Current Audit

### Present

- FFT ocean exists in `src/core/water/wave_generator.gd`.
- Two FFT render paths exist:
  - `src/core/water/shaders/ocean_fft.gdshader` for clipmap mesh.
  - `src/core/water/shaders/ocean_fft_projected.gdshader` for projected grid.
- Shared surface shading lives in
  `src/core/water/shaders/ocean_fft_common.gdshaderinc`.
- Jacobian foam, shore intersection foam, Beer-Lambert absorption, guarded
  refraction, custom in-shader SSR, and wave-tip SSS approximation are present.
- Shore-mask vertex dampening and analytical shore waves already exist in both
  FFT vertex paths.
- Terrain wetness exists through `HorizonMapManager` plus
  `src/core/world/terrain_horizon.gdshader`.
- Object wet-line memory exists in the wetness visual test via
  `src/core/shaders/object_wet.gdshader`.
- Buoyancy exists via `BuoyancyBody3D` and `BuoyancyProbe3D`.

### Missing Or Risky

- No dedicated all-in-one ocean lab scene. Current tests each cover one slice.
- No built-in visual/perf matrix for ocean feature toggles.
- No sea spray layer.
- No shipped `WetnessManager` or screen-space wet compositor. Wetness is terrain
  and test-object only.
- GPU readback for buoyancy uses `RenderingDevice.texture_get_data()` every
  process frame for every cascade. Official Godot docs say this blocks the GPU;
  `texture_get_data_async()` is the canonical alternative.
- `BuoyancyBody3D` multiplies force vectors by `delta` before `apply_force()`.
  Godot's RigidBody3D docs define `apply_force()` as a time-dependent force
  applied every physics update, not an impulse.
- Shore waves are present, but blockiness likely comes from mask resolution,
  mask format, bounds, sampling, or amplitude envelope tuning.
- Wave-tip translucency exists as SSS, but the visible result is weak or broken.
- Old test scenes use a mix of raw key polling and InputMap actions. New test
  scenes must use the unified input system.

---

## Canonical Patterns

- Ocean surface coverage: projected grid / clipmap, as used by Sea of Thieves,
  Wicked Engine, and CDLOD-style ocean grids.
- Shore wave shaping: SDF/depth-cache driven shore behavior, CREST/Outerra
  style, not separate hand-placed shore meshes.
- Foam: FFT/Jacobian whitecaps plus shore intersection foam. Dynamic spray is a
  separate particle or impostor layer driven by crest masks and wind.
- Refraction/absorption: opaque depth-buffer water with Beer-Lambert absorption.
  Godot transparent water is not acceptable here because transparent materials
  do not participate properly in screen/depth effects.
- Reflections: custom SSR remains necessary for this material because Godot
  screen/depth texture use and native SSR have ordering/visibility limits.
- Wetness: Sebastien Lagarde PBR wet surfaces, with terrain/material/compositor
  paths sharing one formula.
- Buoyancy: RigidBody forces in physics tick; GPU readback must avoid per-frame
  blocking where possible.

---

## Phase 0 - Ocean Lab Testbed

Status: first pass implemented 2026-05-07; stabilization pass in progress

Created `tests/visual/test_ocean_lab.tscn` and
`tests/visual/test_ocean_lab.gd`. The first pass forks the wet terrain setup and
pulls in the buoyancy debug grid, weather presets, mesh-mode toggle, shader
debug cycling, low-sun toggle, reflection/refraction canaries, wet test objects,
and HUD. The second pass moved all ocean/debug management to a button UI and
anchors the playground to a scanned Terrain3D shoreline instead of world origin.
The third pass made the UI stateful enough to use without memorizing shortcut
cycles: the debug button now shows the active shader debug mode number/name, and
weather/mesh/sun/wetness/quality buttons show their current state. The wetness
pickup objects were also moved west/south of the shoreline playground and raised
above the waterline so they are not buried in terrain at startup. Next pass
should add explicit feature cost toggles after the OceanManager/shader APIs
exist.

2026-05-07 stabilization notes:

- Mesh-mode rebuild lifecycle was hardened after the lab's `Mesh: <mode>`
  button was reported to crash when toggling back to clipmap. The old
  `OceanMesh` is now detached from the scene tree before being queued for
  deletion, and a crash-smoke scene exercises `Clipmap -> Projected -> Clipmap`.
- Water-thickness debug mode exposed a hard cutoff where genuinely deep
  underwater terrain was being classified as sky/far. The shader now treats
  only near-zero reversed-Z depth samples as sky/far; deep valid scene geometry
  remains deep water and is only clamped for absorption/debug scaling.

### Source Scenes To Merge

- From `test_wet_map.gd`:
  - Terrain3D setup.
  - HorizonMapManager terrain wetness path.
  - Wetness sliders.
  - Draggable wet test objects.
- From `test_buoyancy_debug.gd`:
  - Full FFT OceanManager setup.
  - Buoyancy CPU surface MultiMesh debug grid.
  - Weather presets.
  - Mesh mode toggle, clipmap versus projected.
  - Debug mode cycling.
  - Low-sun toggle for wave-tip translucency.
  - Buoyant object spawning.
- From `test_reflections.gd`:
  - Reflection/refraction canary geometry.
  - Half-submerged monolith.
  - Submerged rock and checker seabed.
  - Emissive and metallic reflection targets.
- From `test_ocean_shore.gd`:
  - Shore-focused camera positions.
  - Shore parameter controls, updated to match current shader uniforms.

### Required Controls

Use InputMap actions for movement and camera mode. Do not add new raw
`Input.is_key_pressed(KEY_*)` movement loops.

- Move/fly using `move_left`, `move_right`, `move_forward`, `move_backward`,
  `jump`, `crouch`, and `sprint`.
- Toggle mouse capture with the existing UI/cancel action or a clearly mapped
  project action.
- Cycle ocean shader debug modes.
- Toggle clipmap/projected mesh mode.
- Toggle FFT/Gerstner/flat quality only through `OceanManager` public API.
- Toggle buoyancy surface grid.
- Spawn buoyant object.
- Cycle weather presets.
- Toggle low sun/high sun.
- Toggle wetness debug.
- Toggle major ocean cost centers: SSR, refraction, foam, SSS, shore waves,
  buoyancy readback, and sea spray once implemented.

### Required HUD

Display:

- FPS and frame time.
- Ocean quality and mesh mode.
- FFT map size, cascade count, update rate.
- Readback mode: sync, async, disabled, or fallback.
- Buoyancy query count per frame.
- Active weather preset and wind strength.
- Debug mode name.
- Shader feature toggles.
- Shore mask bounds/resolution/fade distance if available.
- Wetness parameters.

### Current UI

Implemented as a left-side button panel plus wetness sliders:

- `Debug: <mode> <name>` cycles shader debug mode and displays the current
  meaning.
- `Weather: <preset>` cycles calm/breeze/moderate/storm/blizzard.
- `Buoy Grid` toggles the CPU-evaluated wave-surface grid.
- `Spawn Buoy` launches a buoyant sphere from the camera.
- `Mesh: <mode>` toggles clipmap/projected FFT mesh mode.
- `Sun: <angle>` toggles high/low sun for crest-translucency checks.
- `Wet Debug: <state>` toggles wetness debug coloring.
- `Center Shore` returns the camera to the scanned shoreline playground.
- `Quality: <quality>` cycles flat/Gerstner/FFT.
- Wetness sliders drive terrain wetness and the object wet shader.

### Acceptance

- Scene launches interactively with the documented Godot binary.
- The ocean renders in FFT mode by default on supported hardware.
- User can fly from deep water to shore without scripted camera capture.
- Debug grid visually tracks wave crests and troughs.
- Reflection/refraction canaries are visible.
- Wet terrain and draggable wet objects are present.
- No automated screenshot harness is added.

### Phase 0 Verification

- `tests/visual/test_ocean_lab.tscn` launched with the documented Godot 4.6
  binary and reached Ocean Lab ready.
- `tests/visual/test_ocean_lab_mesh_toggle_smoke.tscn` completed the mesh-mode
  round trip without crashing.
- User visually confirmed the water-thickness hard cutoff was fixed in the lab.

---

## Phase 1 - Measurement And Cost Switches

Status: pending

Before visual tuning, make the current cost visible and controllable.

Tasks:

- Add public OceanManager toggles or shader uniforms for SSR, refraction, foam,
  SSS, shore waves, and readback.
- Add counters around `get_wave_height()` and readback requests.
- Add a readback mode:
  - `sync`: current `texture_get_data()` path.
  - `async`: `texture_get_data_async()` callback path.
  - `disabled`: use `OceanPhysicsEvaluator` or Gerstner fallback.
- Add a lightweight benchmark route for the ocean lab that can run without
  screenshots and logs average FPS/frame time for each toggle set.

Acceptance:

- Ocean lab can isolate the cost of each feature.
- Sync readback cost is visible.
- Disabling buoyancy readback does not disable the visual ocean.
- No feature toggle changes visual defaults in normal gameplay.

---

## Phase 2 - Buoyancy Correctness And Readback

Status: pending

Fix buoyancy before adding spray or wake effects because many later systems will
use the same wave sample path.

Tasks:

- Verify `apply_force()` usage against Godot 4.6 docs.
- Remove erroneous `delta` scaling from `BuoyancyBody3D` force application if
  confirmed in-scene.
- Keep forces in `_physics_process()`.
- Convert displacement readback to async or rate-limited async.
- Decide whether visual-perfect readback is needed every frame:
  - Small clutter: fallback/evaluator may be enough.
  - Boats: async GPU readback at a lower rate plus interpolation may be enough.
- Make readback cascade count configurable.

Acceptance:

- Buoyant objects sit on the visual water in calm, breeze, and storm presets.
- No large FPS drop just from enabling buoyancy.
- The ocean lab shows sync versus async versus fallback behavior clearly.

---

## Phase 3 - Shore Quality

Status: pending

The shore system exists, but it needs to stop looking blocky.

Tasks:

- Inspect actual loaded shore mask metadata and image format.
- Verify the prebaked mask matches current terrain bounds and sea level.
- Confirm shader sampling uses the same coordinate convention as the baker.
- Test nearest versus linear/mipmap sampling impact on blockiness.
- Tune `shore_fade_distance`, `shore_wave_amplitude`, `shore_wave_frequency`,
  `shore_wave_speed`, and `shore_wave_steepness` in the ocean lab.
- If mask resolution is the limit, rebake at the smallest resolution that fixes
  visual blockiness without wasting memory.
- If gradient quantization is the limit, evaluate a higher precision format or
  derived smooth gradient.

Acceptance:

- Waves dampen near shore without terrain penetration.
- Shore waves run toward shore smoothly.
- No hard square blocks are visible in the wetness/ocean lab coastline.
- CPU `get_shore_factor()` and shader shore result agree at debug sample points.

---

## Phase 4 - Water Color, Refraction, Absorption, SSR

Status: pending

This phase tunes the already implemented surface optics.

Tasks:

- Validate depth reconstruction in the ocean lab across shallow shelf, deep
  floor, submerged rock, and half-submerged monolith.
- Tune Beer-Lambert coefficients for Morrowind-scale water.
- Re-check refraction guard chain after tuning strength.
- Add feature toggles to isolate refraction and SSR in the lab.
- Reduce custom SSR step count or distance by quality tier if it is expensive.
- Keep ReflectionProbe and sky fallback working when SSR misses.

Acceptance:

- Submerged geometry is visible and refracted without silhouette halos.
- Half-submerged objects have tolerable waterline behavior.
- SSR reflects nearby opaque/emissive targets without dominating the water.
- Distant water remains stable and does not shimmer excessively.

---

## Phase 5 - Wave-Tip Translucency

Status: pending

The shader already has a Sea of Thieves-inspired SSS approximation, but the
user reports tip translucency does not work.

Tasks:

- Use ocean debug mode 9 under low sun in the ocean lab.
- Compare current `v_choppiness` peak mask against Jacobian foam mask.
- Prefer the mask that fires only on real crests.
- Tune scatter color, thresholds, view term, and sun backlight term.
- Ensure the effect is color-stable through sunset lighting.

Acceptance:

- Low-sun crests visibly glow/transmit light.
- Top-down calm water does not turn into broad green patches.
- The effect scales with weather/wind.

---

## Phase 6 - Sea Spray

Status: pending

Add Sea of Thieves-style spray after the crest mask and performance controls are
trusted.

Canonical direction:

- GPU particles or camera-facing impostor quads emitted from high crest mask
  regions, wind-biased, distance-faded.
- Use wave crest/Jacobian/choppiness thresholds as the spawn signal.
- Keep spray as a separate layer from foam so it can be disabled independently.

Tasks:

- Prototype spray in ocean lab only.
- Use wind direction and wave crest mask for placement.
- Fade by distance and weather.
- Avoid CPU spawning per wave vertex.
- Add quality tiers and a hard off switch.

Acceptance:

- Storm waves shed visible spray at crests.
- Calm water has little to no spray.
- Spray is not locked to screen space in an obvious way.
- Feature can be disabled with measurable perf recovery.

---

## Phase 7 - Wetness System Integration

Status: pending

Terrain wetness and object wet-line memory exist, but the canonical full system
does not.

Tasks:

- Implement or revive the `WetnessManager` plan from
  `docs/plans/wetness_system.md`.
- Keep `HorizonMapManager` responsible only for applying the terrain shader
  override.
- Add shared wetness uniforms for terrain, object wet shader, and future
  compositor path.
- Add screen-space compositor wetness only after measuring its cost.
- Integrate carry items and characters through per-material wetness memory.

Acceptance:

- Terrain near water gets dark/glossy in the ocean lab.
- Draggable objects retain a wet line after dunking and dry over time.
- Main-world objects have at least compositor wetness or documented fallback.
- Cost is measurable and toggleable.

---

## Phase 8 - Main Scene Integration

Status: pending

Only integrate after the ocean lab is stable and measured.

Tasks:

- Launch `scenes/Godotwind.tscn` interactively.
- Enable ocean in a controlled way around Seyda Neen coast.
- Verify frame time with ocean off/on and feature toggles.
- Verify shore mask matches real Terrain3D data.
- Verify wetness and buoyancy do not affect interiors or unloaded cells.

Acceptance:

- Main scene launches and streams with ocean enabled.
- Ocean does not create a persistent large FPS loss outside expected feature
  budgets.
- Shore and wetness behavior holds up on real Morrowind terrain.

---

## Verification Rules

- C# changes require `dotnet build Godotwind.sln` before launching Godot.
- Gameplay, streaming, rendering, or performance changes require either:
  - interactive launch of the relevant scene, or
  - automated benchmark/crash smoke that exercises the changed path.
- Visual ocean work must be checked interactively. No auto-capture proof.
- New visual test scenes must use InputMap actions for movement.
- Final summaries must explain the practical visual or performance effect, not
  only list files.

---

## Open Questions

- Which mesh mode should become the default after measurement: clipmap or
  projected grid?
- Is visual-perfect buoyancy worth GPU readback every frame, or should boats use
  async readback and clutter use the CPU evaluator?
- Should sea spray be GPU particles, MultiMesh impostors, or a hybrid?
- Should screen-space wetness ship globally, or should terrain/material wetness
  cover the first integration pass?
- Does the prebaked shore mask need a higher precision format, or is the current
  blockiness from stale/wrong bounds data?
