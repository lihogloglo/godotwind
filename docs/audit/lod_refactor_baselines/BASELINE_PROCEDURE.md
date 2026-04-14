# LOD Refactor Baseline Procedure (v3)

**Purpose:** capture the pre-refactor programmatic baseline for the LOD B-wide refactor. "Before" side of every "before vs after" comparison across Phase D and Phase G.

**No screenshots. No eyeballing. Dedicated test scene with specific hypothesis tests.** v1 used screenshots (rejected as lossy). v2 used in-main-scene console dump commands (too abstract, too much walking around, "nothing different from the previous experience" per `@user` msg 186). v3 uses a dedicated test scene (`tests/visual/test_lod_baseline.tscn`) that loads a single cached `.res` file directly and runs 9 specific hypotheses against it with PASS/FAIL per hypothesis + a diagnosis block.

**Before you start:** the plan is at `docs/audit/LOD_REFACTOR_B_WIDE.md`. Phase A is what this procedure delivers. Phase B-G are the code changes.

---

## 0. Prerequisites

- On branch `refactor/lod-b-wide` (already checked out by `@lods` in Phase A)
- Godot 4.6 Mono available: `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe"`
- Cache at `C:/Users/metzo/Documents/Godotwind/cache/models/` contains 5172 `.res` files (verified via `pre_wipe_cache_manifest.txt`)
- **Do NOT rebake** before running the baseline. The current buggy cache IS the baseline we want to capture. Phase D rebakes everything with the new engine pipeline, and we compare against the current state.
- The test scene is `tests/visual/test_lod_baseline.tscn`. The script is `tests/visual/test_lod_baseline.gd`.

---

## 1. Primary artifact — dedicated test scene

### 1.1 What `test_lod_baseline.tscn` does

Loads a specific cached `.res` file (e.g., `x_ex_vivec_h_01_nif.res`) via `ResourceLoader.load(path, "PackedScene")` and walks the instantiated prototype tree. It auto-detects the cache format (OLD sibling-`_LODn` vs NEW embedded-`surface_lod_indices`), aggregates per-LOD mesh info (triangle counts, AABBs, materials, visibility ranges, node counts) across all MeshInstance3Ds, and runs 9 hypothesis tests with PASS/FAIL markers:

| H | Test | Failure signals |
|---|------|-----------------|
| H1 | LOD0 has > 100 triangles (sanity) | source mesh empty or corrupted |
| H2 | LOD1 tri count is 40–60% of LOD0 | simplifier not hitting 50% target |
| H3 | LOD2 tri count is 20–35% of LOD0 | simplifier not hitting 25% target |
| H4 | LOD3 tri count is 5–15% of LOD0 | simplifier not hitting 10% target |
| H5 | LOD1/2/3 AABB volume is ≥ 95% of LOD0 volume | entire panels collapsed |
| H6 | LOD1/2/3 AABB X/Y/Z dimensions each ≥ 95% of LOD0 | asymmetric collapse |
| H7 | LOD1/2/3 have a material assigned | material pipeline dropped materials |
| H8 | LOD1/2/3 have the same MeshInstance3D node count as LOD0 | **sub-meshes dropped entirely — the canonical "missing faces" bug** |
| H9 | LOD1, LOD2, LOD3 triangle counts are pairwise distinct | simplifier no-op'd — produced identical output at all levels |

It also spawns each LOD variant side-by-side in the scene (along the X axis, spaced `lod_spacing` meters apart) with all other LOD levels hidden, so you can free-cam around and visually inspect each LOD in isolation if desired.

The final output is a text report written to `user://lod_baselines/<output_label>.txt` which resolves to `%APPDATA%/Godot/app_userdata/Godotwind/lod_baselines/<output_label>.txt` on Windows.

### 1.2 Running the scene (automated, one command per target)

There are two equivalent paths:

**Option A — CLI launch with default target (`x_ex_vivec_h_01_nif.res`):**

```bash
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" \
    --path "D:/Gamedev/Godotwind/godotwind" \
    res://tests/visual/test_lod_baseline.tscn
```

Runs automatically on `_ready()`, prints the report to stdout, writes the file to `user://lod_baselines/baseline_vivec_h_01.txt`, then opens a window showing the side-by-side LODs. Press `SPACE` in the window to re-run the test. Close the window to exit.

**Option B — change the target:**

Edit `tests/visual/test_lod_baseline.tscn` in the Godot editor, select the root `TestLodBaseline` node, change the `Cache Model Filename` and `Output Label` in the Inspector, save. Then run via F6 or the CLI command above.

OR — for fast iteration without editing the scene — edit `@export var cache_model_filename` default value in `test_lod_baseline.gd` directly.

### 1.3 Target list for Phase A baseline

Run the test scene against each of these targets:

| Target filename | Output label | Context |
|-----------------|--------------|---------|
| `x_ex_vivec_h_01_nif.res` | `baseline_vivec_h_01` | Vivec canton hero piece (Temple district modular) |
| `f_flora_tree_01_nif.res` | `baseline_tree_01` | Generic tree (flora LOD path) |
| `f_flora_bc_mushroom_01_nif.res` | `baseline_mushroom_bc_01` | Bitter Coast mushroom (organic silhouette) |
| `d_ex_redoran_hut_01_a_nif.res` | `baseline_redoran_hut` | Redoran architecture (Ald-ruhn district) |

(Feel free to pick different targets — these are suggestions. The point is to hit variety: architecture + flora + mushroom + Redoran/Hlaalu mix.)

After each run, **copy the report from `%APPDATA%/Godot/app_userdata/Godotwind/lod_baselines/` to `docs/audit/lod_refactor_baselines/programmatic/`** so it lives in the repo alongside the plan doc.

### 1.4 Reading the output

Example output from `baseline_vivec_h_01.txt` (captured 2026-04-09):

```
Format detection: OLD (sibling _LODn MeshInstance3D nodes, pre-refactor hand-rolled pipeline)

Per-LOD summary:
  lod0: 478 tris across 5 nodes, AABB (11.0×7.5×9.1), vol 749, vis_range 0-150
    nodes: MergedMesh_0, MergedMesh_1, MergedMesh_2, MergedMesh_3, MergedMesh_4
  lod1: 292 tris across 1 nodes, AABB (11.0×7.4×9.1), vol 735, vis_range 150-250
  lod2: 292 tris across 1 nodes, AABB (11.0×7.4×9.1), vol 735, vis_range 250-375
  lod3: 292 tris across 1 nodes, AABB (11.0×7.4×9.1), vol 735, vis_range 375-500

Hypothesis tests:
  H1 [LOD0 > 100 tris]: PASS (478)
  H2 [lod1 tri ratio 40-60%]: FAIL (292 tris, 61.1% of LOD0)
  H3 [lod2 tri ratio 20-35%]: FAIL (292 tris, 61.1% of LOD0)
  H4 [lod3 tri ratio 5-15%]: FAIL (292 tris, 61.1% of LOD0)
  ...
  H8 lod1 [node count == LOD0 (5)]: FAIL (1) — 4 sub-meshes DROPPED
  H8 lod2 [node count == LOD0 (5)]: FAIL (1) — 4 sub-meshes DROPPED
  H8 lod3 [node count == LOD0 (5)]: FAIL (1) — 4 sub-meshes DROPPED
  H9 [LOD1/2/3 tri counts distinct]: FAIL (292 / 292 / 292)

Diagnosis:
  [DROPPED SUB-MESHES] The canonical 'missing faces' bug manifestation:
    - lod1 has 1 nodes, LOD0 has 5 → 4 sub-meshes MISSING
    - lod2 has 1 nodes, LOD0 has 5 → 4 sub-meshes MISSING
    - lod3 has 1 nodes, LOD0 has 5 → 4 sub-meshes MISSING
  At distance > 150m, the MID-tier RS instances for the dropped merge groups
  are literally absent — the geometry was never placed in LOD1/2/3 sibling nodes.
```

**What it says ELI5:**

The Vivec canton piece (`x_ex_vivec_h_01`) has **5 separate mesh groups** at full detail (the 5 MergedMesh_N nodes, each a material group — walls, roof, trim, windows, etc.). At LOD1/2/3 there is only **1** of those 5 groups present. **4 out of 5 mesh groups literally disappear** when the camera moves past 150 meters. Additionally, that remaining group has the same triangle count at LOD1, LOD2, and LOD3 — the simplifier isn't producing distinct reduction levels, it's just emitting the same mesh three times.

That is exactly what "LODs still buggy with faces missing" looks like in hard numbers. No eyeballs needed.

### 1.5 Post-refactor comparison

After Phase D refactor lands, re-run the test scene with the same target filenames. Expected behavior change:

- `Format detection: NEW (single MeshInstance3D with ArrayMesh.surface_lod_indices, post-refactor engine pipeline)`
- `embedded_0`, `embedded_1`, `embedded_2`, etc. keys in the per-LOD summary instead of `lod1/2/3`
- Each embedded LOD level has DIFFERENT triangle counts (H9 PASS — engine pipeline produces distinct cascades)
- No "dropped sub-meshes" — ImporterMesh handles multi-surface meshes natively
- Triangle ratios (H2/H3/H4 equivalents) should approximate the engine's default cascade, probably tighter than 50/25/10%

Save post-refactor reports to `docs/audit/lod_refactor_baselines/programmatic_post_phase_d/<label>.txt` and diff against the baseline.

---

## 2. Secondary artifact — runtime at-camera dump (complementary)

The `lod_baseline_dump <label>` console command added to `src/tools/lod_debug_commands.gd` in this Phase A session is still useful — it captures what's actually rendering **at runtime**, in the main scene, at a specific camera position. Whereas the test scene (§1) captures what's **in the .res file**.

Both are valuable because:
- Test scene catches prebake-output bugs (dropped sub-meshes, simplifier no-ops, AABB collapse)
- Console dump catches runtime bugs (RS instance count drift, visibility range miscalculation, streaming failures)

**Optional runtime capture procedure:**

1. Launch `scenes/Godotwind.tscn`, wait for streaming to settle
2. Teleport to Vivec Temple district, park camera overlooking a canton
3. Open console (`` ` ``), run: `lod_baseline_dump vivec_canton_runtime`
4. Repeat at Balmora dock (`balmora_runtime`), Seyda Neen (`seyda_neen_runtime`), Ald-ruhn (`aldruhn_runtime`)
5. Copy the 4 resulting text files from `%APPDATA%/Godot/app_userdata/Godotwind/lod_baselines/` to `docs/audit/lod_refactor_baselines/programmatic_runtime/`

This is optional for Phase A — the test scene baselines (§1) are the primary deliverable. Runtime captures can be deferred to Phase D if they're not needed right now.

---

## 3. Tertiary artifact — `StreamingBenchmark` CSV

Unchanged from previous versions.

**What the benchmark does:** scripted Seyda-Neen-centered camera path (idle → approach → orbit → sprint → teleports → return, ~30 s total). Writes CSV to `user://benchmark_results/`.

**How to run:**

> **Updated 2026-04-14:** the standalone `src/tools/streaming_benchmark.tscn` scene referenced below was removed in the v1 benchmark rip-out (see `docs/audit/BENCHMARK_V2_PLAN.md`). Use the console command from a normal scene launch instead: launch `scenes/Godotwind.tscn`, open the console with `` ` ``, run `benchmark` (or the alias `bench`). Same camera path, same CSV output location. The bash invocation below no longer works and is kept for history.

```bash
# v1 (removed 2026-04-14, no longer works):
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" \
    --path "D:/Gamedev/Godotwind/godotwind" \
    res://src/tools/streaming_benchmark.tscn
```

**After the run:**
1. Find the most recent CSV in `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/`
2. Copy it to `docs/audit/lod_refactor_baselines/baseline_perf.csv`

**Critical per memory `feedback_headless_framerates.md`:** do NOT run headless. Real-renderer only.

---

## 4. Signaling completion

When all three artifact types are captured:

1. Verify `docs/audit/lod_refactor_baselines/` contains:
    - `pre_wipe_cache_manifest.txt` ✓ (already generated by `@lods`)
    - `pre_wipe_cache_filelist.txt` ✓
    - `pre_wipe_cache_filesizes.txt` ✓
    - `BASELINE_PROCEDURE.md` ✓ (this document, v3)
    - `programmatic/baseline_vivec_h_01.txt` ✓ (already generated by `@lods` in Phase A smoke run — verifies the test scene works)
    - `programmatic/baseline_tree_01.txt` — **you generate**
    - `programmatic/baseline_mushroom_bc_01.txt` — **you generate**
    - `programmatic/baseline_redoran_hut.txt` — **you generate**
    - `baseline_perf.csv` — **you generate (from `StreamingBenchmark`)**
    - `programmatic_runtime/*.txt` — OPTIONAL
2. Post in `#lods`: "baselines captured, Phase A exit criteria met"
3. Phase A closes. Phase B.0 smoke tests start next session.

---

## 5. Rollback reference

Unchanged: `git checkout pre-lod-refactor` → nuke cache → full rebake → verify 5172 files match `pre_wipe_cache_manifest.txt`.

---

## 6. Extending the test scene

If you want to add more hypotheses or test different aspects:

- `tests/visual/test_lod_baseline.gd` is ~450 lines, well-commented
- Hypothesis tests are in `_run_hypotheses()` — add new `_check_*` helper methods and call them from there
- Format detection is in `_detect_format()` — extend if a new cache format appears
- Diagnosis block is in `_append_diagnosis()` — add new diagnostic patterns here

The scene is intentionally minimal (Camera + WorldEnvironment + HUD). No dependencies on the main scene, no streaming manager, no cell loading. It's a pure resource-level inspection tool.
