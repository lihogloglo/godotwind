> Archived session log. Preserved verbatim from the pre-cleanup `docs/INTERACTION_SYSTEM.md` §16 "Decision History". Current interaction system state lives in `docs/systems/interaction_system.md`. This file is kept for the C.2 click-bug hunt + C.2.5 sequencing history.

## 16. Decision History (Session 2026-04-07)

This section is an audit log of what was done and decided during the original drafting session, so future agents picking up I.0+ implementation work can understand the constraints without re-deriving them from chat history.

### 16.1 Session timeline

| Time   | Event | Outcome / Artifact |
|--------|-------|--------------------|
| start  | `@user` requested audit of physics-interaction-pickup stack on `#interactivity` | Posted findings: collision builder fully built, interaction framework wired in test scene only, buoyancy framework standalone, ZERO pickup/carry/throw code anywhere |
| +20min | `@user` requested design doc for "perfect interactivity that doesn't fight other systems" | Drafted `docs/INTERACTION_SYSTEM.md` §1-§15 |
| +5min  | `@reviewer` review pass: 3 must-fix + 7 should-fix | See §16.2 |
| +10min | M1 verification — frozen-RB tick check | Built `tests/diagnostic/frozen_rb_tick_check.tscn`, ran headless, **confirmed Godot 4.6 ticks `_physics_process` on frozen RigidBody3D**: 59 ticks in 60 frames, freeze=true, freeze_mode=KINEMATIC. Early-out guard mandatory. |
| +10min | All 10 review fixes folded into doc | See §16.2 |
| +5min  | `@reviewer` re-pass — green-light + 5 checklist additions | See §16.3 |
| +20min | Cross-thread API shape coordination (got messy) | See §16.4 |
| +5min  | `@user` shut down crossposting, reassigned channels strictly | `@interactivity` → `#interactivity` only, `@dialogue` → `#text` only |
| +10min | Final API shape locked: signal-based modal gate registry on `PlayerController` | See §3.1 |

### 16.2 Reviewer Round 1 — 3 must-fix + 7 should-fix (all addressed)

| # | Issue | Resolution |
|---|-------|------------|
| **M1** | §6.4 frozen-RB `_physics_process` tick was unverified — whole perf argument depended on it | **Verified empirically** — `tests/diagnostic/frozen_rb_tick_check.tscn` confirms Godot 4.6 ticks frozen RBs every frame. Guard `if freeze: return` is now spelled out in §6.4 with the verification date stamped in the code comment. |
| **M2** | §6.1 vs §13 Q5 layer mask contradiction | New §6.5 "Held-state collision mask" section. Spawn = `Environment | Player`. Grab snapshots mask + clears `PLAYER_BIT`. Release restores before unfreeze + impulse. Single source of truth. |
| **M3** | §6.3 throw step 3 dimensional bug — `camera_angular_motion` (rad/s) added to linear velocity | Fixed: `linear_velocity += camera_angular_velocity.cross(held_position - camera_position)` (lever arm, dimensionally clean rad/s × m → m/s). Unit error called out for paper trail. |
| **S1** | §6.1 mass conversion contradiction (50 kg cap vs 200 kg cap, lbs vs kg) | Committed to "ESM weight treated as kg directly, gameplay-tuned, no lb→kg conversion". `[0.1, 200.0]` clamp is solver sanity only. 50 kg grab refusal lives in `CarryController`, not spawn clamp. One cap, one place. |
| **S2** | §10 orphan registry vs "no new autoloads" rule | Explicit ownership note before §10: `OrphanedCarriedItems` is a child of `NativeStreamingManager`, not a fourth singleton. Promotion to autoload requires explicit reviewer sign-off. |
| **S3** | §8 rule 2 only covered `DialoguePanel.visible`, missed `BookViewer.visible` | Rewritten as "Modal UI gates carry" — covers `DialoguePanel`/`BookViewer`/`JournalPanel`/future container UI via central `is_modal_ui_open()` helper. Spelled out the exact bug it prevents (hold E to read → book lifts mid-read). |
| **S4** | §6.2 hold spring lacked tunable parameters | New "Hold spring tuning" paragraph: stiffness ~80 N/m equivalent (lerp 0.25/frame), max pullback 0.6 m, force-drop after 0.3 s at max. Flagged as I.3-tunable. |
| **S5** | §6.3 throw window was frame-based (`~3 frames`), framerate-dependent | Rewritten as "last 50 ms (time-windowed, framerate-independent — ring buffer keyed by `Time.get_ticks_msec()`)". |
| **S6** | §7 InventoryService failure modes undefined | Full contract table added: `OK` / `INVENTORY_FULL` / `FORBIDDEN` / `INVALID_RECORD` with world-body-action column. Cap policy explicit: inventory cap and grab cap independent. |
| **S7** | Roll-locked rotation for held objects missing | New "Hold pose rotation contract" paragraph in §6.2. Yaw + pitch tracked, roll locked to world up. Snapshot `(yaw, pitch, 0)` Euler. |

### 16.3 Reviewer Round 2 — green-light + 5 checklist additions

After all 10 fixes landed, `@reviewer` approved the doc and asked for 5 new items in §15:
- Modal UI gate API surface
- Held-state mask transition
- Throw lever-arm cross product
- Mass field as kg
- Hold pose roll lock

All 5 added (see §15 lines 377-381). Doc was green-lit for I.0 implementation.

### 16.4 API shape negotiation — three rejected proposals before settling on signal-based

The "how do modal UIs gate input?" question went through three shapes before locking. Documenting them so future agents don't re-propose any of the rejected ones.

**Proposal 1 — counter (`push_modal_ui()` / `pop_modal_ui()` / `_modal_count > 0`)** — `@interactivity` initial proposal in #interactivity id=3870. **Rejected** because counter drifts positive if a panel frees while visible (no final symmetric pop event). Hard to debug for long sessions.

**Proposal 2 — Callable predicate (`register_modal_gate(is_open: Callable)`)** — `@interactivity` revision in #interactivity id=3873, after `@dialogue` pointed out the counter coupling problem. Better than counter (self-healing via `Callable.is_valid()`), but introduced a dialect mismatch: a parallel reviewer post in #text proposed an `InputOwner` enum stack instead.

**Proposal 3 — `InputOwner` enum stack (`push_owner(InputOwner.DIALOGUE)` / `pop_owner()`)** — `@reviewer` override in #text id=3872, with members `{ WORLD, DIALOGUE, BOOK, MENU, CARRY }` (later `+ LOADING`). **Considered** because the enum carries semantic state (mouse mode = `func(owner)`) and lets `PlayerController` be sole owner of `Input.set_mouse_mode`. **Rejected** in #interactivity id=3881 in favor of the simpler signal-based registration: enum adds state nobody currently needs, and the mouse-mode-as-func-of-owner benefit can be layered on top of the bool gate later if needed. YAGNI.

**Locked shape — signal-based registration with `is_open()` contract** (Proposal 4, the keeper). See §3.1 for the full code. Key properties:
- Zero coupling to specific UI types
- Self-healing via `tree_exiting` connection (auto-removes freed gates)
- Debuggable (can dump registered gate names)
- `is_open()` method instead of `.visible` duck-typing because `DialogueUI` is a `CanvasLayer` with no top-level `.visible`
- `InputOwner` enum can be added as a layer on top later if differential per-owner input handling becomes a real requirement

### 16.5 Cross-thread coordination outcome (and what NOT to repeat)

The InputOwner architecture spans both `#interactivity` and `#text` (because `@dialogue`'s `DialogueUI` is the primary consumer of whatever API `@interactivity` ships on `PlayerController`). During the negotiation, both threads got cross-posts and conflicting reviewer decisions (one in each channel). `@user` shut it down — no more crossposting. Channel discipline locked:

- `@interactivity` → `#interactivity` only, reviewed by `@reviewer`
- `@dialogue` → `#text` only, reviewed by `@roaster`
- Cross-thread topics: each agent posts in their own channel, reviewers relay if needed

Future I.0+ implementation work follows this rule strictly.

### 16.6 Sequencing locked

1. **C.2** [SHIPPED] shipped earlier in session (`@dialogue` side) — temporary `DialogueSession.is_any_panel_open()` bool gate + raycaster early-out + `interact`-action close handler in `BookViewer`/`DialogueUI`. Unblocks `test_interaction.tscn`. Marked as STOPGAP, deletion target for C.2.5.
2. **I.0** (next) — `@interactivity` builds `PlayerController` with the API in §3.1 + wires `InteractionRaycaster` into `scenes/Godotwind.tscn` + removes `interaction_raycaster.gd:89-102` `_unhandled_input` handler + ships `tests/visual/test_interaction_phase_I0.tscn`
3. **C.2.5** (after I.0) — `@dialogue` side consumes `PlayerController.register_modal_gate()` from `DialogueUI`/`BookViewer`/`JournalPanel`, deletes the C.2 stopgap, deletes per-site `Input.set_mouse_mode` calls
4. **I.1** + **C.5** can ship in parallel after C.2.5

### 16.7 Artifacts created in this session

| Path | Purpose |
|------|---------|
| `docs/INTERACTION_SYSTEM.md` | This doc — the design contract for the entire interaction system |
| `tests/diagnostic/frozen_rb_tick_check.gd` | Diagnostic that proves Godot 4.6 ticks `_physics_process` on frozen RigidBody3D |
| `tests/diagnostic/frozen_rb_tick_check.tscn` | Scene wrapper for the diagnostic — kept as a regression check |

### 16.8 Status as of end-of-session 2026-04-07

- Doc: design-only, **green-lit by `@reviewer`**, ready for I.0 implementation
- Code: zero implementation shipped this session (apart from the diagnostic)
- C.2 hotfix on the dialogue side: shipped, **awaiting `@user` interactive verification** of the topic-click bug
- Next action: `@interactivity` starts I.0 implementation, ships `tests/visual/test_interaction_phase_I0.tscn`, pings `@reviewer` in `#interactivity` for the impl review
