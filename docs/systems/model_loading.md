# Model Loading — Canonical PackedScene Pattern

**Status:** DONE 2026-04-16. All `.duplicate()` callsites removed. Jolt broadphase deferred to NEAR tier only.

Canonical async-streaming pattern adopted from Unreal `StreamableManager` / Unity Addressables: the cache stores `PackedScene`, callers `instantiate()` on demand. No shared `Node3D` instances, no mid-load `DirAccess.remove_absolute` races, no reparent-owner hazards.

## Files

```
src/core/world/model_loader.gd           — `_model_cache: Dictionary[String, PackedScene]`, async + sync load paths
src/core/world/reference_instantiator.gd — per-ref instantiation, collision stays disabled until NEAR
src/core/world/native_streaming_manager.gd — `_process_promoted_collision_enable()` on MID→NEAR promotion
```

## Cache invariant

`_model_cache` stores **`PackedScene`**, not pre-instantiated `Node3D`. Every cell stream calls `PackedScene.instantiate()` for a fresh tree. See `model_loader.gd::_model_cache` (`model_loader.gd:45`). Callers: `reference_instantiator.gd::_instantiate_model_object` → `get_model()` returns the instantiated Node3D with collision already disabled.

## Collision invariant (load-bearing)

At instantiation time, every `CollisionShape3D` in the prefab is disabled — either via `disabled = true` or by detaching from the broadphase. Collision is re-enabled only when the object promotes into NEAR tier (< 150m), inside `native_streaming_manager.gd::_process_promoted_collision_enable()` (`native_streaming_manager.gd:1372`), called from the main streaming update at line 732.

**Why this invariant exists:** streaming bursts (initial exterior cold-boot, teleport, fast flyby across cell boundaries) instantiate hundreds of prefabs in a handful of frames. If every `CollisionShape3D` registers with Jolt's broadphase at `add_child()` time, Jolt stalls the main thread recomputing AABB hierarchies. Deferring to the NEAR tier caps the live-shape count to whatever fits inside the 150m physics radius — the rest sit cheap in the scene tree with physics off.

This is the root-cause fix for the `process_async_loads` signal-11 signature diagnosed during the 2026-04-16 model-loader-race investigation. Bridge fixes #1 (deferred instantiate queue) and #2 (`_clear_owner_recursive` on carryable reparent) landed first; the canonical PackedScene refactor removed their need.

## Related carve-outs

Carry held-body vibration saga — the held `RigidBody3D` keeps its own physics interpolation carve-out and does **not** follow the streaming-level collision-enable flow. See `docs/systems/interaction_system.md` §17.2.1 for the HL2 physics-gun solution and `carry_controller.gd` for the implementation.

## History

- 2026-04-16 model-loader-race investigation — diagnosis + canonical-pattern analysis + bridge-fix log folded into this doc.
