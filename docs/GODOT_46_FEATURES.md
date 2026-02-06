# Godot 4.6 Features Used in Godotwind

**Godot Version:** 4.6 (released January 2026)

---

## Rendering Enhancements (4.5+)

**Forward+ and Mobile Renderer Improvements:**
- **Specular occlusion** rework (ambient-based, cheaper option available)
- **Motion vectors in Mobile renderer** (previously Forward+ only)
- **Explicit FP16 usage** for Mobile renderer optimization
- **Stencil buffer support** (all backends) - useful for portals/selections
- **SMAA support** and **bent normal maps**
- **Fragment density maps** for Mobile renderer

**LOD & Culling:**
- **Mesh LOD system** with `visibility_range_begin/end/fade_mode`
- **Automatic LOD crossfading** (FADE_SELF, FADE_DEPENDENCIES)
- **Occlusion culling** (best for interiors, limited benefit outdoors)
- **Improved LOD generation** (4.6) - component pruning better preserves multi-part mesh shapes

**What Godot 4.6 Does NOT Have (We Implement Ourselves):**
- No built-in impostor system - we use custom octahedral impostors
- No automatic texture atlasing - we manage this manually

## Rendering Enhancements (4.6)

**Screen Space Reflections (SSR) Overhaul:**
- **Complete SSR rebuild** with Hi-Z tracing, better roughness handling and visual stability
- **Dual resolution modes** - full-res (quality) and half-res (2x performance)
- **Automatic quality improvement** - existing `env.ssr_*` properties still work, quality improves without code changes

**Reflection Probes:**
- **Octahedral maps** replace cubemaps for reflection/radiance probes (cheaper GPU cost, less memory)

**Other 4.6 Rendering:**
- **Glow** now processed before tonemapping with Screen as default blend mode
- **AgX tonemapper** gains `agx_white` and `agx_contrast` parameters
- **Texture import** ~50% faster via GPU RGB-to-RGBA conversion during Betsy compression
- **D3D12** is now the default backend on Windows (better driver stability)
- **Shader caching** persists across editor restarts (faster iteration)

## Physics (4.6)

- **Jolt Physics is default** - production-ready, no longer experimental
- Project configured with `3d/physics_engine="JoltPhysics3D"` in `project.godot`
- Better stability and performance for collision detection
- Handles **3-4x more active bodies** than old Bullet engine
- **Known issue:** Many overlapping `Area3D` nodes cause perf penalties even with `monitoring=false` — set `collision_mask=0` on non-monitoring areas

## IK System (4.6)

> **Status:** API documented below, but **not actively used in production** yet. The ik_controller.gd file exists but IK is not integrated into the main character system.

**New modular IK framework replacing SkeletonIK3D:**
- **IKModifier3D** - base class for all IK solvers (extends SkeletonModifier3D)
- **TwoBoneIK3D** - deterministic solver for limbs (arms, legs)
- **SplineIK3D** - for curves (tails, tentacles, spines)
- **FABRIK3D** - Forward And Backward Reaching IK for multi-bone chains
- **CCDIK3D** - Cyclic Coordinate Descent IK (fast, mechanical)
- **JacobianIK3D** - Jacobian transpose IK (biological motion)

**TwoBoneIK3D API (settings-indexed):**
```gdscript
var ik := TwoBoneIK3D.new()
ik.set_setting_count(1)
ik.set_root_bone_name(0, "UpperLeg")      # Root bone (hip)
ik.set_middle_bone_name(0, "LowerLeg")    # Mid bone (knee) — required
ik.set_end_bone_name(0, "Foot")           # End bone (foot)
ik.set_target_node(0, path_to_target)     # Target Node3D
# Optional: ik.set_pole_node(0, path_to_pole)  # Pole target for joint direction
# No start()/stop() — auto-solves as SkeletonModifier3D
# Use ik.active = true/false to enable/disable
```

**Key differences from SkeletonIK3D:**
- No `start()` / `stop()` — IK evaluation is automatic during skeleton update
- No `root_bone` / `tip_bone` properties — replaced by indexed setters
- `active` property (from SkeletonModifier3D) replaces start/stop
- Middle bone (knee/elbow) is now explicitly specified
- Pole targets for joint direction control

## Animation System

**AnimationTree Features:**
- **State machines** (`AnimationNodeStateMachine`)
- **BlendSpace1D/2D** with automatic triangulation
- **Animation retargeting** via `SkeletonProfileHumanoid`
- **BoneMap auto-mapping** for common skeleton names

## Threading & Performance

**Worker Thread API:**
- `WorkerThreadPool.add_task()` for async operations
- `ResourceLoader.load_threaded_request()` for async resource loading
- `Mutex` for cross-thread synchronization
- **Must call `wait_for_task_completion()`** for every submitted task (memory leak otherwise)

## Shader & Compute

**Shader Capabilities:**
- **Ubershaders** (4.4+) eliminate first-frame stutter with runtime specialization
- **Shader baker** pre-compiles shaders during export (reduces stutter)
- **Compute shaders** for ocean FFT, terrain generation
- **Custom material properties** for FPS-style first-person objects
- **`sampler2DArray`** for texture atlasing (impostor batching)
- **Pipeline precompilation** detects needed pipelines at load time

## Debugging & Profiling (4.6)

- **ObjectDB snapshots** - capture live object lists and diff to detect memory leaks
- **C++ tracing profilers** - Tracy, Perfetto, and Instruments integration for deep profiling
- **GDScript Tracy support** — profile GDScript function calls natively
- **Speed controls during testing** - slow down/accelerate running games for inspection
- **Pipeline monitors** — track shader pipeline creation counts

## Accessibility (4.5+)

- **Screen reader support** via AccessKit (Control nodes, Project Manager)
- Not currently used in this project (world explorer tool, not end-user game)

## Unique Node IDs (4.6)

- Nodes now have **unique internal IDs** that persist across scene tree restructuring
- Reorganize hierarchy without breaking signal connections or references
- Re-save all scenes via Project > Tools > Upgrade Project Files to benefit
