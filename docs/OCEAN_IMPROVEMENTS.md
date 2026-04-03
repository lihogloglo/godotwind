# Ocean Improvements Plan

**Agent:** oceanfix
**Started:** 2026-04-03
**Goal:** Upgrade ocean system — opaque rendering, FFT buoyancy sync, production buoyancy physics

---

## Phase 1: Opaque Ocean Shader (GodotOceanWaves approach)
**Status:** DONE
**Files:** `src/core/water/shaders/ocean_fft.gdshader`

Fully opaque ocean — no ALPHA, no SCREEN_TEXTURE, no refraction. Color from ALBEDO + SSS lighting.
Fixes "hollow wave crests" caused by transparent rendering pipeline.

**Changes:**
- [x] Removed SCREEN_TEXTURE sampler and all refraction code
- [x] Removed ALPHA entirely — ocean stays in opaque render queue
- [x] `depth_draw_opaque` render mode (correct for opaque)
- [x] GodotOceanWaves-style Fresnel: roughness-dependent power `5.0 * exp(-2.69 * roughness)`
- [x] Roughness increases at grazing angles (hides horizon aliasing)
- [x] SPECULAR modulated by fresnel
- [x] Shore transition via color blending (lighten toward `color_shallow` near shore)
- [x] Depth buffer used ONLY for shore discard (minimal)
- [x] `v_flat_pos` (undisplaced) for depth comparison — fixes false discard at wave crests
- [x] Foam distance fade: `1.0 - smoothstep(500, 2000, dist)`
- [x] Distance-based normal flattening: `normal_y_scale = max(1.0, dist * 0.002)`
- [x] Shore mask retained in vertex for wave displacement dampening only

---

## Phase 2: GPU Readback Buoyancy
**Status:** DONE
**Files:** `src/core/water/wave_generator.gd`, `src/core/water/ocean_manager.gd`

GPU readback for exact visual-physics sync. Replaces broken hash-based CPU evaluator.

**Changes:**
- [x] `wave_generator.gd`: Added `CAN_COPY_FROM_BIT` to displacement texture + `read_displacement()` method
- [x] `ocean_manager.gd`: Reads cascade 0 displacement once per frame via `texture_get_data()`
- [x] Bilinear sampling from RGBA16F CPU data (`_sample_displacement_readback()`)
- [x] Normal via finite differences from readback
- [x] Fallback chain: GPU readback → OceanPhysicsEvaluator → GerstnerMath
- [x] Cost: 512KB readback/frame, constant regardless of query count

---

## Phase 3: Production Buoyancy Physics
**Status:** DONE
**Files:** `src/core/water/buoyancy_body.gd` (NEW), `src/core/water/buoyancy_probe.gd` (NEW)

Probe-based buoyancy using Jolt physics (standard Godot API).

**BuoyancyBody3D** (extends RigidBody3D):
- [x] Multi-point probe sampling (forces at probe positions → natural torque)
- [x] Non-linear depth response: `pow(depth, buoyancy_power)` (default 1.5)
- [x] Hydrodynamic drag: linear + angular velocity damping proportional to submersion
- [x] Distributed gravity mode for boats (mass distribution creates listing)
- [x] Configurable: buoyancy_force, buoyancy_power, fluid_density, drag coefficients

**BuoyancyProbe3D** (extends Marker3D):
- [x] Lightweight wave sampling point
- [x] Per-probe buoyancy_multiplier
- [x] Tracks depth and submersion state

---

## Phase 4: Archive Gerstner
**Status:** NOT STARTED

- [ ] Move `ocean_standard.gdshader` to `src/core/water/archive/`
- [ ] Move `gerstner_math.gd` to `src/core/water/archive/`
- [ ] `ocean_physics_evaluator.gd` kept as fallback but GPU readback is primary

---

## Architecture Decisions
- **Fully opaque ocean**: No ALPHA anywhere. Shore transition via color blend + discard. Follows GodotOceanWaves. Reflections from Godot SSR + ReflectionProbe.
- **GPU readback for buoyancy**: `texture_get_data()` on cascade 0. Exact match with visual. ManickYoj rate-limits to 10Hz; we do 60Hz since cost is acceptable on RTX 4060.
- **Jolt via standard API**: `RigidBody3D.apply_force(force, offset)` works with Jolt. Jolt's `ApplyBuoyancyImpulse` is NOT exposed to GDScript in 4.6.
- **Shore mask retained**: Vertex-stage wave dampening + CPU `is_in_ocean()` queries.
- **v_flat_pos for depth**: Undisplaced sea-level position avoids false shore detection at wave crests.
- **OceanPhysicsEvaluator kept as fallback**: Hash mismatch means it doesn't perfectly match GPU, but still useful if readback fails or is disabled.

## Future Improvements
- `texture_get_data_async()` (Godot 4.4+) for non-blocking readback
- 6-axis hydrodynamic drag model (ManickYoj's axial/lateral/vertical/yaw/pitch/roll)
- Volumetric cell mode for large ships (partial submersion based on cell volume)
- Horizontal displacement correction (iterative, from tessarakkt)
- Cascade filtering: large boats ignore small detail cascades
