# MID-Tier Visual Audit Results — 2026-03-02

## Tools Built

### `mid_debug` / `md` (MidTierDebugger)
- **Autopilot camera**: Back-and-forth flight at 30 m/s, 100m altitude, ±600m from start
- **Object census**: ESM expected vs NEAR+MID actual, per-cell, every 5s and at each endpoint
- **Missing object markers**: Red 3D pillars at positions of expected-but-absent objects
- **HUD panel**: Real-time batch pool stats overlay
- **CSV report**: Per-census row with all metrics, crash-safe append+flush

### `mid_audit` / `ma` (Visual Audit)
- Checks every loaded NEAR object for: visibility_range config, layer masks, mesh existence, material existence, visibility in tree
- Checks every MID batch for: visible_instance_count vs max_used_slot, visibility_range, empty batches, orphaned hidden slots

### `mid_census` / `mc` (One-shot census)
### `mid_markers` / `mm` (Toggle markers only)
### `mid_hud` (Old batch debug HUD, renamed from previous `mid_debug`)

---

## Census Results (6 laps, autopilot)

| Metric | Value |
|--------|-------|
| Cells checked | 49 |
| Expected MID-worthy objects | 5,070 |
| NEAR tier objects | 1,163–1,400 (fluctuates with camera position) |
| MID tier objects | 4,547 (stable — MultiMesh batches) |
| Promoted (MID→NEAR) | 30–266 |
| Queued | 0 (pipeline always keeps up) |
| **Genuinely missing** | **0 (0.0%) across ALL 6 laps** |
| FPS | 79–234 |

CSV saved at: `user://mid_debug_reports/mid_debug_2026-03-02_12-22-08.csv`

---

## Visual Audit Results (4 snapshots during autopilot)

| Check | Result |
|-------|--------|
| NEAR objects audited | 798–1,252 |
| In camera range & should render | 587–1,061 |
| **In range but blocked** | **0 in ALL runs** |
| Layer mismatches | 0 |
| Missing mesh | 0 |
| Missing material | 0 |
| Bad visibility_range | 0 |
| Hidden nodes | 0 |
| MID batches | 978 |
| MID total objects | 13,641–14,868 |
| visible_instance_count mismatches | 0 |
| Empty batches | 0–9 (0.9%, trivial) |
| Orphaned hidden slots | 0 |

---

## Conclusion

**The NEAR and MID tier streaming pipeline is healthy.** Every expected MID-worthy object is loaded in either NEAR or MID tier. No objects are "blocked" from rendering. The 9 empty batches are a trivial artifact.

## What This DOESN'T Cover

The audit tested NEAR (0–150m) and MID (150–500m) only. The user's perception of "things missing" may come from:

1. **FAR tier (impostors, 500m–5km)** — NOT audited. If octahedral impostors are broken or missing for many models, the world looks empty beyond 500m. This is the most likely cause of perceived sparsity.
2. **LOD transition pop-in** — Objects may appear suddenly rather than fading in smoothly. The fade-in material pool exists (Phase 6) but may not cover all cases.
3. **Morrowind's natural sparsity** — Wilderness areas (Ashlands, West Gash) genuinely have sparse placement in the ESM data.
4. **Terrain coverage gaps** — Terrain3D may not have full data for all areas, causing floating objects or bare patches.

## Recommended Next Investigation

1. **Audit the FAR/impostor tier** — Check how many models have prebaked impostors vs how many should. The impostor system (`src/core/world/impostor_*.gd`) may have gaps.
2. **Check LOD transition smoothness** — Fly slowly through the 140–160m boundary and the 490–510m boundary. Objects should crossfade, not pop.
3. **Screenshot comparison** — Compare a specific cell's loaded objects against OpenMW rendering of the same cell to identify what's visually different.

---

## Files Created/Modified

| File | Change |
|------|--------|
| `src/tools/mid_tier_debugger.gd` | NEW (~930 lines) — Full debug system |
| `src/core/world/mid_tier_batch_pool.gd` | +13 lines — Public accessors for `_cell_index` |
| `src/tools/world_explorer.gd` | +7 lines — Command registration, StatsCollector type fix |

## Bug Fixed (Pre-existing)

`StatsCollector.update()` was called with an untyped `{}` dict but expects `Dictionary[String, Variant]`. Caused a SCRIPT ERROR every frame, spamming logs. Fixed by adding the type annotation to the caller in `world_explorer.gd:1084`.
