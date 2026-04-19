# C# Instantiate Bridge — Scope Analysis 2026-04-19

**Status:** CANCELLED 2026-04-19. User locked terminal architecture (`statics_no_node3d.md`). C# bridge overlaps ~80% with that plan — shipping it would be duplicate engineering with worse architectural outcome (per @roaster chat 2026-04-19 msg 1756 + @coder scope verdict §4). Kept for historical context — DO NOT IMPLEMENT.

**Prior status:** SCOPE-ONLY v1, 2026-04-19. NOT a commitment to implement.
**Parent:** `near_tier_refactor.md` §S.6 + `lazy_jolt_activation.md`

**TL;DR:** the C# bridge is a real option BUT overlaps ~80% with the terminal "no Node3D for statics" architecture. If we commit to terminal, C# bridge is dead work. If we stay with Node3D-per-static, C# bridge is the right perf play. Verdict: **scope it, don't ship it yet; blocked on terminal-vs-lazy-Jolt direction lock.**

---

## 1. What "C# instantiate bridge" means (and what it doesn't)

What it means concretely:

```csharp
// Hypothetical API:
public partial class NativeInstantiator : RefCounted {
    public Node3D InstantiateStaticRef(
        string resPath,
        Transform3D xf,
        StringName refId,
        int refNum,
        bool enableCollision   // within NEAR_END ring
    );
    public Node3D[] InstantiateBatch(
        string[] resPaths,
        Transform3D[] xfs,
        StringName[] refIds,
        int[] refNums,
        bool[] enableCollision
    );
}
```

GDScript (cell_manager.process_async_instantiation) calls the batch method; the C# side handles the hot loop without Variant marshalling.

### What the bridge CANNOT do (hard limits from Godot C++)

1. **`PackedScene.Instantiate()` is engine C++ main-thread-only.** C# calling it takes the SAME wall-clock time as GDScript calling it. The C# code is NOT faster at deserializing the packed binary — the engine does that regardless of caller.
2. **`add_child` triggers scene-tree notifications (ENTER_TREE, NOTIFICATION_READY) on main thread.** C# can't short-circuit these.
3. **Jolt broadphase registration** fires in `_notification(NOTIFICATION_ENTER_TREE)` for `CollisionObject3D`. C# can't bypass.
4. **Worker-thread instantiate is forbidden** per CLAUDE.md anti-pattern #12 — `PackedScene.Instantiate()` must be main thread.

### What the bridge CAN save

1. **Variant marshalling on property sets.** `node.position = xf.origin`, `node.set_meta("form_id", ...)`, etc. — each GDScript→engine call costs ~200-500 ns for the Variant boxing. Call from C# drops to ~50-100 ns. For ~10 property sets per object × 50 objects/frame = 5000 Variant hits → savings ~1-2 ms/frame.
2. **Reference-counted cache lookups.** Dictionary lookups on model paths, shape library, metadata registry — batched in C# with pre-computed hashes.
3. **Batch API amortization.** Single GDScript→C# call with array input beats 50 individual calls. Saves binding overhead (~5-10 µs/frame).
4. **Bypass PackedScene entirely (BIG WIN if implemented).** Store prebaked assets as raw `ArrayMesh` RID + `Shape3D` sidecar. C# builds `MeshInstance3D + StaticBody3D + CollisionShape3D` manually, skipping `PackedScene.Instantiate()`'s generic deserialization. Could save 30-50% of per-object cost.

Savings upper bound if we do ALL FOUR: ~40% reduction in `inst:` time. `60ms → 36ms`. Helpful but not 240 FPS.

---

## 2. Why this overlaps with terminal architecture

The terminal "no Node3D for statics" plan (`statics_no_node3d.md`, to be written) is approved direction in chat. Its wins:

- `RS.instance_create2` instead of `PackedScene.Instantiate()` → skips the PackedScene deserialization entirely for statics
- No StaticBody3D + CollisionShape3D per rock → one merged cell body, ~200× Jolt broadphase reduction
- No add_child cascade for statics → single RS call per prototype instance
- Metadata via side-table on the renderer, not Node3D.meta

**The C# bridge's "bypass PackedScene" win is what terminal already does by definition.** If we ship terminal, items 1-4 from §1.2 are either redundant (1, 2, 3) or superseded (4).

If we stay with Node3D-per-static + lazy-Jolt instead of terminal:
- C# bridge delivers a real ~40% `inst:` reduction on top of lazy-Jolt's Jolt-side savings
- Combined lazy-Jolt + C# bridge = maybe 120 FPS mid-movement (still not 240 FPS target)

---

## 3. Honest effort estimate

Scope A — "thin C# bridge, still uses PackedScene.Instantiate":
- `NativeInstantiator.cs`: ~300 LOC (property setters, metadata, batch API)
- Factory wiring in `NativeFactory.cs`: ~20 LOC
- GDScript shim in `reference_instantiator.gd`: ~50 LOC (call bridge vs fallback path)
- Test scene `test_csharp_instantiate_bridge.tscn`: ~100 LOC
- Total: ~470 LOC, ~1 day engineering
- Payoff: ~15-20% `inst:` reduction (Variant marshalling + batch)

Scope B — "full C# bridge, bypass PackedScene":
- Scope A + raw mesh/shape storage format: ~200 LOC
- Prebake changes (emit raw-data sidecars): ~300 LOC in `model_prebaker.gd`
- Cache rebuild required (all ~4884 `.res` files): one-time user action
- Total: ~970 LOC, ~2 days engineering
- Payoff: ~40% `inst:` reduction — but we've largely done the terminal arch by this point

**Scope B effort ≈ terminal effort with WORSE architectural outcome** (statics still have Node3D + StaticBody3D per rock; only spawn is faster).

---

## 4. Verdict

**If direction locks on TERMINAL (Node3D-less statics):** do NOT ship the C# bridge for statics. Statics don't exist as Node3Ds anyway post-terminal. The bridge could still be applied to interactive refs (doors, carryables, actors) but the payoff is ~100 µs/frame (tiny — those are <5% of spawns).

**If direction locks on LAZY-JOLT (Node3D stays, physics deferred):** ship Scope A (~1 day, ~15-20% inst: reduction). Skip Scope B — its architecture is worse than terminal for the same effort.

**Open question for @user:** do you want Scope A drafted anyway as insurance / measurement? It's a clean self-contained module; even if terminal lands, the batch-property-set pattern is reusable for NPC / character spawn paths.

---

## 5. Recommended next step

Blocked on @user direction lock for terminal-vs-lazy-Jolt (per chat 2026-04-19). If terminal wins: close this doc as "not shipped, see rationale §2." If lazy-Jolt wins: promote Scope A to primary plan, ~1 day implementation.

No code written until the direction locks. Writing speculative C# binding now risks becoming dead weight if terminal wins.
