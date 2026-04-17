# Phase 3 Handoff — for next agent 2026-04-17

Copy the prompt in §1 into a fresh Claude Code session on this repo. Everything else in this file is supporting context retained for persistence.

---

## 1. Prompt (copy this verbatim)

```
You are continuing a multi-session distant rendering refactor in the Godotwind Godot 4.6 project. A previous agent did the audit, wrote the plan, shipped phases 1 / 2 / 7 / phase-3-step-1, and cleared context. Your job is to pick up at Phase 3 Step 2.

Branch: perf/distant-rendering-2026-04-17 (off refactor/lod-b-wide). Do not touch master. Last commit: 817a81b "docs(plan): phase 3 step 1 complete".

Read in this order, no skimming:
1. .claude/CLAUDE.md — especially "Industry Standard Never Kludge", "Simplicity Over Over-Engineering", "Reviewer Engagement Scope" principles.
2. docs/audit/DISTANT_RENDERING_AUDIT_2026_04_17.md — problem map.
3. docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md — §2 ground rules (non-negotiable), §3 phase list, §4 measurement log. Phase 3 is IN_PROGRESS step 1/8.
4. docs/audit/PHASE_3_MID_MULTIMESH_DESIGN.md — full design spec for what you're implementing. §1.1 scope (OpenMW pattern, locked by user), §5 cull strategy, §13 implementation sequence.
5. src/core/world/prototype_batch.gd + prototype_registry.gd + tests/unit/test_prototype_registry.gd — what step 1 shipped.
6. src/core/world/static_object_renderer.gd — the 1000-line file you'll be modifying in step 2.
7. src/core/world/cell_manager.gd:2074-2092 around `_finalize_request` — where `batch_cell_into_multimesh` is wired.

Ground rules locked by user 2026-04-17:
- Only code + runtime data from launching the scene are ground truth. Docs and commit messages can lie. Verify before acting.
- User's measured baseline: cold ~14 FPS for 1-2 min, then steady ~50 FPS. MID is the dominant cost. Crashes frequent but specific class (Tween lambda) was killed in phase 2.
- "Keep it simple" (user 2026-04-17): HLOD-on = full pipeline, HLOD-off = only NEAR renders past 150m. No middle ground. Don't rebuild options that were explicitly scoped out.
- Goal is FPS when everything is correctly implemented, not short-term wins. Don't chase quick fixes. Don't disable in-progress code without asking.
- DO launch scenes/Godotwind.tscn via `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --headless --quit-after 20` after edits to parse-check and watch for errors. Pre-existing shutdown Signal 11 is not from your changes.
- Commit often. Branch isolated. User wants incremental commits not monolithic ones.
- Run tests via `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/run_tests.tscn`. The 9 failures in test_object_paging_kernel.gd are pre-existing — leave them.
- C# is 20-50× GDScript for hot loops. Use it when appropriate (step 5 of the design). Bridge pattern in src/core/native_bridge.gd.
- Use the agentchattr MCP chat (channel: general, sender: claude) for status updates. User may address you as @claude-1 in multi-instance sessions. Read any pending messages on connect.

Your next action:
Implement Phase 3 Step 2 per docs/audit/PHASE_3_MID_MULTIMESH_DESIGN.md §13: wire static_object_renderer.add_instance (and add_multi_sub_mesh_instance if it exists) to route through the new PrototypeRegistry behind a feature flag. Coexist with the existing per-cell path — don't delete anything yet. Verify both paths render the scene correctly with the flag toggle.

Before writing code, post in chat confirming you've read the docs and summarize your plan for step 2 in under 150 words. Await user ack before the first edit.
```

---

## 2. Session summary for the next agent

**Shipped this session (commits on `perf/distant-rendering-2026-04-17`):**

| SHA | Phase | Description |
|---|---|---|
| `1ae6953` | Audit + plan | Audit doc + cross-session work plan |
| `4641010` | Phase 1 | Delete dead GPUSceneDatabase SSBO fill path |
| `3ade1f3` | Phase 1 | Gate LightAnimator per-tick loop on `is_visible_in_tree()` |
| `52beb34` | Phase 2 | Replace per-object Tween fade with shader-driven `TIME - spawn_time` fade; SceneTreeTimer for material restoration. Closes "Lambda capture was freed" crash class. |
| `4a5d8dc` | Phase 7 partial | Cold-start instantiation budget 15→25 ms. Post-startup 4 ms left intact (death-spiral guard per `streaming_config.gd:116-120`). |
| `8d1a135` | Plan update | P1/P2/P7 status + verification notes |
| `04d5b93` | Phase 3 design | Initial design draft |
| `dce7629` | Phase 3 design v2 | Rewrite after user's "OpenMW scope" call — MID narrowed to 150-300 m, γ-band LOD dropped, HLOD becomes load-bearing |
| `89780df` | Phase 3 step 1 | `prototype_batch.gd` + `prototype_registry.gd` + 10-test unit suite (all pass) |
| `817a81b` | Plan update | Phase 3 step 1 DONE |

**Known pre-existing issues, NOT caused this session:**
- Shutdown Signal 11 crash when closing the scene. Fires after init succeeds.
- 9 test failures in `test_object_paging_kernel.gd`.

**Audit corrections found at runtime (ignore the audit on these):**
- `sky_manager.gd:276` already sets `directional_shadow_max_distance = 200.0`. Audit §5.7 was wrong.
- `cell_manager.gd:2085-2090` contains a prior-session comment claiming `batch_cell_into_multimesh` regressed FPS 15-20. Uncorroborated — user wants to leave it ON until Phase 3 replaces it cleanly, not chase short-term wins.

**Reviewer pass recorded:**
- `@roaster` 2026-04-17 on the Phase 3 v1 design: flagged LOD blocker at horizon under HLOD-off; user dissolved the blocker by scope-cutting in §1.1. Other guidance (C# marshalling layout, verify `multimesh_set_visible_instances` API, use known-good buffer layout from `native_impostor_renderer.gd:1757-1826`) is folded into design v2 §13 pre-step.

**User's 4 design questions, answered in design v2:**
1. β (CPU cull + C#) — selected. γ dropped (scope made it unnecessary).
2. Buildings batched per sub-mesh — yes.
3. C# for the cull loop — yes, with `PackedFloat32Array` marshalling, not `Plane[]`.
4. Sequence — §13, 8 steps. Step 1 done. Step 2 next.

**Branch state summary:**

```
perf/distant-rendering-2026-04-17
  ↑ 10 commits
refactor/lod-b-wide (parent)
  ↑ N commits  
master
```

Fully revertable. No master changes.
