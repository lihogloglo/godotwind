# Phase 3 Handoff V2 — for next agent 2026-04-17 (evening)

Copy the prompt in §1 into a fresh Claude Code session on this repo. Everything else in this file is supporting context retained for persistence.

---

## 1. Prompt (copy verbatim)

```
You are continuing a multi-session distant rendering refactor in the Godotwind Godot 4.6 project. The prior agent (this session) shipped Phase 3 code-complete: steps 1-7 of the design doc, 12 commits on the branch. Your job is to RUNTIME-VERIFY Phase 3 (the user's A/B pass) and, if verified, advance to Phase 4.

Branch: perf/distant-rendering-2026-04-17 (off refactor/lod-b-wide). Do not touch master. Last commit: 5dda7a0 "refactor(phase3): delete legacy per-cell batcher — registry is the only MID path".

Read in this order, no skimming:
1. .claude/CLAUDE.md — "Industry Standard Never Kludge", "Simplicity Over Over-Engineering", "Reviewer Engagement Scope" principles. Non-negotiable.
2. docs/audit/DISTANT_RENDERING_AUDIT_2026_04_17.md — full problem map.
3. docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md — §2 ground rules (non-negotiable), §3 phases, §4 measurement log (populated through Phase 3), §5 design decisions log (two entries from prior session), §8 status snapshot.
4. docs/audit/PHASE_3_MID_MULTIMESH_DESIGN.md — full spec. §1.1 OpenMW scope, §2.5 HLOD integration, §5 cull strategy, §13 implementation sequence (all 7 steps ✅).
5. src/core/world/prototype_batch.gd — 350 lines. Owns slot_transforms + slot_custom_data PackedFloat32Array storage. cull_and_upload has both a GDScript loop and a native_culler branch. FADE_SHADER preload + _build_fade_material helper.
6. src/core/world/prototype_registry.gd — 280 lines. get_or_create_batch + add/remove/hide/show/set_transform instance APIs. tick_cull_if_needed gated on dirty flag OR camera-moved ≥10m. Lazily instantiates WorldMidCuller via NativeBridge on first tick.
7. src/native/WorldMidCuller.cs — C# cull kernel. CullAndPack(slot_live, slot_transforms, slot_custom_data, cam_pos, max_dist_sq, slot_capacity) returns {visible: int, buffer: float[]}. JIT-friendly, AggressiveOptimization attribute, Array.Copy hot path.
8. src/core/world/static_object_renderer.gd — post step-7 cleanup, ~870 lines. Registry is the only MID path for prototypes with sub_meshes; register_mesh_type direct path kept as fallback (tests / debug tools). No flag, no CellBatch.
9. src/core/world/shaders/lod_crossfade_multimesh.gdshader — spawn_time fade via INSTANCE_CUSTOM.x/.y; matches Phase 2's lod_crossfade.gdshader formula per-slot.
10. src/core/world/cell_manager.gd:2075-2083 — _finalize_request simplified (no more batch_cell_into_multimesh).
11. src/core/world/native_streaming_manager.gd:680-689 — tick_prototype_cull hook, runs every frame unconditionally, registry no-ops internally when uninstantiated.
12. tests/unit/test_prototype_registry.gd — 10 tests covering slot lifecycle + registry dedup + multi-sub-mesh add + idempotent remove + batch_key stability. All pass.

Ground rules locked by user 2026-04-17:
- Only code + runtime data from launching the scene are ground truth. Docs and commit messages can lie. Verify before acting.
- User's measured baseline (verbal, pre-session): cold ~14 FPS for 1-2 min, then steady ~50 FPS. MID is the dominant cost.
- "Keep it simple" (user 2026-04-17): HLOD-on = full pipeline, HLOD-off = only NEAR renders past 150m. No middle ground.
- Goal is FPS when everything is correctly implemented, not short-term wins. Don't chase quick fixes. Don't disable in-progress code without asking.
- DO launch scenes/Godotwind.tscn via `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --headless --quit-after 20` after edits to parse-check and watch for errors. Pre-existing shutdown Signal 11 is not from Phase 3 changes — same failure mode was present pre-session.
- Commit often. Branch isolated. User wants incremental commits not monolithic ones.
- Run tests via `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/run_tests.tscn`. Expect 114 total, 9 pre-existing failures in test_object_paging_kernel.gd — leave them.
- C# is 20-50× GDScript for hot loops. WorldMidCuller.cs already written. If you modify C# you MUST `dotnet build Godotwind.sln` from project root — user will not rebuild.
- Shader cache: if you modify any .gdshader, `rm -rf .godot/shader_cache` before testing. User will not clear it.
- Use the agentchattr MCP chat (channel: general, sender: claude) for status updates. User may address you as @claude-1 in multi-instance sessions. Read any pending messages on connect.

Your next actions in order:

A. RUNTIME VERIFY Phase 3 (user hasn't tested yet — this is the gate before moving on).
   1. Launch scenes/Godotwind.tscn in Godot editor at Play. DO NOT use --auto-capture or any scripted harness — user memory forbids it (feedback_never_launch_main_game_unprompted + similar). Interactive launch only; let the user fly the camera.
   2. Ask user for permission BEFORE launching the main scene — per feedback_never_launch_main_game_unprompted ("Never launch main game unprompted"). Post in chat requesting green-light first.
   3. Once greenlit: from the console (`` ` ``), run `hud` for live overlay, `proto_registry` for registry stats, `bench` for the 85s scripted flyby.
   4. Compare against pre-session baseline (commit c207f1c, user-reported ~14 FPS cold / ~50 FPS steady).
   5. Record results in DISTANT_RENDERING_PLAN_2026_04_17.md §4.N (new sub-section "Phase 3 verify 2026-04-??"). Cite commit SHA + HLOD state + segment-by-segment FPS.
   6. If FPS win is <20 FPS @ vista — investigate via profiler (Debug → Profiler → Shader Map Update / RenderingServer work). Likely suspects: marshalling overhead on C# CullAndPack calls (profile with a GDScript-path toggle — see prototype_batch.cull_and_upload signature); OR the per-tick full-buffer rebuild (step 5 implementation packs the whole slot_capacity × 16 float buffer per tick). Don't patch blindly — find the canonical perf pattern first.
   7. If FPS WIN verified: flip phase 3 status to DONE in §8 of the plan. Move to B.

B. Pick next phase per DISTANT_RENDERING_PLAN_2026_04_17.md §3:
   - Phase 4 — HLOD/MID dedup (+5-15 FPS with HLOD on; removes double-render hazard). Design decision tree in §5.1 of the audit: option A (dedup registry) vs option B (invert ownership). Phase 3 makes option B more feasible because registry.remove_instance/add_instance is cheap.
   - Phase 5 — push FAR_START 500m → 1km. Depends on phase 4. constants + ranges in distance_utils.gd.
   - Phase 6 — impostor texture-array double-buffer (removes 6-8ms hitches, not avg FPS).
   - Phase 7 — burst cold-start budget (DONE partial in prior session — commit 4a5d8dc).

Before starting Phase 4, post a plan draft in chat + wait for user ack — per the reviewer engagement rule.

Known post-step-7 open items (not blockers, flagged in the commit message):
- mid_tier_debugger.gd and lod_debug_commands.gd still iterate InstanceData.instance_rid (always RID() in registry path) — debug tools will report "0 valid RIDs" and "0 applied bias", non-fatal noise. Rewrite to iterate registry batches for the registry-owned instances.
- InstanceData.sub_rids + .instance_rid retained on the struct as legacy fallback for register_mesh_type direct callers (tests + debug tools). They're always empty/RID() under the registry path. A future rename-cascade step could strip them entirely.
- get_stats still returns mm_batches/mm_slots/mm_cells as 0 for heartbeat log + benchmark reader compatibility. Deprecate in a follow-up (update heartbeat log format first so rename doesn't break outside readers).

Commit hygiene: one commit per logical change. Use HEREDOC format. Co-Author line required.

(read PHASE_3_HANDOFF_2026_04_17_V2.md for previous session summary)
```

---

## 2. Session summary (this session, 2026-04-17 evening)

**Branch:** `perf/distant-rendering-2026-04-17`. Off `refactor/lod-b-wide`. No master changes.

**Commits shipped (12 this session, steps 2-7 of Phase 3):**

| SHA | Phase step | Description |
|---|---|---|
| `d71302c` | 3.2 | PrototypeRegistry gains set_instance_transform / hide_instance / show_instance + InstanceSlot.local_transform |
| `f5472b1` | 3.2 | StaticObjectRenderer feature-flag wiring (use_prototype_registry), InstanceData.registry_id, add/remove/visible/promoted/transform branch through registry when flag ON, cell_manager skips per-cell batch when flag ON |
| `5e2450a` | 3.2 | `proto_registry on\|off\|status` console command |
| `847fa84` | docs | Tracker update for steps 2 + design decisions log seeded |
| `93973df` | 3.3 | Pre-cull correctness (superseded by step 4 refactor but kept for git history) |
| `f3105ca` | 3.4 | GDScript cull pass — PrototypeBatch.cull_and_upload + PrototypeRegistry.tick_cull_if_needed + native_streaming_manager driver hook. Major refactor: PrototypeBatch now owns slot_transforms/custom_data PackedFloat32Array; MM buffer written only via set_buffer during cull |
| `b35cd1c` | 3.5 | C# kernel — src/native/WorldMidCuller.cs [GlobalClass] + NativeFactory.CreateWorldMidCuller + NativeBridge.create_world_mid_culler. PrototypeBatch._cull_native marshalls slot_live/slot_transforms/slot_custom_data to C#, receives {visible, buffer} back, uploads. Registry lazily instantiates culler on first tick |
| `1291655` | 3.6 | lod_crossfade_multimesh.gdshader rewritten for INSTANCE_CUSTOM.x=spawn_time / .y=fade_duration per-slot fade. PrototypeBatch.FADE_SHADER preload + _build_fade_material helper (copies albedo/roughness/metallic/specular + alpha-scissor from StandardMaterial3D). StaticObjectRenderer.REGISTRY_FADE_DURATION_S = 0.3 s, spawn_time from Time.get_ticks_msec. Shader cache cleared pre-test |
| `5dda7a0` | 3.7 | Legacy per-cell batcher DELETED — batch_cell_into_multimesh, _create_cell_batch, _hide_batch_slot, _show_batch_slot, _free_cell_batches, CellBatch inner class, _cell_batches dict, MM_BATCH_MIN_COUNT const, InstanceData.mm_slot/.batch, use_prototype_registry flag, _sub_local helper. Lifecycle methods simplified (2-way: registry_id >= 0 → registry; else → legacy sub_rids fallback for register_mesh_type). cell_manager._finalize_request trimmed. world_explorer proto_registry reduced to status-only. +70 / -434 lines. Tracker updated. |

**Test-suite state (headless run, 2026-04-17):** 114/114 pass excluding 9 pre-existing `test_object_paging_kernel.gd` failures (unrelated).

**Parse-check (headless --quit-after 20):** zero new SCRIPT ERROR / Identifier-not-found / Parse Error from this session's files. Dummy-renderer "Parameter m is null" / "Attempting to use an uninitialized RID" errors in model_loader and distant_light_manager are pre-existing (dummy renderer can't instantiate real meshes), unrelated to Phase 3. Shutdown Signal 11 is pre-existing (same as noted in prior session's handoff at `PHASE_3_HANDOFF_2026_04_17.md`).

**dotnet build:** clean, 0 errors, 25 warnings (all pre-existing on NativeESMLoader / NativeObjectPagingKernel, unrelated).

**Runtime FPS verification:** NOT YET DONE. User explicitly deferred until end of Phase 3. Verification is the first task for the next agent per the prompt in §1.

**Known open items (not blockers — noted in step-7 commit body):**
1. `mid_tier_debugger.gd:922` + `lod_debug_commands.gd:1284` iterate `InstanceData.instance_rid` — always `RID()` under registry path. Debug tools will report "0 valid RIDs" and "0 applied bias", non-fatal noise.
2. `InstanceData.sub_rids` + `.instance_rid` retained on the struct as legacy fallback for `register_mesh_type` direct callers. Could be stripped in a rename-cascade step.
3. `get_stats` still returns `mm_batches=0` / `mm_slots=0` / `mm_cells=0` for heartbeat log + benchmark reader compatibility. Deprecate in follow-up.

**Tracker docs updated in this session:**
- `DISTANT_RENDERING_PLAN_2026_04_17.md` §4.N (Phase 3 steps 2-4 measurement entry), §5 (two design decision entries — slot storage ownership + cull gate), §8 (phase 3 status DONE-code).
- `PHASE_3_MID_MULTIMESH_DESIGN.md` §13 (all 7 implementation steps marked ✅ with commit refs).

**Branch state:**

```
perf/distant-rendering-2026-04-17
  ↑ 22 commits (10 from prior + 12 from this session)
refactor/lod-b-wide (parent)
  ↑ N commits
master
```

Fully revertable. No master changes.

---

## 3. Architecture as it stands

**MID tier data flow (post step-7):**

```
ESM record + prototype Node3D
         │
         ▼
cell_manager._instantiate_mid_tier
         │
         ▼
static_object_renderer.add_instance(type_name, xform, cell_grid, ...)
         │ (sub_meshes non-empty → registry path; else → legacy RS fallback)
         ▼
PrototypeRegistry.add_instance(id, sub_meshes[], world_xform, spawn_time, 0.3)
         │
         ▼
for each sub-mesh:
   PrototypeRegistry.get_or_create_batch(mesh, material) → PrototypeBatch
   batch.acquire_slot() → slot index
   batch.set_slot_transform(slot, world * local)
   batch.set_slot_custom_data(slot, (spawn_time, fade_duration, 0, 0))
   InstanceSlot(batch, slot, local_xform) recorded in registry._instance_slots[id]
```

**Per-frame cull driver:**

```
native_streaming_manager._process (end of frame)
         │
         ▼
static_object_renderer.tick_prototype_cull(cam_pos, vr_end²)
         │
         ▼
PrototypeRegistry.tick_cull_if_needed(cam_pos, max_dist_sq)
         │ gates on _cull_dirty OR camera moved ≥ 10 m since last tick
         ▼
(first tick) NativeBridge.create_world_mid_culler → WorldMidCuller RefCounted
         │
for each PrototypeBatch:
         ▼
   batch.cull_and_upload(cam_pos, max_dist_sq, culler)
         │
         ├── culler != null → _cull_native: C# CullAndPack returns {visible, buffer}
         │                    → RenderingServer.multimesh_set_buffer(mm_rid, buffer)
         │                    → RenderingServer.multimesh_set_visible_instances(mm_rid, visible)
         │
         └── culler == null → GDScript loop (identical logic, slower)
```

**Cell unload:**

```
static_object_renderer.remove_cell_instances(grid)
         │
         ▼
for each instance_id in _cell_index[grid]:
    remove_instance(id)
         │
         ▼
    if data.registry_id >= 0:
        PrototypeRegistry.remove_instance(registry_id)
            → for each InstanceSlot: batch.release_slot(slot) → freelist
            → _cull_dirty = true
    else:
        (legacy) free per-sub-mesh RS RIDs
```

**Shader fade path:**

Per-batch fade ShaderMaterial built in `PrototypeBatch._init` when prototype material is `StandardMaterial3D`. Uses `lod_crossfade_multimesh.gdshader`. Every slot in the batch reads its own `INSTANCE_CUSTOM.x` (spawn_time) and `INSTANCE_CUSTOM.y` (fade_duration). Formula: `fade = clamp((TIME - spawn) / max(duration, 0.0001), 0, 1)`. Shader discards pixels where `dither_threshold >= fade`, matching Phase 2's `lod_crossfade.gdshader` formula.

---

## 4. Verification commands

```bash
# Run tests (expect 114, 9 pre-existing paging failures = OK):
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/run_tests.tscn

# Parse-check (headless; ignore dummy-renderer mesh errors + shutdown Signal 11):
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --headless --quit-after 20

# Rebuild C# if modified (required — user won't do this):
cd D:/Gamedev/Godotwind/godotwind && dotnet build Godotwind.sln

# Clear shader cache if modified:
rm -rf "D:/Gamedev/Godotwind/godotwind/.godot/shader_cache"

# Runtime interactive (user must drive — never auto-capture):
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe"  # opens editor at project
# Then Play the scene from the editor. Console commands:
#   hud                 → live overlay
#   proto_registry      → batch/slot counts
#   bench               → 85s scripted flyby, CSV + JSON to user://benchmark_results/
#   hlod_enable         → enable HLOD (MID narrows to 300m)
#   toggle only mid_objects + bench    → MID-isolated perf run
```

---

## 5. Reviewer engagement

Per `CLAUDE.md` §"Reviewer Engagement Scope": reviewer (@roaster etc.) engages at plan review + implementation review, NOT mid-flight. This session's plan pass happened in the prior session (roaster review on design v2 — recorded in the design doc §header). Next reviewer touchpoint: implementation review of the next phase (Phase 4) after first-draft lands.

Phase 3 implementation review was NOT formally requested this session — user wanted continuous forward progress. If reviewer pass desired post-landing, user can spawn @roaster with a "Phase 3 implementation review" prompt pointing at commits `d71302c..5dda7a0`.

---

## 6. Pre-session context (for completeness)

Prior session (earlier today) shipped Phase 3 step 1 (skeletons + tests). See `docs/audit/PHASE_3_HANDOFF_2026_04_17.md` (v1) for that summary. This v2 supersedes it for the question "what has Phase 3 done" but v1 is still authoritative for Phase 1 / 2 / 7 history (commits `1ae6953..817a81b`).
