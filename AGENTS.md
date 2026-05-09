# Godotwind — Godot 4.6 Morrowind Framework

## Codex Session Verification Rule

For Godotwind work, do not stop at static inspection. Before calling a gameplay,
streaming, rendering, or performance change done, either:

1. Launch `scenes/Godotwind.tscn` interactively so the user can visually check it, or
2. Run an automated benchmark/crash smoke that exercises the changed path.

Use the documented local binary when available:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

If a C# file changed, run `dotnet build Godotwind.sln` before launching Godot.
If neither visual launch nor automated benchmark can be run, say exactly why in
the final response.

## Shader Import / Cache Verification Rule

When a `.glsl` compute shader or `.gdshader` / `.gdshaderinc` visual shader
changes, do not trust a normal launch to pick up the edit. Before visual
verification, clear the relevant generated shader/import cache and force
reimport/recompile:

- For imported compute shaders (`RDShaderFile`, usually `.glsl`), delete the
  matching `.godot/imported/<shader-name>-*.res` and `.md5` files, then run:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import`
- For visual `.gdshader` / `.gdshaderinc` changes, clear the relevant
  `.godot/shader_cache/` entries if the edit appears stale, then relaunch the
  test scene.
- In the final response, say whether shader cache/import artifacts were cleared
  before the visual check.

## Plain-English Work Summary Rule

Always explain in plain English what you changed and what you verified. Do not
only list file names, commands, or implementation details; include the practical
effect the user should expect to see.

Not a faithful port — "Morrowind if it was made in 2025 with modern Godot."
Best-in-class open-world rendering in Godot, using Morrowind as the data source.

**Godotwind is a generic open-world RPG framework. Morrowind is just one data source — a specific use case, not the architecture.** All game-specific logic (ESM formats, SCVR conditions, NIF quirks, MW coordinate systems) lives in translation/adapter layers. Core framework systems (`src/core/dialogue/`, `src/core/ui/`, `src/core/world/`) must be engine-agnostic — never bake Morrowind-specific data formats or conventions into them. Litmus test: could someone plug in a different game's data with only a new adapter layer, without modifying framework code?

---

## Engineering Principle — Industry Standard, Never Kludge

**We always aim for the industry-standard solution. We never ship quick fixes, kludges, or hand-rolled bridges around problems that already have a canonical answer.** If a pattern is in Unreal, Unity, Source, id Tech, Bevy, or the Godot docs themselves, that is the pattern we adopt — not a bespoke version of it. Locked by user 2026-04-08.

**Why:** every kludge is technical debt with compounding interest. A hand-rolled patch around one symptom hides the underlying clock mismatch / data flow / lifecycle issue and breeds N more patches in adjacent systems. The carry vibration story is the canonical lesson — a manual snapshot bridge in `carry_controller.gd` papered over the absence of project-wide physics interpolation, and the same root cause was waiting to surface in animation, streaming, and any other system that crossed the physics-render boundary. Fixing it the standard way (engine-side `physics_interpolation` + per-node carve-outs, the Glenn Fiedler "Fix Your Timestep" pattern that every commercial engine has used for 20 years) eliminates the entire bug class, not just the visible symptom.

**Operational rules:**
1. Before proposing a fix, identify the canonical pattern. Search the Godot docs, the major engine docs (Unreal, Unity, Source), academic / blog references (Fiedler's `gafferongames.com`, Game Programming Patterns, etc.). If a standard exists, name it in the proposal.
1a. For Godot engine/API behavior (RenderingServer, ResourceLoader, MultiMesh, PhysicsServer, threading), verify the hypothesis against the current Godot 4.6 official docs and, when relevant, the official `godotengine/godot` issue/source history before changing code. Treat project comments and inherited assumptions as secondary evidence.
1b. Do not treat existing project docs, old plans, comments, or prior agent summaries as current truth. They are evidence, not authority, and some may be obsolete or wrong. For every non-trivial rendering, gameplay, streaming, performance, or architecture change, first research (a) the industry-standard way to solve the problem and (b) the best current Godot way to implement it. If that research contradicts local docs, update or supersede the docs instead of preserving the stale assumption.
2. If no standard exists, design from first principles AND document the design decision in `docs/audit/` so the next agent inherits the rationale, not just the code.
3. Quick fixes are allowed ONLY as **explicitly time-boxed bridges to a planned proper fix**, never as the end state. Time-boxed fixes must include: (a) the symptom they paper over, (b) the canonical pattern they're standing in for, (c) the follow-up commit that removes them, (d) a dated TODO with the agent owner.
4. "It works" is not the bar. "It's the way the industry has solved this problem and the way our future selves would build it from scratch" is the bar.
5. If reviewer (`@roaster`) flags a fix as a kludge, the burden of proof is on the implementer to either justify why the canonical pattern doesn't apply here, or to redo the fix properly. We do not ship "good enough for now" architecture.

**Litmus test before any non-trivial PR:** "Would I be embarrassed if a senior engineer at id Software / Epic / Unity opened this file?" If yes, redo it.

**Examples of the principle in action:**
- Physics-render boundary → engine `physics_interpolation` + camera carve-out, NOT manual prev/current snapshot bridges
- Async loading → `WorkerThreadPool` + frame budgeting, NOT thread-naked `Thread.start()` calls or polling loops
- LOD / culling → engine `visibility_range` + RS instance API, NOT custom distance checks per-frame
- Coordinate conversion → centralized in `coordinate_system.gd`, NOT inline `Vector3(x, z, -y)` flips at every call site
- Dialogue / interaction → framework + adapter layer, NOT MW-specific code in framework files

When in doubt: read the Godot docs, find the canonical pattern, follow it. If the canonical pattern doesn't fit, escalate to user with the trade-off analysis BEFORE writing code.

---

## Engineering Principle — Simplicity Over Over-Engineering

**Agents have a strong failure mode: they over-engineer early decisions, then spend subsequent sessions trying to fix / tweak / extend the over-engineered foundation instead of stepping back and reaching for the simpler, battle-tested pattern that would have been the right answer on day one.** Locked by user 2026-04-08 after the carry-vibration saga.

**The failure pattern looks like this:**
1. Agent encounters a problem (e.g. "held object vibrates")
2. Agent invents a bespoke solution (manual snapshot interpolation, double-deferred mode reapply, manual composition chain, custom pushback raycast, etc.)
3. Solution doesn't fully work — leaves a residual bug
4. Next agent inherits the bespoke solution + the residual bug, and tries to patch THE BESPOKE SOLUTION rather than replace it
5. Complexity compounds. Session after session, the same symptom gets patched from yet another angle, each patch adding state + special cases + carve-outs
6. Eventually someone notices that a well-known industry pattern (HL2 physics gun velocity drive, WorkerThreadPool + frame budget, engine visibility_range, etc.) would have solved the original problem AND deleted 200 lines of the patchwork

**Carry-vibration saga canonical example.** Session 1 shipped kinematic direct-transform writes from `_process` at render rate + manual two-snapshot interpolation. Session 2 flipped project-wide physics interpolation + camera carve-out + manual chain composition. Session 3 tried body MODE_OFF + `reset_physics_interpolation()` + interpolated reads + MSAA. All three sessions patched the *bespoke kinematic-write approach*. The canonical fix — **HL2 physics-gun pattern**: keep the body dynamic, `linear_velocity = (target - body) * pull` in `_physics_process`, let Jolt integrate + engine interpolate — would have eliminated the entire bug class AND deleted: the manual composition chain, the wall-pushback raycast, the per-node interpolation mode carve-outs on the held body, the `reset_physics_interpolation()` calls, the exponential lerp rate tuning constants, and the sig 11 shutdown race around held-body teardown. Roughly 200 lines of complexity delete. The user had to literally paste the HL2 snippet into chat before the agent reached for it — three agents in a row went deeper into the bespoke solution instead of stepping back.

**Operational rules for agents:**
1. **When a bug persists across 2+ fix attempts on the same approach, STOP patching that approach.** Step back. Re-ask the original question: "How does Unreal / Unity / Source / Bevy / id Tech do this?" If a 20-year-old pattern exists, adopt it wholesale — don't re-derive a variant.
2. **Shortest path wins.** If the bespoke solution has 5 state variables, 3 deferred call chains, and 2 carve-outs, and the battle-tested pattern has 1 function and no state — the pattern wins even if the bespoke solution "almost works". Almost-working complexity is worse than working simplicity.
3. **Re-evaluate the approach, not just the code.** When reading inherited code, ask "is this architecture correct?" before "is this line buggy?" A line-level fix on a wrong architecture is negative work. The line-level fix gets in the way of the eventual architectural rewrite.
4. **Ask: would deleting this whole file simplify the next session?** If yes, propose the delete + replacement, not another patch on top. The user would rather see a 50-line rewrite than another 20-line patch.
5. **Explicit callout when re-reaching for the same tools.** If the third session in a row on the same bug is still "tweak the exponential lerp rate", stop. Write one line in chat: "approach is on its third iteration without resolution, searching for the canonical pattern". Then search. Canonical-pattern searches take 5 minutes; another 3-hour session patching the wrong approach does not.
6. **Don't trust the comments in bespoke code.** Long inline comments defending a custom solution are a SIGNAL, not a sign of quality. The code that requires 40 lines of comment to explain why it's safe is more likely to be unsafe than the 5-line canonical version that needs no explanation.

**Litmus test before ANY bug fix on existing code:** "If I were writing this system from scratch today, would I architect it this way?" If no, the fix is in the architecture, not the line.

**Signs you are over-engineering (stop and back out):**
- You need a multi-step deferred call chain to avoid race conditions
- You are writing a per-node interpolation carve-out that cascades through a subtree
- You are composing a chain of transforms by hand instead of reading one `global_transform`
- You are writing a "reset" helper to zero out state that gets dirty every frame
- You are adding a guard rail because the previous fix created a new failure mode
- The existing code has `# WHY: ...` comments longer than the function body
- A senior engineer at Epic / Valve / id would open the file and say "why is this so complicated"

**This principle is load-bearing against the pattern "the last agent built X, I should extend X".** Don't extend bad architecture. Replace it. The user would rather you spend 30 minutes deleting 200 lines of patchwork and shipping 50 lines of canonical pattern than 3 hours patching the patchwork.

---

## Engineering Principle — Build the Final Feature, Not a Placeholder Step

**Do not silently downgrade a requested feature into "let's first do X" just to have a Step 1 shipped.** Locked by user 2026-05-09 after the underwater-effect pass produced partial approximations for Snell's window, fog, rays, wobble, and particles that now need to be redone.

When the user asks for a feature, the target is the finalized, production-ready version of that feature, not a scaffold, prototype, diagnostic approximation, placeholder, or "good enough first pass" unless the user explicitly asks for that.

**Operational rules:**
1. If the full production-quality implementation is too large for one session, say so up front and propose a complete implementation plan with honest scope boundaries. Do not quietly build a lesser version.
2. Do not use phrases like "first pass", "step 1", "scaffold", "prototype", "approximation", or "temporary" as a shield for shipping behavior the user will reasonably expect to keep.
3. If technical risk requires a probe, keep it as an explicit throwaway investigation and do not present it as the completed feature.
4. If a feature requires a canonical architecture change, do that architecture change or stop and explain the cost. Do not bolt a partial effect onto the old architecture to show progress.
5. Before finalizing, ask: "Will the next agent need to redo this to make the requested feature real?" If yes, the work is not done.

---

## Reviewer Engagement Scope

**Reviewers (`@reviewer`, `@roaster`, `@critic`, etc.) engage at two points per change, NOT continuously.** Locked by user 2026-04-08.

**The two engagement points:**
1. **Plan review** — after the first draft of a plan / design doc / ADR lands, the reviewer weighs in on architecture, canonical-pattern choice, trade-offs. One pass, then hand back.
2. **Implementation review** — after the first draft of the implementation lands, the reviewer weighs in on code quality, edge cases, correctness. One pass, then hand back.

**NOT at:**
- Every in-flight bug fix during implementation
- Every chat message from the implementer
- Every commit / incremental save
- "Status check" intermediate milestones
- Responding to individual questions from the implementer while they work

The implementer runs the loop. The reviewer is a checkpoint, not a shoulder-surfer. Mid-implementation course corrections should come from the implementer's own judgment + the canonical-pattern litmus tests in `## Engineering Principle — Industry Standard, Never Kludge` and `## Engineering Principle — Simplicity Over Over-Engineering` above. If the implementer is drifting, THAT is the signal to re-engage the reviewer — not a scheduled tick.

**Why:** continuous reviewer engagement produces (a) micro-management friction, (b) context window bloat from reviewer ack-messages with no content, (c) implementer learned-helplessness waiting for sign-off on decisions they should be making, (d) noise in the chat timeline that drowns out the actual decision points. The reviewer's value per intervention goes DOWN as frequency goes up.

**Operational rule for reviewer agents:** if you are about to post a chat message that boils down to "noted" / "looks reasonable so far" / "proceed" / "ack" during active implementation, DON'T. Save your attention for the plan draft and the implementation draft. In between, silence is the correct output.

**Operational rule for implementer agents:** don't ping the reviewer for in-flight decisions unless you've hit a genuine architecture question that can't be resolved by the canonical-pattern principles. Ship the plan, ship the draft, THEN ping.

---

## Quick Reference

- **Engine:** Godot 4.6, Forward+, Jolt Physics, D3D12 (Windows)
- **Languages:** C# preferred for new work + hot paths, GDScript for thin orchestration glue, GLSL shaders
- **Main scene:** `scenes/Godotwind.tscn`
- **Morrowind cell size:** ~117m (70 MW units = 1 meter, i.e. 64 units/yard)

---

## Language & Typing Policy

**Prefer C# generally — it's significantly more performant.** New systems, hot paths, data structures, and non-trivial logic should default to C#. Reach for GDScript only when the task is dominated by Godot API calls where Variant marshalling cost eats the raw-compute win (light scene-tree glue, small signal handlers, one-off editor tools, `@tool` scripts).

**Rule of thumb:**
- **C# (default):** binary parsing, streaming pipelines, math-heavy systems, data structures, containers, algorithms, anything that runs per-frame on > 100 items, anything that runs on a worker thread, any new subsystem where performance might matter later.
- **GDScript:** thin orchestration glue where the work is calling engine APIs and reacting to signals. UI callbacks, simple gameplay triggers, editor tool shims, one-file utilities.

When in doubt: **write it in C#**. Marshalling cost is real but small on a per-call basis; raw-compute wins compound across frames. A system that starts in GDScript and grows into a hot path is harder to migrate than one born in C#.

**Strict typing REQUIRED in `src/core/`** — all params, returns, vars:
```gdscript
func parse_cell(reader: Reader) -> CellRecord:
    var cell := CellRecord.new()
    return cell
```

**Relaxed typing OK in `src/tools/`, `tests/`** — use `@warning_ignore` per-line:
```gdscript
@warning_ignore("untyped_declaration", "unsafe_method_access")
```

**Performance rules:**
- Static typing gives ~47% speedup in hot paths — always type Vector operations and loops
- Use `for element in array` not `for i in array.size()` (~60% faster)
- Prefer `PackedArray` variants (PackedVector3Array, etc.) for large data — contiguous memory
- Inner classes OK for encapsulating data (e.g. `BackgroundProcessor.TaskEntry`)

---

## Project Structure

```
src/core/              Core engine systems (strict typing)
src/core/world/        Streaming, LOD, cell management, interior pockets
src/core/nif/          NIF model parsing & conversion
src/core/esm/          Elder Scrolls Master file parsing
src/core/bsa/          Bethesda Archive reading
src/core/water/        Ocean simulation (framework ready, NOT integrated)
src/core/dialogue/     Generic dialogue framework + morrowind/ adapter
src/core/interaction/  Generic Interactable + InteractionRaycaster (Phase B)
src/core/ui/           Book viewer, journal, dialogue panel, toast, theme
src/native/            C# performance implementations
src/tools/             Editor tools, prebaking utilities (relaxed typing)
addons/                Third-party plugins (terrain_3d, etc.)
assets/ui/             Fonts, themes, icons
docs/                  Detailed documentation (see bottom of file)
```

---

## Autoloads

```
Log              — Structured logging (levels + categories, replaces raw print())
SettingsManager  — User settings, paths (get_cache_dir(), get_morrowind_install_path())
BSAManager       — Bethesda archive access (256MB LRU cache)
ESMManager       — ESM parsing, grid-indexed cell lookup (get_cell_by_grid())
OceanManager     — Water system coordinator (not integrated yet)
ShaderManager    — Shader hot-swap management
```

Never instantiate these — use the global singleton directly.

**Logging:** Use `Log` instead of `print()`. Levels: `debug`, `info`, `warn`, `error`. Categories match subsystems: `streaming`, `esm`, `nif`, `water`, `animation`, `deformation`, `textures`, `collision`, etc.
```gdscript
Log.info("esm", "Loaded %d records in %d ms" % [count, elapsed])
Log.debug("nif", "Parsing bone: %s" % bone_name)
```

---

## Distance Rendering (Single Source of Truth)

Constants in `src/core/world/distance_utils.gd`.

| Tier | Range | Technique | Status |
|------|-------|-----------|--------|
| NEAR | 0-150m | Full 3D Node3D + physics (single visibility_range band on root, 0-300m) | Working |
| MID | 0-300m* | Single raw RS instance per object with embedded LOD chain. `ImporterMesh.generate_lods()` at bake time; Godot C++ screen-space selector picks LOD level per frame from `mesh_lod_threshold` + `lod_bias` | Working (was 0-500m, narrowed by HLOD) |
| HLOD | 300-1000m | One RS instance per chunk — runtime-merged static geometry with LOD chain. `object_paging.gd` merges on background thread, staggered 2/frame. Adaptive chunk sizes: 1×1 (150-300m), 2×2 (300-600m), 4×4 (600-1000m). Enabled via `hlod_enable` console cmd | Implemented 2026-04-13, disabled by default, visual verification pending |
| FAR | 1000-5km | Octahedral impostors (single MultiMesh draw call) | Working |

\* MID range falls back to 0-500m when HLOD is disabled (default). Enable via `hlod_enable` console command — runtime merger handles all merging, no prebake needed.

MID tier uses `RenderingServer.instance_geometry_set_visibility_range()` for hard-cull at the MID→HLOD handoff (300m with HLOD, 500m without). Sub-LOD selection is fully engine-driven from the embedded `ArrayMesh.surface_lod_indices` cascade — **no manual per-band visibility_range sub-bands**. Post-B-wide refactor, each MID object is **one** RS instance (not 4). HLOD cells are also one RS instance each. See `docs/systems/distance_rendering.md` + `docs/archive/plans/lod_refactor_b_wide.md`. Promotion at 250m / demotion at 280m for physics bodies (20m hysteresis).

---

## System Status

Ground truth lives in `docs/STATUS.md`. Don't duplicate here. When in doubt about what's shipped vs framework-only vs not-started, read STATUS.md first.

---

## Verification — How to Check Your Work

- Open `scenes/Godotwind.tscn` and run — should stream Morrowind cells at 60+ FPS
- Press `` ` `` for console, check for errors
- Streaming changes: watch frame time (budget: 2ms/frame for cell loading)
- Shader changes: fly to tier boundaries (150m, 500m) and check for artifacts
- **C# changes MUST rebuild** before running: `dotnet build Godotwind.sln` from project root, or Build > Build Solution in Godot editor. Godot will NOT auto-rebuild C# on scene launch.
- Profile before optimizing: use Godot's built-in profiler or ObjectDB snapshots (4.6)

## Testing (gdUnit4)

- **Framework:** gdUnit4 v6.1.2 (`addons/gdunit4/`)
- **Run all tests:** `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/run_tests.tscn`
- **Exit code:** 0 = all pass, non-zero = failures
- Opens a window briefly (headless doesn't resolve `class_name` types)
- **Test directories:**
  - `tests/unit/` — Fast, isolated, no scene tree needed
  - `tests/integration/` — Needs autoloads/scene tree
  - `tests/benchmark/` — Performance tests with thresholds (see `benchmark_thresholds.gd`)
  - `tests/visual/` — Manual visual verification scenes
- **Benchmark thresholds:** `tests/benchmark/benchmark_thresholds.gd` (single source of truth for perf limits)
- **Writing tests:** Use `GdUnitTestSuite` base class. Unit tests must not depend on Morrowind data install — use hardcoded fake data.
- **When to add tests:** New math/utility code, performance-critical paths, bug fixes (regression tests). Don't retroactively test all existing code.
- **Test scenes MUST use the unified input system.** Every new test scene (visual, integration, manual) reads input via the `InputMap` actions defined in `project.godot [input]` and namespaced in `src/core/input/input_actions.gd`. Never hardcode `Input.is_key_pressed(KEY_*)`, never invent ad-hoc WASD loops with raw keycodes, never bypass actions for "just a quick test scene." This applies to test scenes too — the unified system is the contract for AZERTY/QWERTY/Dvorak parity, gamepad support, and future rebinding. Canonical example: `tests/visual/test_input_phase_K0.tscn`. Reference: `docs/systems/input_system.md` §6.

---

## Anti-Patterns — Don't Do This

- **DON'T** create new autoloads — use existing singletons
- **DON'T** access scene tree from worker threads — use `call_deferred()`
- **DON'T** use `pop_front()`/`push_front()` on arrays — O(n). Use `pop_back()`/`append()`
- **DON'T** call `get_node()` every frame — cache with `@onready`
- **DON'T** skip `wait_for_task_completion()` on WorkerThreadPool — causes memory leaks
- **DON'T** default to GDScript for new systems without justification — C# is the default (see Language & Typing Policy)
- **DON'T** call RenderingServer functions that return values every frame (stalls async pipeline)
- **DON'T** add collision shapes as trimesh when primitives fit — box/sphere/capsule are dramatically cheaper
- **DON'T** set `monitoring=true` on Area3D without specific `collision_mask` — Jolt perf issue
- **DON'T** forget `visibility_range_end_margin` on LOD boundaries — causes flicker
- **DON'T** use `push_error()`/`push_warning()` for expected conditions — use `Log.info()`
- **DON'T** use raw `print()` in `src/core/` — use `Log.info/debug/warn/error()` instead
- **DON'T** instantiate from worker threads — `duplicate()` is OK, `instantiate()` is main-thread only
- **DON'T** bake Morrowind-specific logic into framework code — MW formats (SCVR, NIF, ESM) belong in `morrowind/` adapter subdirectories, not in generic systems
- **DON'T** roll your own input loop in a test scene — read from `InputMap` actions (`Input.is_action_*`, `Input.get_vector("move_left","move_right","move_forward","move_backward")`). No `Input.is_key_pressed(KEY_*)`, no raw WASD branches. See Testing section + `docs/systems/input_system.md` §6.
- **DON'T** use automated screenshot/auto-capture harnesses for visual verification — **EVER**. No `--auto-capture`, no scripted camera paths that auto-quit, no headless PNG dumps to "prove" a visual change works. Scripted captures lock to one camera pose and miss artifacts the user would catch in 5 seconds of free-fly (wobble patterns, debug modes left on, guard inversions, screen-space artifacts). Launch the test scene **interactively** and let the user pilot the camera. Auto-capture is a trap: it fakes confidence in broken visuals. Internal math sanity dumps (debug shader modes for world-pos reconstruction, etc.) are fine, but the human-verification pass is always interactive.

---

## Architecture Decisions — Why We Chose This

- **Prebaked assets** not runtime conversion: 1-5ms load vs 50-200ms parse per NIF
- **C# for parsing** not GDScript: 20-50x faster binary I/O
- **Custom impostors** not engine LOD: Godot has no built-in impostor system
- **Material dedup via hashing**: 90% reduction (10,000 -> 1,000 unique materials)
- **Frame budgeting** not blocking loads: 2ms/frame keeps 60 FPS smooth
- **NativeBridge pattern**: C# can't call GDExtensions directly — GDScript bridge (`src/core/native_bridge.gd`)
- **Hysteresis on LOD boundaries**: Different load/unload radii prevent oscillation
- **Translation layer pattern**: Game-specific logic (MW formats, conditions, conventions) in adapter subdirectories (e.g. `morrowind/`), framework stays generic

---

## Gotchas & Known Issues

1. **C# cannot call GDExtensions** — use GDScript bridge (`src/core/native_bridge.gd`)
2. **Occlusion culling buggy outdoors** — enable for interiors only
3. **Custom SSR in water shaders** is SEPARATE from engine SSR (don't disable engine SSR expecting water to keep working)
4. **Water/ocean** framework complete but not integrated into world_explorer
5. **TwoBoneIK3D** uses settings-indexed API: `set_root_bone_name(0, ...)` — no property-based access. No `start()`/`stop()`, uses `active = bool`
6. **Morrowind coords are Z-up** — conversion: `Vector3(mw.x, mw.z, -mw.y)`. See `src/core/coordinate_system.gd`
7. **Log autoload is named `Log`, not `Logger`** — Godot 4.6 introduced a built-in native `Logger` class, causing a naming conflict. Our autoload was renamed from `Logger` to `Log` to avoid shadowing the engine class.
8. **Terrain3D v1.0.1 stable** — `terrain.vertex_spacing = TERRAIN_VERTEX_SPACING` works natively. No scale workaround needed. `import_images()` and `get_height()` accept world positions directly.
9. **Terrain3D ENTER_TREE re-enables physics** — C++ handler calls `set_physics_process(true)`. Always re-disable AFTER `add_child()`. Also add a Camera3D before Terrain3D in @tool scenes (crashes in `_grab_camera()` without one).
10. **Terrain3D `import_images()` uses CENTER position** — v1.0.1 expects center of region for snapping: `x * size + size * 0.5`, `z = -y * size - size * 0.5`. World positions passed directly (no coordinate conversion needed). **Requires terrain rebake** after any import position changes.

---

## Code Style (Essentials)

- **Classes:** PascalCase (`ESMRecord`, `CellManager`)
- **Variables/functions:** snake_case, private with leading underscore (`_cache`, `_helper()`)
- **Constants:** SCREAMING_SNAKE (`MAX_LOAD_DISTANCE`)
- **Signals:** typed connections (`signal.connect(callable)`), never string-based
- **Comments:** explain WHY not WHAT. Skip obvious comments.
- **@tool decorator** for scripts that need editor-mode execution
- **Error handling:** `push_error()` for critical failures, `push_warning()` for recoverable, `assert()` for debug checks
- **Use Godot's native features** (visibility_range, MultiMesh, WorkerThreadPool, Jolt) before implementing custom systems

---

## Documentation

Detailed docs in `docs/`. Key entry points:
- `docs/STATUS.md` — what works (ground truth)
- `docs/ARCHITECTURE.md` — systems overview, code map, patterns
- `docs/systems/` — per-subsystem truth docs (dialogue, interaction, input, character controller, distance rendering, lighting, terrain, ocean, NIF pipeline, loading, object paging, benchmarking, etc.)
- `docs/reference/` — industry / research / OpenMW / AAA framework gap analysis — NOT current-state docs
- `docs/plans/` — in-flight plans (benchmark v2, groundcover, impostor rebuild, wetness, lighting roadmap, NIF collision part 2, phase 3 MID multimesh, distant rendering 2026-04, shore overhaul)
- `docs/archive/` — superseded plans + dated session logs

`ls docs/systems/` for the live per-topic set.

---

## Behavioral Guidelines (from [andrej-karpathy-skills/CLAUDE.md](https://github.com/forrestchang/andrej-karpathy-skills))

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
