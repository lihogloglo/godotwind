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
- Opaque FFT water surface for waves, foam, reflection, absorption, and
  visible wave-tip translucency.
- A dedicated underwater / waterline compositor path for submerged-object
  distortion, underwater fog, caustics, and the camera-underwater view.
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
- Jacobian foam, shore intersection foam, Beer-Lambert absorption tint, custom
  in-shader SSR, and wave-tip SSS approximation are present. Surface-owned
  screen refraction has been retired in favor of the waterline compositor.
- A separate underwater volume track exists (`docs/systems/underwater.md`,
  `src/core/water/underwater_volume.gd`,
  `src/core/water/shaders/underwater_volume.gdshader`) with wobble, caustics,
  and absorption, but it is not yet the owner of ocean waterline/submerged
  object distortion and still has known ghosting issues.
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
- Ocean surface refraction is carrying too much responsibility. Attempts to fix
  half-submerged object ghosts purely inside `ocean_fft_common.gdshaderinc`
  trade one artifact for another: foreground halos versus straight underwater
  mesh overlap. This is now treated as an architecture problem, not a guard
  tuning problem.
- The projected-grid mesh path has broken or unstable refraction/SSR, implying
  its surface-position/depth contract with the shared fragment shader needs a
  separate audit before it can become default.
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
- Refraction/absorption: keep the FFT ocean surface opaque for large-water
  stability, depth authority, foam, and reflection. Do not use Godot's native
  transparent refraction as the main ocean path: Godot 4.6 documents it as
  screen-space, transparent-pipeline, sorting-limited, and incompatible with
  several screen/depth/reflection expectations.
- Waterline / underwater distortion: use a dedicated underwater or compositor
  pass (Option C), not more ad hoc silhouette guards in the surface shader.
  The ocean surface should render the water surface; the underwater path should
  own submerged-object wobble, caustics, water fog, and below-surface camera
  behavior.
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
- Refraction foreground ghosts and straight-underwater-mesh overlap exposed a
  deeper pipeline problem: surface refraction and underwater/waterline
  distortion are fighting inside one screen-space shader. Decision for the next
  refactor: switch to Option C. Keep the FFT ocean surface opaque and simplify
  its refraction role; move submerged-object wobble, waterline transition,
  underwater fog, and caustics into the underwater/compositor path. The old
  underwater volume shader already has caustics/wobble/absorption and must be
  folded into this tracker as the starting point, even though it is not yet
  production-quality.
- Render-order audit captured in
  `docs/audit/ocean_option_c_render_order_2026_05_07_codex.md`: a late
  transparent `UnderwaterVolume` can diagnose and serve underwater-camera
  effects, but above-water half-submerged-object distortion needs a compositor
  or pre-ocean capture path if the visible ocean mesh hides the submerged
  object depth.
- Ocean Lab now disables OceanManager's legacy ShaderManager underwater
  compositor through `set_underwater_compositor_enabled(false)` instead of
  letting OceanManager re-enable it every frame and then force-disabling it
  from the lab.
- Ocean Lab `UnderwaterVolume` diagnostics were added:
  `UW Scope: BelowCam/Debug` (renamed from the earlier all-camera label),
  `Ocean Mesh: On/Off`, and
  `UW Debug: Final/Slab Mask/Depth/Y/Big Wobble`. These are interactive-only
  controls for proving what the underwater path sees; no automated screenshot
  harness was added.
- User visually diagnosed the first `UnderwaterVolume` bug: the volume was
  classifying pixels against flat `sea_level` while the visible FFT ocean mesh
  displaced up/down. This produced a flat underwater slab boundary through a
  moving wave surface. Fixed in Ocean Lab by syncing FFT `map_scales`,
  `wave_scale`, shore mask, and shore-wave uniforms from the ocean material and
  computing a dynamic water level per pixel in
  `src/core/water/shaders/underwater_volume.gdshader`.
- User visually confirmed the dynamic underwater slab fix: `UW Debug:
  Slab Mask` now follows the visible wave crests/troughs instead of a flat
  plane.
- Follow-up diagnostics now sync OceanManager optical constants into
  `UnderwaterVolume`: surface deep tint, Beer-Lambert extinction sigma, and
  weather-scaled underwater caustic strength. The wobble neighbor guard also
  compares against the displaced water height instead of flat `sea_level`, and
  the slab top is biased just below the dynamic surface so a visible opaque
  ocean mesh does not get mistaken for submerged scene geometry.
- User re-ran the intended `UW Scope: Debug` / `UW Debug: Big Wobble` check
  after dynamic-waterline sync. With `Ocean Mesh: On` versus `Off`, the volume
  effect looks broadly similar; the visible difference is an outline at the
  object waterline when the ocean mesh is on. This means the late
  `UnderwaterVolume` can tint/wobble visible submerged pixels, but the opaque
  ocean surface still owns the exact object/water intersection. Treat the
  volume wobble as diagnostic scaffolding / underwater-camera effect, not the
  final above-water waterline refraction solution.
- User identified the remaining small "refraction" as `UnderwaterVolume`
  wobble: tiny edge shimmer on objects, visually not good enough. This was not
  the retired surface-shader screen-refraction path; above-water refraction
  ownership moved to the Waterline compositor. Next pass should expose an
  explicit `UW Wobble` toggle so absorption/caustics can be evaluated without
  this diagnostic distortion.
- First Option C compositor ownership probe added:
  `src/core/shaders/effects/waterline_compositor_effect.gd` plus
  `src/core/shaders/compute/waterline_probe.glsl`. It originally ran at
  `PRE_TRANSPARENT`, classifies opaque scene pixels against the displaced FFT
  water height, and uses OceanManager optical getters for tint/absorption. This
  is a strong visual marker to prove ordering, not final waterline polish.
- Ocean Lab now has `UW Wobble: On/Off` and `Waterline: On/Off` (older notes
  called this `WL Proto`). `UW Wobble` defaults off so tint/absorption/caustics
  can be evaluated without the small edge shimmer; `Waterline` defaults on to
  make the compositor ownership proof obvious.
- 2026-05-07 follow-up: the new compute shader needed an editor import pass
  before game launch could load it as an `RDShaderFile`. After import, console
  launch reached Ocean Lab ready and logged:
  `[WATERLINE_PROTO] render callback fired enabled=true pipeline=true
  displacement=true shore=true`. User visually confirmed the cyan WL Proto
  waterline and magenta corner marker are visible, proving compositor execution
  and resource binding.
- WL Proto alignment pass added `WL Debug: Final/Flat/FFT/FFT+Shore/Delta`.
  The classifier now uses water-surface sample distance for FFT cascade fade
  instead of object-pixel distance, includes shore-wave height as a selectable
  term, and does a small inverse step for horizontal FFT/shore displacement so
  the screen-space classifier better matches the actual displaced mesh. User
  observed the first cyan line was not perfectly aligned with the moving ocean;
  next pass should use the debug modes to identify the remaining mismatch
  before adding polish.
- WL Proto sampler-contract fix: the compositor now samples the FFT
  displacement array with repeat wrapping, matching the tiled ocean vertex
  shader and CPU wave sampler, while depth reconstruction uses nearest depth
  sampling to avoid interpolated geometry edges. This should remove a major
  world-UV alignment error before further visual tuning.
- WL Proto debug band tightened: the cyan waterline marker is now a narrow
  band with only a small antialias edge instead of a broad feather, making
  above/below alignment errors easier to judge interactively.
- Verification gotcha: after editing `waterline_probe.glsl`, delete its
  generated `.godot/imported/waterline_probe.glsl-*.res/.md5` artifacts and run
  Godot with `--import` before visual checks. A stale imported `RDShaderFile`
  can make the lab appear to ignore shader edits.
- Timing probe: surface shore-wave / foam animation and WL Proto now share an
  OceanManager-owned `ocean_time` instead of mixing spatial-shader `TIME` with
  compositor-side wall-clock sampling. If the cyan band still appears offset
  after cache-cleared verification, remaining drift is more likely classifier
  geometry/depth reconstruction than clock phase.
- WL Final first pass: cyan is now debug-only. `WL Debug: Final` uses the
  aligned classifier for subtle submerged-object tint/absorption plus a small
  non-cyan transition band, while `WL Debug: Flat/FFT/FFT+Shore` keep the
  narrow cyan measuring band for diagnosis.
- Future requirement: support a half-immersed camera view. When the camera is
  near/intersecting the dynamic wave surface, the compositor should split the
  frame by the moving wave intersection: underwater absorption/fog/caustics on
  the submerged portion of the screen, normal above-water atmosphere on the
  exposed portion, and a waterline that moves up/down with the FFT waves.
- Shore-wave quality requirement: the near-land analytical/Gerstner shore
  waves are an accepted architecture choice for adding surf close to land while
  FFT handles the broader ocean, but the current animation direction is wrong.
  The shore waves appear to travel out toward the ocean instead of in toward
  the real shore. They should also shrink as they approach the shoreline and
  climb only a few dozen centimeters up the beach for a gentle lap/run-up,
  rather than flattening abruptly at the shore.
- Shore-wave direction/envelope fix: `shore_data.gb` is documented by both the
  runtime and C# shore-mask bakers as pointing away from shore. The analytical
  shore-wave phase now travels toward decreasing shore distance, and the
  amplitude envelope keeps a small near-shore run-up lobe instead of dropping
  to zero at the shoreline. The visible ocean, underwater volume, and WL Proto
  classifier were updated together so diagnostics stay aligned.
- Option C source-buffer pass started: Ocean Lab now creates a secondary
  receiver `SubViewport` camera. The first attempt excluded only the dedicated
  water render layer; the current architecture captures only opt-in receiver
  objects on render layer `1 << 18`. `PrewaterCaptureEffect` copies that
  viewport's clean color and depth into RD textures, and
  `WaterlineCompositorEffect` samples those buffers instead of the main buffer
  when available. Practical effect: WL Proto can classify and bend/tint the
  object behind the opaque ocean surface, while rejecting offset samples whose
  reconstructed receiver world position is above the displaced FFT waterline.
  The underwater-camera debug no-entry case is also handled: when the camera is
  already below the dynamic water surface, the compositor no longer searches
  for an impossible forward entry crossing.
- Verification: `waterline_probe.glsl` and `prewater_capture.glsl` import
  artifacts were deleted from `.godot/imported/`, then Godot was run with
  `--import` to force shader recompile. Ocean Lab was launched interactively
  afterwards for visual inspection.
- Follow-up after user visual check: the receiver capture viewport was fixed
  to track the main viewport size instead of a hardcoded 1280x720 target. The
  mismatch could make `WL Debug: Refract` appear as sliding colored wedges
  around half-submerged objects while moving. The refraction sample was also
  simplified to a source-buffer screen offset driven by the dynamic FFT water
  normal, followed by the same reconstructed-world-position waterline reject.
  This keeps the proper receiver-buffer architecture while removing the brittle
  above-water entry-ray dependency from the visible bending path.
- Shore-wave timing/run-up follow-up: the analytical shore/Gerstner layer now
  uses a shared `ocean_time` clock and a gravity-wave dispersion-derived
  temporal frequency instead of a separate weather-scaled speed. User visually
  confirmed the shore/Gerstner wave speed now matches the FFT cadence better.
  A second pass removed the first-meter dead strip by deriving a fallback shore
  direction from neighboring shore-mask alpha samples when shore seed pixels
  encode no direction, allowing the run-up lobe to operate at `raw_dist == 0`.
  User visually confirmed the shore now rises/falls, but the motion feels too
  robotic / ON-OFF. Next pass should replace the binary crest-gated run-up with
  a smoother swash curve that advances, slows, and recedes continuously.
- Shore-wave swash pass: the binary crest gate was replaced by a continuous
  swash curve with fast uprush and slower backwash. Weather scaling was raised
  so Storm/Blizzard can push the shore layer well above the previous sub-meter
  cap (`shore_wave_amplitude` now ramps to 2.2m and steepness to 0.95). The
  visible clipmap path, projected-grid path, `UnderwaterVolume`, and WL Proto
  classifier were updated together so diagnostics use the same water height.
- Shore-wave seesaw diagnosis: user screenshot showed a hinge artifact where
  some shore vertices did not move while adjacent water vertices rose/fell.
  Root cause: the shore mask encodes land/seed pixels as zero distance with no
  direction, so those vertices became pinned. Temporary shader bridge: neutral
  shore pixels now search outward up to 8 texels in the shore-mask alpha field
  to recover an offshore gradient and join the swash motion. Proper production
  fix remains a rebaked signed shoreline SDF/depth cache that stores land-side
  run-up distance and direction explicitly.
- Ocean Lab wireframe debug was added as `Wireframe: On/Off`, using the
  viewport wireframe debug draw. It works for both clipmap and projected-grid
  mesh modes and is intended to diagnose topology/blockiness, with the caveat
  that viewport debug draw is not a final shaded ocean view.
- Shoreline smoothness follow-up: user reports the ocean/shoreline edge still
  appears super blocky near the camera. Do not assume the cause yet. Diagnose
  whether the blocks come from ocean clipmap tessellation, Terrain3D shoreline
  geometry/depth silhouette, shore-mask resolution/filtering, or the
  screen-depth water/terrain intersection before choosing a fix.
- Surface refraction has been removed from the FFT surface shader. Do not treat
  the old surface-shader screen refraction path as production-ready or revive
  it for half-submerged objects.
- Wave-tip translucency / SSS is still not visibly working as far as the user
  knows. Phase 5 remains pending.

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
- `Buoy Grid` toggles the CPU-evaluated wave-surface grid. It defaults off so
  the lab opens on the actual ocean view instead of the diagnostic overlay.
- `Spawn Buoy` launches a buoyant sphere from the camera.
- `Mesh: <mode>` toggles clipmap/projected FFT mesh mode.
- `Sun: <angle>` toggles high/low sun for crest-translucency checks.
- `Wet Debug: <state>` toggles wetness debug coloring.
- `Center Shore` returns the camera to the scanned shoreline playground.
- `Quality: <quality>` cycles flat/Gerstner/FFT.
- Surface refraction is retired from the FFT surface shader. The surface stays
  opaque; above-water submerged-object bending is owned by the waterline
  compositor.
- `UW Volume: <state>` toggles the existing `UnderwaterVolume` caustics /
  wobble / absorption pass. This is the seed for the new underwater/waterline
  owner, not yet final quality.
- `UW Scope: <BelowCam|Debug>` controls whether `UnderwaterVolume` only runs
  when the camera is below water or whether non-final debug views can be forced
  on above water for render-order diagnosis. Final above-water waterline
  rendering must stay compositor-owned.
- `Ocean Mesh: <state>` hides only the ocean mesh, without shutting down
  OceanManager. This lets the lab prove whether the underwater pass can see
  submerged objects when the opaque ocean surface is not writing color/depth.
- `UW Debug: <mode>` cycles the underwater volume through final shading, cyan
  underwater slab mask, reconstructed depth/Y coloring, and exaggerated
  wobble/tint. This makes the volume's own depth classification visible during
  interactive diagnosis.
- `UW Wobble: <state>` enables/disables the diagnostic `UnderwaterVolume`
  screen-offset wobble independently from its tint/absorption/caustics.
- `Waterline: <state>` enables/disables the receiver-only `CompositorEffect`
  waterline path.
- `WL Debug: <Final|Flat|FFT|FFT+Shore|Receiver Mask|Refract|Refract Offset|Source>`
  selects the waterline compositor classifier/debug view.
- The underwater volume now syncs FFT `map_scales`, `wave_scale`, shore mask,
  and shore-wave parameters from the ocean material, then classifies pixels
  against the displaced water height instead of a flat `sea_level` plane. This
  fixes the diagnostic mismatch where the visible wave crests moved above the
  underwater slab boundary.
- Wetness sliders drive terrain wetness and the object wet shader.
- Lab buttons/sliders are mouse-only controls (`FOCUS_NONE`) so Space remains a
  fly-camera `jump` input and does not activate whichever UI button was last
  clicked.

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
- User visually confirmed the underwater volume's slab-mask waterline now
  follows FFT wave displacement after the dynamic water-level sync.
- 2026-05-07 follow-up: `test_ocean_lab_mesh_toggle_smoke.tscn` still exits
  cleanly after optical-constant sync and underwater-volume diagnostic changes.
  `test_ocean_lab.tscn` was launched interactively for the requested
  `UW Scope: Debug` / `UW Debug: Final` and `Big Wobble` /
  `Ocean Mesh: On-Off` comparison.

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

Status: in progress

The shore system exists, but it needs to stop looking blocky.

Current 2026-05-07 visual state:

- Shore/Gerstner wave speed is now visually close to the FFT wave cadence after
  switching to shared `ocean_time` plus dispersion-derived timing.
- The waterline now moves up/down at the shore after the shader derives a
  fallback SDF direction from neighboring shore-mask alpha samples on zero
  distance seed pixels.
- The run-up no longer uses the binary crest gate. Current shader uses a
  continuous swash curve and stronger weather energy, so high-wind presets have
  enough vertical headroom for visible storm run-up.
- A temporary shore-gradient fallback reduces the "seesaw" hinge where some
  shore vertices were pinned. This is acceptable for now, but the production
  data model should become a signed shoreline SDF/depth cache with explicit
  land-side run-up support.
- The shoreline/ocean edge still looks blocky near the camera. Cause is
  unproven and must be isolated before fixing.

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
- Verify analytical shore-wave direction so waves travel toward the shore, not
  out toward the ocean. First shader pass implemented; user confirmed speed
  now feels matched to FFT cadence.
- Verify shore-wave amplitude envelope so waves reduce height near the real
  shoreline and produce a small run-up/lapping motion instead of a hard flatten.
  First shader pass implemented; follow-up replaced the binary gate with a
  smoother swash curve and increased weather-scaled amplitude.
- Diagnose first before changing mesh density: compare clipmap versus projected
  grid, shore debug modes, waterline debug modes, and terrain/depth silhouette
  to determine whether the blocky edge comes from ocean mesh tessellation,
  Terrain3D geometry, shore-mask resolution/filtering, or depth intersection.
- Replace the temporary multi-texel shore-gradient fallback with a proper
  signed shoreline SDF/depth-cache bake so beach-side run-up is represented in
  data rather than inferred in the shader.

Acceptance:

- Waves dampen near shore without terrain penetration.
- Shore waves run toward shore smoothly.
- Shore waves visibly lap/run up the beach by a few dozen centimeters, then
  recede, without large rollers intersecting the terrain.
- In strong weather, the shore swash moves as a coherent sheet along/up the
  beach, not as a seesaw hinged on pinned shore vertices.
- No hard square blocks are visible in the wetness/ocean lab coastline.
- CPU `get_shore_factor()` and shader shore result agree at debug sample points.

---

## Phase 4 - Surface / Underwater Split

Status: in progress

Refactor the current surface-only optical path into the Option C architecture:
opaque FFT ocean surface plus dedicated underwater/waterline compositor. This
phase must happen before further refraction tuning. The existing underwater
volume shader is the seed, not the final design.

2026-05-07 handoff:

- Ocean Lab now exposes the old `UnderwaterVolume` path directly and disables
  the legacy ShaderManager compositor in the lab.
- The underwater volume's first correctness bug is fixed in the lab: its
  waterline classification now uses the displaced FFT water height, not a flat
  `sea_level` plane.
- User observation before the dynamic-waterline fix: final shading showed no
  meaningful difference between `Ocean Mesh: On` and `Ocean Mesh: Off` except
  for the ocean-surface waterline/foam line. Re-run this comparison after the
  dynamic-waterline fix before deciding whether a late transparent volume is
  sufficient or whether a compositor/pre-ocean path is required.
- User observation after the dynamic-waterline fix: `UW Debug: Big Wobble` in
  `AllCam` still shows broadly similar submerged tint/wobble with ocean mesh on
  or off, but the ocean mesh adds the visible waterline outline. Conclusion:
  late `UnderwaterVolume` is useful for underwater fog/caustics/tint and for
  diagnostics, but it is not the production owner of above-water
  half-submerged-object waterline/refraction.
- Surface refraction is retired from the FFT surface shader. Do not re-add
  surface-owned `SCREEN_TEXTURE` bending to solve half-submerged objects.
- New direction: keep the FFT ocean opaque and use an explicit refraction
  receiver source. Ocean Lab now proves this with a receiver-layer capture
  viewport plus `PrewaterCaptureEffect`; promote this into runtime only after
  the lab result is visually accepted and costed.
- 2026-05-08 ownership fix: Ocean Lab now prevents `UnderwaterVolume` final
  shading from drawing above water. Its above-water scope is diagnostic-only,
  so it cannot overwrite the receiver waterline compositor result. The legacy
  ShaderManager underwater compositor is disabled by default and enable
  requests are ignored.
- 2026-05-08 object wetness fix: lab wet test objects now receive the active
  `WaterSurfaceState` every frame and their material shader samples FFT
  displacement plus shore swash per fragment, with `wet_line_y` retained only
  as drying high-water memory.
- 2026-05-08 receiver-only cleanup: the broad water-excluding capture was the
  source of the ghosting/terrain projection. Ocean Lab now reserves render
  layer `1 << 18` for refraction receivers, keeps water on `1 << 19`, and
  captures only opt-in objects for `WaterlineCompositorEffect`. Terrain and the
  broad seabed helpers are not receiver inputs.
- 2026-05-08 waterline stage correction: with receiver-only buffers, the
  compositor returns to `PRE_TRANSPARENT`, after opaque ocean and before spray
  or diagnostic volumes. `Final` output requires valid receiver depth plus a
  visible-water gate in the main view, so it must not repaint empty ocean,
  terrain, or dry foreground object parts.

Tasks:

- Keep the failed conditional silhouette-guard experiments out of the surface
  shader; the FFT surface has no production screen-refraction role.
- Decide the exact owner of each effect:
  - FFT surface shader: waves, foam, Fresnel, surface color, surface
    absorption tint, custom SSR/probe/sky reflection, wave-tip SSS.
  - Underwater/waterline path: submerged-object wobble, underwater fog,
    caustics, waterline transition, underwater camera view.
- Keep `UnderwaterVolume` toggleable in the ocean lab for underwater-camera
  tint/caustics and debug views.
- Add a separate `UW Wobble` toggle so the lab can test underwater tint,
  absorption, and caustics without the current edge-only wobble artifact.
- Use Ocean Lab's `UW Scope: Debug` plus `Ocean Mesh: Off` diagnostic to map
  exactly what `UnderwaterVolume` sees before and after the opaque ocean writes
  depth. If the volume only works with the ocean hidden, the final above-water
  waterline solution needs a compositor/pre-ocean/subpass design rather than a
  late transparent volume alone. See
  `docs/audit/ocean_option_c_render_order_2026_05_07_codex.md`.
- Audit `src/core/water/shaders/underwater_volume.gdshader` for current Godot
  4.6 depth reconstruction, sea-level wiring, and its known waterline ghosting.
- Share color/absorption constants between the surface shader and underwater
  shader through OceanManager-facing uniforms or typed getters, so the
  waterline does not change tint abruptly. First pass implemented for
  `UnderwaterVolume`; carry this same API into the compositor prototype.
- Add explicit ocean lab toggles for SSR and underwater volume/compositor.
- Re-run `UW Scope: Debug` with `UW Debug: Slab Mask` and `Big Wobble`, comparing
  `Ocean Mesh: On` and `Ocean Mesh: Off`, now that the underwater slab follows
  the FFT surface. Done visually; result above points toward a compositor
  waterline pass.
- Prototype the smallest `CompositorEffect` waterline pass. Use the same
  dynamic FFT water-height classification and OceanManager optical getters.
  First goal is only to prove ordering/ownership: tint or strongly mark pixels
  classified below the displaced water surface before/around transparent ocean
  composition. First proof is done: console launch logs the render callback
  with valid pipeline/displacement/shore resources, and the user can see the
  cyan WL Proto line plus magenta corner marker.
- Align the WL Proto classifier with the rendered ocean mesh before visual
  polish. Current pass moved closer to the mesh contract by using surface
  distance for cascade fade and approximately inverting horizontal
  displacement, then fixed the compositor sampler contract so FFT displacement
  repeats like the visible ocean mesh instead of clamping at tile edges. Use
  `WL Debug` modes to isolate any remaining drift from shore-wave terms,
  projected/clipmap differences, or depth/object geometry.
- Feed WL Proto from the receiver capture buffers, not from the main
  post-ocean color/depth or a broad terrain capture. Current pass is
  implemented in Ocean Lab; next check is visual quality and frame cost at the
  chosen capture resolution.
- Add the half-immersed camera compositor mode after object waterline ownership
  is proven. The desired behavior is a moving wave-driven split screen:
  underwater treatment below the dynamic surface contour and normal atmospheric
  rendering above it.
- Validate projected-grid mesh separately: refraction and SSR must receive
  coherent `v_world_pos`, `SCREEN_UV`, and depth relations before projected
  grid can become default.
- Reduce custom SSR step count or distance by quality tier if it is expensive,
  but only after the surface/underwater split is stable.

Screen-space policy:

- Use screen-space/compositor passes where they are the canonical fit:
  waterline/submerged-object distortion, underwater camera fog/caustics/tint,
  and broad wetness overlays.
- Keep the ocean itself as a real opaque 3D surface for displacement, normals,
  foam, Fresnel, SSR/probe/sky reflection, and future wave-tip SSS.
- Reflection target: layered reflection, not one magic path. Use custom SSR for
  nearby reflected geometry, reflection probes/sky fallback when SSR misses,
  and consider planar reflection only for deliberate hero views if measurement
  justifies the cost.

Acceptance:

- Submerged geometry is visible with underwater wobble, without a straight
  unrefracted duplicate from the surface shader.
- Above-water foreground objects no longer cast faint refraction ghosts onto
  water behind them.
- Half-submerged objects have a stable waterline transition owned by the
  underwater/waterline path, not by more surface-shader guard tweaks.
- Underwater caustics/fog/wobble from the old underwater shader are visible in
  the ocean lab when enabled.
- SSR reflects nearby opaque/emissive targets without dominating the water.
- Distant water remains stable and does not shimmer excessively.

---

## Phase 5 - Wave-Tip Translucency

Status: pending

The shader already has a Sea of Thieves-inspired SSS approximation, but the
user reports tip translucency does not work. As of the 2026-05-07 handoff,
this is still believed broken / unverified; do not assume the existing SSS
uniforms are producing a visible wave-tip translucency effect.

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

Status: first pass implemented 2026-05-08, visual tuning in progress

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

2026-05-08 first pass:

- Added `OceanSpray`, a GPU-particle sea-spray layer owned by OceanManager.
  The particle shader samples the same FFT displacement cascade as the surface
  shader, then activates only high-energy candidate particles in a
  camera-centered world-space window.
- Weather drives spray energy: calm stays off, breeze starts sparse misting,
  and storm/blizzard presets increase opacity, size, and wind drift.
- Ocean Lab exposes `Spray: On/Off`, `Spray Q: Off/Low/Medium/High`, and HUD
  `spray_energy` so visual quality and cost can be compared interactively.
- Artist-authored texture hook: `res://src/core/water/textures/sea_spray.png`
  is used if present; otherwise a procedural soft spray texture is generated.
- Shader cache entries matching `ocean_spray*` were cleared before import.
  Godot `--import` succeeded, the Ocean Lab mesh-toggle smoke exited cleanly,
  and `tests/visual/test_ocean_lab.tscn` was launched interactively for user
  visual checking.

2026-05-08 tuning update:

- Replaced the crude choppiness-first spawn mask with the GodotOceanWaves-style
  foam/normal signal: foam is the primary activation source, normal slope
  filters broad flat foam, and a lower-weight choppiness/height fallback keeps
  sharp crests alive when foam is sparse.
- Imported `src/core/water/textures/sea_spray.png` from GodotOceanWaves
  (MIT; attribution in `src/core/water/textures/ATTRIBUTION.txt`) and updated
  the billboard shader to preserve the texture's irregular shape with a
  lifetime dissolve.
- Added per-particle size variation: mostly small wisps, some medium sheets,
  and rare larger bursts. Width and height vary independently so the spray no
  longer reads as repeated identical stamps.
- Added performance A/B hooks: `OceanManager.get_sea_spray_status()`,
  `toggle_sea_spray()`, Ocean Lab HUD fields for emitting/candidates/energy,
  and the main-scene console command `ocean_spray [on|off|status]` with
  `spray` alias.
- Cost note: foam-driven spawn is more expensive than the earlier
  choppiness-only prototype because candidate particles now sample normal/foam
  data in addition to displacement and active particles follow the surface.
  It does not add new FFT generation work; the first performance knob is
  spray quality/candidate count.
- Verification: cleared `.godot/shader_cache/`, ran Godot `--import`, ran
  `tests/visual/test_ocean_spray_smoke.tscn` successfully, and relaunched
  `tests/visual/test_ocean_lab.tscn` interactively for visual checking.

2026-05-08 Ocean Lab visual feedback handoff:

- User visually confirmed the wave-tip SSS direction/sign fix: translucency now
  reads correctly when looking toward the sun instead of when the sun is behind
  the camera.
- Shoreline wetness currently looks best on terrain with wet margin set to
  `0.05` in Ocean Lab. Treat this as the known-good visual tuning point for the
  next session.
- The other shoreline wetness settings are still wrong visually. Do not preserve
  them as final tuning; next pass should retune from the `0.05` margin baseline
  and continue separating dynamic wave-runup wetness from any static waterline
  darkening.

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
