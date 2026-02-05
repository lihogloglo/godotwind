# Godot 4.5 → 4.6 Migration Tracker

Migrate Godotwind from Godot 4.5 to 4.6: **IK system overhaul**, **Jolt physics**, **SSR improvements**, **docs update**.

---

## Phase 1: Project Config
- [x] Update `project.godot`: `"4.5"` → `"4.6"`
- [x] Add `[physics]` section: `3d/physics_engine="JoltPhysics3D"`

---

## Phase 2: IK Migration (`ik_controller.gd`)

Migrated `SkeletonIK3D` → `TwoBoneIK3D` (new settings-indexed API):
```gdscript
# New API pattern:
ik.set_setting_count(1)
ik.set_root_bone_name(0, "UpperLeg")
ik.set_middle_bone_name(0, "LowerLeg")  # NEW: required
ik.set_end_bone_name(0, "Foot")
ik.set_target_node(0, path_to_target)
# No start()/stop() — auto-solves as SkeletonModifier3D
```

- [x] **A.** Update variable types: `SkeletonIK3D` → `TwoBoneIK3D` (lines 52-54, 528-531)
- [x] **B.** Rewrite `_setup_foot_ik()`: new API + add middle bone (knee) from existing `_bone_indices[&"left_lower_leg"]`
- [x] **C.** Remove `start()` calls in `_update_foot_ik()`
- [x] **D.** Fix `set_foot_ik_enabled()`: `.start()`/`.stop()` → `.active = enabled`
- [x] **E.** Rewrite `_create_leg_ik()`: new API + middle bone from `leg_bones["lower"]`
- [x] **F.** Update `_create_ik_target()` type hint: `SkeletonIK3D` → `TwoBoneIK3D`, use `set_target_node(0, ...)`
- [x] **G.** Fix `_update_leg_ik()`: type hint, `ik.tip_bone` → `ik.get_end_bone_name(0)`, remove `ik.start()`
- [x] **H.** Verified `_find_bone_indices()` already detects `left_lower_leg`/`right_lower_leg` — no changes needed

---

## Phase 3: SSR (No Code Changes Needed)

- [x] Existing SSR config works unchanged in 4.6 (quality improves automatically via engine overhaul)
- [x] Custom SSR in `flat_water.gdshader` is shader-level — unaffected by engine SSR changes

---

## Phase 4: CLAUDE.md Full Update

- [x] Update all version references `4.5` → `4.6`
- [x] Add new IK System (4.6) section with `IKModifier3D` hierarchy and `TwoBoneIK3D` API + code examples
- [x] Add Physics (4.6) section documenting Jolt as default
- [x] Add Rendering (4.6) section with SSR overhaul, octahedral probes, LOD improvements, texture import speed
- [x] Add Debugging & Profiling (4.6) section: ObjectDB snapshots, Tracy/Perfetto profilers
- [x] Update Known Issues section (occlusion culling, LOD quality notes updated for 4.6)
- [x] Update Resources & Documentation section (4.5 → 4.6 links, added IK docs)
- [x] Update Final Notes key principle for 4.6

---

## Phase 5: Cleanup & Type References

- [x] Searched entire `src/` for `SkeletonIK3D` — zero references remaining
- [x] Searched `.gd`, `.tscn`, `.tres` files — clean
- [x] Updated `docs/design/CHARACTER_ANIMATION_SYSTEM.md` — IK row in Known Limitations table

---

## Phase 6: Deprecated API Cleanup

- [x] Replaced `set_bone_global_pose_override()` in `_apply_look_rotation()` (`ik_controller.gd:358-365`) — converted to `set_bone_pose_rotation()` with global→local space conversion via rest pose and parent bone
- [x] Removed outdated "Godot 4.5" comment in `animation_manager.gd:403`

---

## NOT Changing

- Custom water SSR shader (shader-level, unaffected)
- Mesh simplifier (custom QEM, not Godot's LOD gen)
- Tonemapping (keeping Filmic/ACES)
- Glow, reflection probes (not used)
- Look-At IK (already custom, not SkeletonIK3D)
- Hand IK (metadata-based, out of scope)

---

## Verification (manual testing needed)

- [ ] Open project in Godot 4.6 — no parse errors
- [ ] Run world explorer — scene loads, terrain/water works
- [ ] Spawn NPC with IK — foot IK adapts to terrain
- [ ] Console clean — no IK errors or deprecation warnings
- [ ] Toggle IK on/off — `.active` property works
- [ ] Test quadruped creatures — 4-leg IK works
- [ ] Verify physics — movement, collision, raycasting with Jolt
- [ ] Profile FPS — no regression
