# Ocean Underwater Rendering Overhaul - 2026-05-09

Canonical cross-session tracker for turning the current ocean / underwater work
into a production-quality rendering path. Update this file as work lands; use
`docs/audit/` for the research notes and rationale that back each phase.

## Tracker Status

| Phase | Status | Date | Verification | Notes |
|-------|--------|------|--------------|-------|
| Phase 0 - Research And Ground Truth | [x] Complete | 2026-05-09 | Static audit only | See `docs/audit/ocean_underwater_architecture_2026_05_09.md`. |
| Phase 1 - Cleanup Ownership | [x] Complete | 2026-05-09 | Static refs + import + timed Godot smokes | Legacy compute/quad paths deleted; `OceanManager` no longer loads the old underwater compositor. |
| Phase 2 - Shared Water Surface And Mask Contract | [x] Complete | 2026-05-09 | Import + timed Godot smokes | Shared surface/mask contract now feeds visual shaders, waterline compositor, and wetness. The old diagnostic volume was deleted on 2026-05-11. |
| Phase 3 - Half-Immersed Camera Split | [x] Complete | 2026-05-09 | Import + timed Godot smokes + interactive main-scene launch | Per-pixel camera split now gates underwater combine; human visual judgement remains with the launched scene. |
| Phase 4 - Snell's Window Rebuild | [ ] Pending | - | - | Must use correct above-water/sky source. |
| Phase 5 - Wobble Rebuild | [ ] Pending | - | - | Screen-space FBM has been removed; final scale/art tuning still pending. |
| Phase 6 - Rays And Caustics Rebuild | [ ] Pending | - | - | Separate ray and caustic gates. |
| Phase 7 - Main Scene Integration | [ ] Pending | - | - | Ocean Lab and `scenes/Godotwind.tscn` must share the path. |
| Phase 8 - Performance And Quality Gate | [ ] Pending | - | - | Final docs update only after visual verification. |

## Purpose

Immediate symptoms:

- Snell's window has visible artifacts and only reads convincingly in deeper
  water.
- Underwater rays work-ish in deep water but glitch in shallow water.
- Wobble is too weak or wrong-scale.
- The half-immersed camera transition does not yet produce a clean, readable
  split between above-water and underwater views.
- Several docs describe old assumptions, old ownership, or intermediate
  experiments as if they were current truth.

The target is not another visual patch. The target is a stable architecture for
waterline, underwater optics, and shallow/deep water continuity in Godot 4.6.

## Non-Negotiable Research Rule

Do not trust former docs as authority. `docs/systems/`, old plans, comments in
shader files, and previous session notes are evidence only. Some are obsolete.
Some describe experiments that should not survive.

Before implementing each phase below, the implementer must do fresh research:

1. Find the industry-standard way to solve that specific problem. Check Unreal,
   Unity/HDRP, Source/id/AAA talks, GPU Gems, SIGGRAPH/GDC material, or other
   serious rendering references.
2. Find the best Godot 4.6 way to express that pattern. Check official Godot
   4.6 docs first, and for renderer/API details check official Godot source or
   issue history when needed.
3. Write down the chosen pattern in the implementation notes before touching
   code. If Godot cannot express the industry pattern directly, document the
   Godot-specific adaptation and the trade-off.

If fresh research contradicts this plan, update the plan. Do not force the code
to follow stale text.

## Target Architecture

### Ownership

- `OceanManager` / `WaterSurfaceState` is the single water contract.
- The opaque FFT ocean surface owns visible surface geometry, surface color,
  foam, reflections, and depth/thickness against opaque scene depth.
- A dedicated waterline / underwater compositor owns:
  - the half-immersed camera split;
  - submerged-object refraction;
  - Snell's window / underwater ceiling;
  - underwater fog, absorption, and backscatter;
  - underwater rays;
  - underwater wobble;
  - receiver caustics;
  - suspended particles.
- `UnderwaterVolume` was deleted on 2026-05-11. Do not reintroduce a
  diagnostic spatial-volume renderer as a fallback for production underwater
  work.
- Dead legacy underwater compositor / quad paths must stay deleted or clearly
  quarantined so nobody patches the wrong system.

### Buffers

The compositor must distinguish these concepts explicitly:

- Main color/depth after the normal scene render.
- Receiver-only pre-water color/depth for opt-in objects that need waterline
  refraction.
- Above-water / sky color source for Snell-window transmission.
- Water body coverage / mask data.
- Dynamic water surface height and normal.

Do not reuse the receiver-only buffer as the Snell window's sky/above-water
source unless fresh research proves that is correct. It probably is not.

### Units

All constants must be Godotwind meters and Y-up. Rafael/OpenMW/DIVE references
are Z-up and use OpenMW/Morrowind-scale distances. Every imported constant must
be converted or discarded. No magic value survives merely because it came from
OpenMW.

## Acceptance Criteria

The feature is done only when all of these are true:

- A camera crossing the water surface shows a stable, neat split between above
  water and underwater, including a readable waterline/meniscus band.
- Snell's window is stable at shallow water depths of a few meters, not only in
  deep water.
- Rays remain stable in shallow water, fade naturally when the water column is
  too thin, and do not flicker or draw disconnected screen-space streaks.
- Wobble is visible, world-anchored, scale-aware, and not camera-locked.
- Caustics and fog use the same water-surface and water-body classification as
  the waterline.
- Ocean Lab and `scenes/Godotwind.tscn` both use the same production path.
- The old/dead paths cannot be accidentally enabled in production.
- Shader cache/import verification was done for every shader edit.

## Phase 0 - Research And Ground Truth

Goal: stop building on stale assumptions.

Tasks:

- [x] Re-audit current files and mark each water/underwater path as production,
  diagnostic, dead, or reference.
- [x] Research the industry pattern for underwater camera transitions, Snell
  window, waterline masks, rays, and caustics.
- [x] Research the Godot 4.6 renderer constraints for `CompositorEffect`,
  `DEPTH_TEXTURE` / reverse-Z, screen textures and transparent materials,
  SubViewport capture timing, and RD compute barriers.
- [x] Write `docs/audit/ocean_underwater_architecture_2026_05_09.md` with
  citations and the selected canonical architecture.

Verification:

- [x] Static only. This phase produced design documentation, not rendering
  changes.

## Phase 1 - Cleanup Ownership

Goal: one production path.

Tasks:

- [x] Delete or quarantine legacy underwater compute/quad files and
  `OceanManager` hooks that can revive them.
- [x] Rename comments/docs that call diagnostic volume behavior "production"
  when the compositor is the production owner.
- [ ] Make the production path explicit in main-scene wiring. Ocean Lab is
  explicit; `scenes/Godotwind.tscn` still needs Phase 7 integration work.
- [x] Confirm `WaterSurfaceState` remains the only shared API for water height,
  water body coverage, optical constants, and wave readiness.

Verification:

- [x] Run a timed crash smoke that opens Ocean Lab and the main scene.
- [x] Confirm no legacy underwater effect file/API remains loadable or toggled.
- [ ] Run the later interactive main-scene ocean-enabled visual check in Phase 7.

## Phase 2 - Shared Water Surface And Mask Contract

Goal: remove shallow-water classification drift.

Implementation notes:

- Fresh research confirms the canonical split from Phase 0: water-body state
  owns the surface/mask contract, and post/compositor passes consume that
  contract instead of inferring water presence from the visible mesh footprint.
- Godot 4.6 visual shaders can share surface code with `.gdshaderinc`
  `#include`; imported `RDShaderFile` GLSL compute shaders remain a separate
  resource path, so the compositor uses a mirrored contract block with the same
  names and uniforms rather than depending on unsupported shader-language
  includes.
- Phase 2 should not change the optical models yet. It only makes surface
  height, water-body coverage, water depth, and diagnostic masks share one
  classification vocabulary.
- 2026-05-09 follow-up: shore mask v4 separates water-body membership from
  shore/wave dampening. `shore_mask.r` remains the dampening ramp; alpha now
  encodes land-vs-water plus water-side raw distance, and compositor/CPU
  coverage gates use alpha-derived body coverage.

Tasks:

- [x] Promote a single water-surface lookup used by surface shader, waterline
  compositor, wetness, caustics, and rays.
- [x] Replace hand-copied `.gdshaderinc` / `.glsl` surface math with a generated
  shared snippet or another verified Godot 4.6-compatible sharing path.
- [x] Add or derive a stable water coverage/body mask that does not depend on
  the finite square ocean mesh depth footprint.
- [x] Split shore dampening from body coverage so shoreline wave fade cannot
  create receiver/ray mask bands.
- [x] Add debug views for camera water depth, receiver water depth, ray water
  entry/exit, water body coverage, and final waterline mask.

Verification:

- [x] Cleared `waterline_probe.glsl` imported shader artifacts and
  `.godot/shader_cache/`, then forced `--import`.
- [x] Timed crash smoke opened Ocean Lab and `scenes/Godotwind.tscn`.
- [ ] Interactive stability while crossing the surface, walking in shallow
  water, and moving outside the ocean mesh square footprint remains for the
  Phase 7/8 visual pass.

## Phase 3 - Half-Immersed Camera Split

Goal: produce the missing clean above/below waterline.

Implementation notes:

- Fresh research reconfirmed the Phase 0/ADR direction: Unreal and Unity HDRP
  bind underwater behavior to water-body state/volumes, while Crest documents a
  camera-lens meniscus and pixel-perfect post-process path for seamless
  above/below transitions. The Godot 4.6 fit remains a `POST_TRANSPARENT`
  `CompositorEffect` using resolved color/depth, reverse-Z depth reconstruction,
  and an imported GLSL compute shader.
- The Godotwind adaptation keeps `WaterSurfaceState` / mirrored
  `WaterSurfaceContractSample` as the only water surface and mask contract. No
  deleted legacy underwater compositor, quad script, or standalone underwater
  shader path was revived.
- The half-immersed split is now evaluated per pixel from the camera ray against
  the dynamic water surface near the camera lens. This produces a spatial mask
  for the underwater camera combine instead of flooding the whole viewport from
  camera Y alone. The meniscus band is derived from the same lens/surface depth
  and water-body gate.

Tasks:

- [x] Treat the waterline as a per-pixel classification problem: camera ray vs
  dynamic water surface, not just camera Y vs sea level.
- [x] Build a stable split mask from the ray/surface intersection and water body
  coverage.
- [x] Add a meniscus/waterline band that is art-directed but derived from real
  waterline geometry.
- [x] Keep above-water and underwater color paths separate until the final
  combine.
- [x] Add temporal smoothing only after the spatial mask is correct. No temporal
  smoothing was added in Phase 3 because the spatial mask now owns the split.

Verification:

- [x] Cleared `waterline_probe.glsl` imported shader artifacts and
  `.godot/shader_cache/`, then forced `--import`.
- [x] Timed crash smoke opened Ocean Lab with the active waterline compositor.
- [x] Timed crash smoke opened `scenes/Godotwind.tscn`.
- [x] Launched `scenes/Godotwind.tscn` interactively for the required human
  visual check.
- [ ] In Ocean Lab, hold the camera half above/half below water and rotate
  slowly. The split should stay coherent.
- [ ] Repeat in `scenes/Godotwind.tscn` near a real shore or shallow area.

## Phase 4 - Snell's Window Rebuild

Goal: make Snell's window physically grounded and shallow-water stable.

2026-05-09 follow-up: the compositor no longer uses a binary
`water_ray_hit ? surface_dist : scene_dist` underwater path-length branch. Water
path now blends toward the short surface path by the smooth Snell/Fresnel
transmission weight, which removes the hard underwater ceiling seam while the
full Phase 4 sky/source rebuild remains open.

Tasks:

- [ ] Research water-to-air refraction, critical angle, Fresnel, and total
  internal reflection as used in real-time underwater rendering.
- [ ] Replace the hard binary `step()` window with a smooth, anti-aliased
  angular transition.
- [ ] Use the correct color source for transmitted above-water/sky content.
- [ ] Use dynamic surface normals from the same water-surface contract.
- [ ] Scale blur/distortion by view angle, surface roughness, and water-column
  thickness in meters.
- [ ] Make shallow water an explicit tuning case, not an accidental byproduct
  of deep-water fog.

Verification:

- [ ] Snell window must be visible and stable with 1m, 3m, 8m, and deep water
  columns.
- [ ] It must not pop when waves pass over the camera.

## Phase 5 - Wobble Rebuild

Goal: visible, world-anchored underwater distortion.

2026-05-09 follow-up: the production compositor no longer uses screen-space
FBM as the wobble driver. It samples the FFT normal texture through
`WaterSurfaceState.normal_texture_rd` and falls back to dynamic height
finite-difference normals. Remaining Phase 5 work is strength calibration and
waterline/sky sampling guards.

Tasks:

- [ ] Research standard underwater refraction/wobble approaches in modern
  engines.
- [ ] Remove screen-space FBM as the production wobble driver unless research
  justifies it.
- [ ] Drive wobble from world-anchored water normals or dynamic surface normals.
- [ ] Express strength in meter-to-pixel terms using camera FOV/resolution/depth
  instead of arbitrary UV constants.
- [ ] Add guards for waterline crossing and sky/above-water sampling without
  killing the effect everywhere.

Verification:

- [ ] Wobble should be obvious in a "debug strong" mode and subtle but visible
  in final mode.
- [ ] Pattern must stay anchored while strafing and rotating the camera.

## Phase 6 - Rays And Caustics Rebuild

Goal: stable shallow and deep underwater lighting.

Tasks:

- [ ] Research volumetric underwater light shafts and real-time caustic receiver
  projection.
- [ ] Implement rays as a low-resolution or full-resolution compositor effect
  only if the Godot research supports the performance/quality trade-off.
- [ ] Anchor rays to sun direction, dynamic surface entry points, and water-body
  coverage.
- [ ] Separate ray visibility from caustic visibility. Thin shallow water should
  not use the same gates as deep open water.
- [ ] Make caustic scale depend on wave normal/variance/dominant wavelength
  rather than fixed texture scale.
- [x] Remove the old `UnderwaterVolume` caustic branch so compositor caustics
  are the only production caustics path.
- [x] Delete the remaining diagnostic `UnderwaterVolume` wrapper, shader, test
  scene, and Ocean Lab controls on 2026-05-11.

Verification:

- [ ] Shallow water rays should fade out or become subtle instead of glitching.
- [ ] Deep water rays should remain readable and stable during camera motion.
- [ ] Caustics should not draw on dry/above-water receivers.
- [x] Ocean Lab caustics toggle controls the compositor path only.

## Phase 7 - Main Scene Integration

Goal: Ocean Lab and Godotwind use the same real path.

Tasks:

- [ ] Wire prewater capture and waterline compositor into `scenes/Godotwind.tscn`
  or the production scene bootstrap.
- [ ] Remove lab-only assumptions from production code.
- [ ] Ensure render layers for receivers, ocean, spray, terrain, and UI are
  documented and enforced.
- [ ] Confirm weather/time-of-day optical constants flow through
  `WaterSurfaceState`.

Verification:

- [ ] Launch `scenes/Godotwind.tscn` interactively.
- [ ] Verify water crossing, shallow shore, deep water, and ocean-on/off
  toggles.

## Phase 8 - Performance And Quality Gate

Goal: keep the effect shippable.

Tasks:

- [ ] Measure GPU time for prewater capture, waterline compositor, rays, and
  caustics separately.
- [ ] Add quality tiers that disable expensive pieces cleanly.
- [ ] Keep the debug modes but ensure final mode has no diagnostic colors or
  proof-only gates.
- [ ] Update `docs/systems/ocean.md`, `docs/systems/underwater.md`, and
  `docs/STATUS.md` only after visual verification.

Verification:

- [ ] Shader cache/import artifacts cleared for any `.glsl`, `.gdshader`, or
  `.gdshaderinc` edits.
- [ ] `dotnet build Godotwind.sln` if any C# changes.
- [ ] Ocean Lab interactive verification.
- [ ] `scenes/Godotwind.tscn` interactive verification.
- [ ] Benchmark/crash smoke for any changed automated path.

## Reviewer Checkpoints

Use reviewers only at the two project-approved points:

- Plan review after Phase 0 research and before implementation.
- Implementation review after the first complete production slice.

Do not ask reviewers to bless every tuning constant mid-flight.
