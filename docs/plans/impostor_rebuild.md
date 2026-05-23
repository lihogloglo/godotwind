# Impostor Pipeline Rebuild — Design Doc

**Status:** Phases 1-3 shipped. v5 baker + inline shader (v4+v5 dual variant) live. Dead `octahedral_impostor.gdshader` deleted 2026-04-12. 12/937 impostors rebaked to v5; rest still v4 (functional, lower quality). Full v5 rebake pending.
**Owner:** `@impostors` (claude)
**Scope:**
- `src/tools/prebaking/impostor_baker_v2.gd` → rebuilt as `impostor_baker_v3.gd`
- `src/core/world/native_impostor_renderer.gd` `_get_octahedral_shader_code()` (embedded runtime shader block) → rebuilt as Variant B below
- `src/tools/prebaking/shaders/octahedral_impostor.gdshader` → **DELETED 2026-04-12**. Was dead code — not referenced by any runtime code path. `distant_light_manager.gd` comment updated to reference inline shader. `LIGHTING_AUDIT.md` updated.
**Related:** `docs/systems/distance_rendering.md` (FAR tier 500m-5km), `src/core/world/distance_utils.gd`, `docs/plans/groundcover.md`, `docs/reference/aaa_framework_gap_analysis.md` section 3 (grass is a separate pipeline; see "Relation to groundcover" below)

---

## 2026-05-02 Production Update

- v5 bakes now default to hemi-octahedral projection for ground-rooted assets. Full sphere remains a metadata-supported override for future assets that can be viewed from below or all around.
- v5 runtime/bake resolution is now 512x512 per atlas (8x8 views at 64 px/view). The old 256x256 atlas was acceptable for small objects but under-sampled large Vivec/Hlaalu landmarks at the 1 km handoff.
- v5 metadata stores `bounds.capture_size`, matching the orthographic square used during capture. Runtime uses this value for billboard scale instead of raw AABB width/height, avoiding padded-atlas origin/scale drift.
- Runtime v5 cards now use camera-plane billboarding so elevated 1 km validation views do not see yaw-locked vertical cards.
- The validation scene starts at a 1 km elevated camera, overlays original meshes, and includes an automatically moving point light plus directional sun controls.
- `src/tools/prebaking/full_rebake_headless.tscn -- --impostors-only` is the unattended v5 rebake path. Use `--max-impostors=N` for a bounded smoke run.

---

## 1. Problem Statement

The current FAR-tier impostor system produces visibly wonky results, especially after normal maps were added. The user's instinct — "I'm not sure the way we do this is industry standard by any mean" — is correct. The code is named "octahedral" but the actual technique is a 16-sample azimuthal billboard with a hand-rolled normal pass bolted on top. Several implementation details break standard normal-map math.

This doc audits the current pipeline against the canonical industry pattern (Ryan Brucks, "Advanced Octahedral Impostor System", Epic 2015–2017, [shaderbits.com](https://www.shaderbits.com/blog/octahedral-impostors)) and proposes a full rebuild. Per `.claude/CLAUDE.md` "Industry Standard, Never Kludge" — the canonical pattern exists, every major engine uses it, we adopt it directly.

## 2. Audit — What's Wrong With The Current Pipeline

### 2.1 "Octahedral" in name only

`impostor_baker_v2.gd:24` — `OCTAHEDRAL_DIRECTIONS` is 16 unit vectors all with `y = 0`. The camera rotates around the Y axis in 22.5° steps. There is no elevation variation and no octahedral projection. When the player looks down from a hill or flies the debug camera overhead, every impostor shows the same horizontal side view. Silhouettes are wrong the moment the pitch deviates from 0.

True octahedral impostors (Brucks, UE4 Impostor Baker plugin, Crytek vegetation, Godot community addons) sample an N×N grid of camera positions on the (hemi)sphere, using octahedral projection to map 3D directions onto a 2D atlas. A 12×12 atlas gives 144 distinct views across the full visible hemisphere, each with proper parallax and silhouette coverage.

### 2.2 MSAA 4× corrupts normal capture

`impostor_baker_v2.gd:90` sets `_viewport.msaa_3d = Viewport.MSAA_4X`. MSAA's linear resolve averages encoded normal values (`[0,1]` RGB) across multi-sampled silhouette edges. Encoded normals do not survive linear averaging — the blended values decode to garbage in the 1–2 px border where lighting transitions are most visible. Standard fix: MSAA off for the normal pass, keep it on the albedo pass, or use alpha-to-coverage without multi-sample resolve.

### 2.3 No renormalization after filtering or frame blending

**Scope correction per reviewer:** this audit item partially applies.

- The dead standalone shader (`octahedral_impostor.gdshader:92-94`) does use 2-frame `mix()` blending — confirmed broken there, but that shader isn't live.
- The live runtime shader (`native_impostor_renderer.gd:404-407`) picks **one** frame with no inter-frame blend, so the 2-frame lerp bug does not apply there. What *does* still apply is bilinear filtering within a single frame (`filter_linear_mipmap` at `:341`) and mipmap minification, both of which average neighboring texels in RGBA8 encoded-normal space. The magnitude decay is milder than with explicit frame-blending but still present, and it gets dramatically worse once tri-sample blending is added in Variant B (three samples blended by barycentric weights = three places that need post-blend renormalization).

The canonical fix stays the same, just framed as "required for the v5 rebuild" not "critical now": (a) higher-precision normal format (see addendum B below — **BC5/RGTC is the industry standard**, not RGBA16F), (b) renormalize after every texture read and every blend, (c) prefer `hint_normal` for tangent-space normals where Godot auto-renormalizes — but this pipeline uses (at capture time) world-space normals so we must do it manually.

### 2.4 Baked normals not rotated by instance yaw

`native_impostor_renderer.gd:404` reads `INSTANCE_CUSTOM.y` as `rotation_offset` and subtracts it from the view angle when selecting the atlas frame. This is correct for *picking* the right frame — a tree baked facing north, then placed rotated 90°, correctly shows its east-facing frame when the camera looks from the north. However, line 453 then does:

```gdscript
NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
```

The `world_normal` it just decoded is still in *bake-time world space* — the coordinate frame of the baker's viewport, which had the tree at rotation 0. For any instance placed in the world at non-zero yaw, the baked normal is rotated wrong by exactly the instance's yaw offset. Result: ~90% of trees in the live world (anything not perfectly aligned to the bake axis) are lit with normals that don't match their actual orientation. This is probably the single biggest contributor to the "wonky" look the user reported.

### 2.5 Parallax offset computed in world-space XY

`native_impostor_renderer.gd:423`:

```gdscript
vec2 parallax_offset = vec2(view_dir.x, -view_dir.y) * parallax_depth * (1.0 - depth) * parallax_fade;
```

`view_dir` is the world-space vector from the impostor center to the camera. Taking its raw `.xy` and using it as a UV offset assumes the billboard is axis-aligned with the world, which it isn't — the billboard is rotated to face the camera, so its tangent frame changes every frame. Brucks's method builds a tangent-space basis from the billboard quad and transforms the view direction into that basis before computing the offset:

```glsl
vec3 view_ts = TBN_inverse * view_dir_world;
vec2 offset = (view_ts.xy / view_ts.z) * depth * strength;
```

The current math happens to produce something that *looks* like parallax when the camera is roughly level, but it's directionally wrong as soon as the camera orbits, and the sign flip on `view_dir.y` is a giveaway that someone was patching symptoms.

### 2.6 `shadows_disabled` — flat lighting at the handoff distance, but the fix has a trap

`native_impostor_renderer.gd:338`:

```glsl
render_mode blend_mix, depth_prepass_alpha, cull_disabled, shadows_disabled;
```

Impostors do not receive cascade shadow maps. At the 500 m MID→FAR handoff, a lit MID-tier tree popping into an unlit FAR-tier impostor is a visible discontinuity.

**Trap (per reviewer addendum D):** simply dropping `shadows_disabled` enables both *receive* and *cast*. Casting shadows from a flat camera-facing quad produces rectangular billboard shadows on the terrain at 500 m+, which is almost certainly why the flag is off today. That would ship a worse artifact than the original "flat lighting" problem.

**The fix must split the two cases:**

1. **Receive shadows: YES.** Fixes the handoff discontinuity. Cheap — one quad per instance. This is the audit's stated goal.
2. **Cast shadows: NO** by default, or cast via a separate cheap proxy (capsule/cylinder per instance, MultiMesh'd through a shadow-only pass). Brucks's standard approach is "impostor receives, low-poly proxy casts" — the proxy is the existing MID-tier LOD 2/3 mesh, reused in the shadow pass only.

Godot's `render_mode` has `shadows_disabled` (both off), `shadow_to_opacity`, and material-level `cast_shadow` modes (`SHADOW_CASTING_SETTING_OFF`, `SHADOW_CASTING_SETTING_ON`, `SHADOW_CASTING_SETTING_DOUBLE_SIDED`, `SHADOW_CASTING_SETTING_SHADOWS_ONLY`). The exact GeometryInstance3D property is `cast_shadow` on the MultiMeshInstance3D. Confirmed path: set `cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF` on the MultiMeshInstance3D, and remove `shadows_disabled` from the shader `render_mode` so receive is enabled. Verify in phase 2 by enabling CSM visualization in the debug overlay.

### 2.7 Stale NORMAL_MATRIX in the billboard vertex shader

The vertex shader at `native_impostor_renderer.gd:390` rebuilds `MODELVIEW_MATRIX` from scratch but never touches `NORMAL_MATRIX`. Godot derives `NORMAL_MATRIX` from the original model transform, so it no longer matches the billboard orientation. The system only works because the fragment shader overrides `NORMAL` directly with the decoded world-space value. This is a latent bug — any future work that uses tangent-space normals or interpolates mesh normals will break silently.

## 3. Reference Pattern — Octahedral Impostors

**Primary reference:** Ryan Brucks, "Advanced Octahedral Impostor System", Epic Games 2015–2017. Published at [shaderbits.com/blog/octahedral-impostors](https://www.shaderbits.com/blog/octahedral-impostors). Ships as the built-in Impostor Baker in UE4/5.

**Secondary references:**
- Crytek, "Vegetation Impostors" (GDC 2013) — the `CryEngine` approach, ~32 hemi views.
- Bevy `bevy_octahedral` community crate — same technique, open-source GLSL port.
- `godot-impostor` community addon (archived) — Godot 3 port of Brucks's shader.

**Core ideas we adopt:**

1. **Octahedral direction encoding.** A 3D unit vector maps to a 2D UV via octahedral projection. The inverse maps any UV in an N×N atlas back to a unique view direction. This packs a sphere (or hemisphere) into a square grid with low distortion.
2. **Tri-sample blending.** For a given view direction, the three nearest atlas cells form a triangle in the octahedral grid. Sampling all three and blending via barycentric weights gives smooth angular transitions with no visible frame popping. (Current pipeline uses 2-frame linear blend, which pops at grid diagonals.)
3. **Parallax via baked depth.** The depth pass writes view-space depth into the alpha channel of the normal atlas. At runtime, the view direction in tangent space drives a parallax offset against that depth, faking 3D volume. Brucks's refinement is "depth-corrected parallax" — iteratively refines the offset using the depth gradient.
4. **World-space or local-space normals.** Brucks uses object-local normals, stored with RG16 (XY only, Z reconstructed) for precision. We'll evaluate RGBA16F vs RG16 during phase 2 — local-space + per-instance yaw rotation is the correct approach for our use case (trees placed at arbitrary rotations).
5. **Single draw call.** Everything lives in texture arrays keyed by instance custom data. One MultiMesh per impostor batch. Our current pipeline already does this and must preserve it.

## 4. Rebuild Plan

### Phase 1 — Baker v3 (`impostor_baker_v3.gd`)

- [ ] Octahedral direction generator: `Vector3 octahedral_to_direction(Vector2 uv)` and inverse.
- [ ] **Sphere coverage — UNRESOLVED, pending user tiebreak.** User said "full sphere (maximalist), we have some floating assets" 2026-04-08. Reviewer countered with "hemi only, no flying assets in `impostor_candidates.gd`" same day. These contradict. **Proposed resolution:** default hemi (reviewer is right for the current asset list, and hemi is half the bake time + half the atlas density), BUT store `"projection": "octahedral_hemi"` vs `"octahedral_full"` in metadata per-asset, so individual floating assets can opt into the full-sphere bake without touching the framework. This gives us the generic-framework guarantee the user asked for without paying the cost on 99% of ground-rooted models. Flag for user sign-off before phase 1 starts.
- [ ] **Per-asset grid size tiering** (per reviewer recommendation): **12×12 (144 views) for hero assets, 8×8 (64) for small props**. Hero = trees, menhirs, large rocks, buildings. Small props = rocks < 2 m, stumps, crates. 8×8 alone is too coarse at the 500 m handoff (angular step ~22.5° → visible popping on orbit). 12×12 ≈ 15° step, imperceptible with tri-sample blend. Classification drives off the existing `impostor_candidates.gd` bounds-based tagging — reuse, don't reinvent. Metadata stores the actual grid per asset so the runtime shader knows how to decode.
- [ ] Two-pass bake per model:
  - **Albedo pass:** existing MSAA 4× viewport, unlit ambient, `BG_COLOR` transparent. Keep as-is.
  - **Normal+depth pass:** *separate* viewport with `MSAA_DISABLED`, same camera rig, ShaderMaterial override writing `(world_normal * 0.5 + 0.5, linear_depth)`. Separate viewport is cleaner than toggling MSAA between passes because it avoids viewport recreation churn.
- [ ] Atlas format (**revised per reviewer addendum B — BC5/RGTC is the industry standard, NOT RGBA16F**):
  - Albedo atlas: PNG RGBA8, sRGB. As today.
  - Normal atlas target format: **BC5 (RGTC2)** — 2-channel compressed, reconstruct Z as `sqrt(1 - x² - y²)` in the shader, 8 bpp. Half the VRAM of RGBA8, quarter of RGBA16F. UE, Unity HDRP, id Tech 6/7, Source 2 all converged on this. Godot supports RGTC via `Image.compress(COMPRESS_BPTC)` for BC7 or the dedicated RGTC path where available.
  - Pipeline: bake to RGBA16F in-memory in the SubViewport (no precision loss during capture), then on save compress to BC5 via Godot's image compression API. Store as `.res` (ImageTexture resource) to bypass the import pipeline entirely and avoid the sRGB trap from addendum C.
  - Fallback: if the BC5 compression path is painful in Godot 4.6 (verify — the API has quirks), ship RGBA16F uncompressed as a temporary bridge with a dated TODO to revisit, per CLAUDE.md "time-boxed bridges only" rule.
  - **Banned:** RGBA8 PNG for normals. That's the current format and it is one of the reasons lighting is wonky — see addendum C below for the sRGB double-gamma trap.
- [ ] **Addendum C — verify the normal atlas is not sRGB-decoded on load.** `impostor_baker_v2.gd:299` saves the normal atlas as PNG. Godot's import pipeline may flag PNGs as sRGB depending on the `.import` preset. If the atlas sampler decodes sRGB → linear on load, the encoded normal values get an unintended gamma curve applied at sample time = visibly "wonky" shading even if everything else is correct. The runtime shader declares `normal_atlas : filter_linear_mipmap` (no `source_color` hint) — correct at *sample time* — but the stored `.import` preset may still be applying sRGB conversion at *load time*. Mitigation: (a) bake directly to `.res` ImageTexture resource (bypasses import pipeline entirely), or (b) generate a matching `.import` file explicitly marked linear. Go with (a) — it's cleaner and matches how we should have been doing this from day one.
- [ ] Frame size: keep 128 default, expose as a per-model override in metadata for hero assets (trees, rocks). `impostor_candidates.gd` can tag candidates by type.
- [ ] Metadata bump to `bake_version = 5`:
  - `"projection": "octahedral_full"` (or `"octahedral_hemi"` if we add a hemi mode later)
  - `"grid_size": 12`
  - `"normal_format": "rgba16f"`
  - `"has_octahedral": true` — runtime loader checks this flag to pick the shader variant
- [ ] Backwards compat: keep `bake_version = 4` loader path alive. Old bakes render via the legacy shader until re-baked. Re-bake is a batch operation over the existing `impostor_candidates` list.

### Phase 2 — Shader rebuild

Two shader variants, both in `native_impostor_renderer.gd::_get_octahedral_shader_code()` as INSTANCE_CUSTOM.w-driven branches:

**Variant A — legacy v4 bakes:** keep the current azimuthal 16-frame path unchanged. Selected when `has_octahedral == false`. Ensures we don't break existing bakes mid-migration.

**Variant B — new v5 octahedral:**

- [ ] Vertex: keep billboard construction, **also update `NORMAL_MATRIX`** to match the billboard basis. Fixes audit §2.7.
- [ ] Build TBN from billboard quad basis (tangent = right, bitangent = up, normal = look_dir). Pass to fragment as a mat3 varying.
- [ ] Fragment:
  - [ ] Compute local-space view direction: `vec3 view_local = (transpose(instance_yaw_basis) * world_view_dir)`. The `instance_yaw_basis` comes from `INSTANCE_CUSTOM.y` (same `rotation_offset` we already store). Fixes audit §2.4.
  - [ ] Encode `view_local` via octahedral projection to `vec2 oct_uv`.
  - [ ] Find the three nearest grid cells (tri-sample neighbors) — this is Brucks's barycentric lookup. Reference impl: [shaderbits Octahedral Impostor Material Functions](https://www.shaderbits.com/blog/octahedral-impostors) §"Triangle Blending".
  - [ ] Sample albedo atlas at all three frames, blend by barycentric weights. No more 2-frame lerp.
  - [ ] Sample normal atlas at all three frames. If BC5: sample two channels (XY), reconstruct Z as `z = sqrt(max(0, 1 - x*x - y*y))` per sample, blend reconstructed vectors by barycentric weights, then `normalize()`. If RGBA16F fallback: sample, decode `*2-1`, blend, `normalize()`. Fixes audit §2.3.
  - [ ] Rotate decoded local normal back into world space via the instance yaw basis, *then* into view space via `VIEW_MATRIX`. Fixes audit §2.4 definitively.
  - [ ] Tangent-space parallax: `view_ts = TBN_inv * view_world; offset = view_ts.xy / view_ts.z * depth * strength`. Clamp to frame bounds. Fixes audit §2.5.
  - [ ] Drop `shadows_disabled`. Add `depth_draw_always`. Fixes audit §2.6. Measure shadow cost at worst case (5000 instances in frustum) — if > 0.3 ms, add `shadows_receive_only` or a distance ramp.
  - [ ] Keep `cull_disabled` — we still need both sides of the quad.

### Phase 2.5 — Baseline benchmark (BEFORE any rebuild work lands)

Per reviewer: no "looks better" hand-waving. Capture ground-truth numbers on the current v4 pipeline first, so the rebuild has something concrete to beat.

- [ ] Bring up the phase-3 validation scene (10×10 rotated-tree grid) against the **current** v4 bakes unchanged.
- [ ] Record: average frame time on the FAR tier draw, peak frame time during camera orbit, total impostor VRAM footprint (texture arrays + metadata), draw call count, visible popping events per 360° orbit (count manually).
- [ ] Save the numbers in this doc under "Baseline (v4)" before touching baker_v3.
- [ ] Re-run the same numbers after v5 ships, side-by-side comparison. Any regression > 10% on any metric requires justification or rollback.

### Phase 3 — Validation

Per `.claude/CLAUDE.md` no-auto-capture rule: all visual verification is interactive. User pilots the camera.

- [ ] **Test scene** `tests/visual/test_impostor_v5.tscn`:
  - 10×10 grid of baked Vvardenfell trees (`flora_tree_*.nif`) at random yaw rotations.
  - Sun direction bound to a slider (0–360° azimuth, 0–90° elevation) — drive from the unified input system per `docs/systems/input_system.md` §6.
  - Side-by-side: NEAR tier ground truth on the left, FAR tier impostor on the right. User pilots between them.
  - Visual pass/fail criteria:
    - (a) Rotated instances light correctly as the sun moves. (Audit §2.4.)
    - (b) No fringe artifacts on silhouettes. (Audit §2.2, §2.3.)
    - (c) Smooth angular transition with no frame popping as camera orbits. (Audit §2.1, §2.3.)
    - (d) Cascade shadows land on impostors at the 500 m handoff. (Audit §2.6.)
    - (e) Parallax visibly shifts inner details as camera orbits, in the correct direction. (Audit §2.5.)
- [ ] **Perf budget:**
  - Single draw call per batch preserved. Non-negotiable. Validate via Godot debugger → Visual → Drawing.
  - VRAM cap: 128 MB total impostor texture memory. RGBA16F normal atlas ≈ 2× RGBA8 footprint. At 12×12 × 128 px × 2 bytes per channel × 4 channels = 1.1 MB per impostor normal atlas. Budget supports ~100 unique impostors at that density. Validate `impostor_candidates.gd` current count.
  - Frame time: FAR tier total < 1.5 ms on target HW (user to specify).
- [ ] **Regression checks:**
  - Verify streaming handoff MID→FAR at 500 m still hysteretic (no flicker).
  - Verify legacy v4 bakes still render via Variant A (backwards compat path).

### Phase 4 — Migration

- [ ] Implement both shader variants, test Variant A with existing bakes first (should be a no-op refactor).
- [ ] Implement baker v3, bake a handful of hero models by hand, validate via test scene.
- [ ] Batch re-bake via existing `impostor_candidates.gd` prebake flow — dump into a new subdirectory (`cache/impostors/v5/`) so rollback is a single config flag.
- [ ] Runtime loader toggles based on `bake_version` in metadata — no flag day.
- [ ] Delete legacy paths only after the full Vvardenfell asset list has been re-baked and validated, in a follow-up commit.

## 5. Relation To Groundcover / Grass

Current authority: `docs/plans/groundcover.md`.

The older Terrain3D Instancer direction is superseded. Groundcover should be a source-neutral provider contract plus a chunked `MultiMeshInstance3D` renderer. The Morrowind adapter owns ESP/NIF/ref parsing and emits normalized placement batches; framework code should not know that the source uses grass ESPs, NIF paths, or Morrowind cell refs.

Grass blades are tiny and numerous, so they remain outside the octahedral impostor rebuild. Impostoring them would be both overkill for near grass and under-kill for the count profile.

**However:** the far-tier distant grass band (the fuzzy color strip on the horizon in any open-world game) could share infrastructure with this system. That's a phase-5 exploration — out of scope for this rebuild. Flag for future work: if distant grass lands in the 500 m+ range, evaluate whether a "grass card" impostor variant (1 frame, no rotation, depth-faded) fits into the octahedral pipeline or needs its own path.

Note for the groundcover work whenever it starts: the "rebuild impostor normal math correctly" outcome of this plan is a prerequisite. Any future tier that stacks on FAR impostors inherits whatever we ship here.

## 6. Open Questions

1. **Full sphere vs hemi — user tiebreak needed.** User said full sphere (maximalist framework). Reviewer countered with hemi (no flying assets in current candidate list). Proposed compromise: hemi default, per-asset `"projection"` flag in metadata so floating assets opt into full sphere. **Blocks phase 1 start.**
2. **Grid size.** Resolved per reviewer: 12×12 for hero assets, 8×8 for small props, driven off existing `impostor_candidates.gd` bounds classification.
3. **Normal format.** Resolved per reviewer addendum B: BC5/RGTC target, RGBA16F fallback if Godot 4.6 BC5 path is painful, no RGBA8 PNG.
4. **sRGB import trap.** Resolved per reviewer addendum C: bake to `.res` ImageTexture resource, bypass the import pipeline entirely.
5. **Shadow cast/receive split.** Resolved per reviewer addendum D: receive YES, cast NO (or cast via MID LOD proxy in shadow-only pass). Exact Godot property path documented in §2.6.
6. **Shadow receiving cost.** Unknown until measured. Fallback plan: distance-ramped receive (full at 500 m, fade out at 2 km).

## 6.5 Baseline Numbers (v4, current pipeline)

_To be filled in during Phase 2.5 before any rebuild work lands. Placeholder._

| Metric | v4 (baseline) | v5 (target) | v5 (measured) |
|---|---|---|---|
| FAR tier avg frame time | TBD | ≤ baseline × 1.1 | TBD |
| FAR tier peak frame time | TBD | ≤ baseline × 1.1 | TBD |
| Total impostor VRAM | TBD | ≤ 128 MB | TBD |
| Draw calls | TBD | = baseline | TBD |
| Popping events per 360° orbit | TBD (likely many) | ≤ 1 | TBD |
| Rotated-instance lighting correctness | visibly wrong | correct | TBD |

## 7. Non-Goals

- Runtime impostor generation (on-the-fly baking). Prebake only, as today.
- Animated impostors (wind, trees swaying). Out of scope — handled by the wind buffer at MID tier and lost at FAR.
- Impostor shadow casting. Receive only in v5. Casting is a phase-5 follow-up if needed.
- Compute-shader culling. Nice to have per `MASTERPLAN.md` but orthogonal to this rebuild.

## 8. References

- Ryan Brucks, "Advanced Octahedral Impostor System" — [shaderbits.com/blog/octahedral-impostors](https://www.shaderbits.com/blog/octahedral-impostors)
- Ryan Brucks, "Octahedral Impostors Part 2: Triangle Blending" — same blog
- Epic Games, UE4/5 Impostor Baker plugin source
- Crytek, "Vegetation in CryEngine 3" (GDC 2013)
- `.claude/CLAUDE.md` — "Industry Standard, Never Kludge" engineering principle
- `docs/systems/distance_rendering.md` — 3-tier LOD contract
- `docs/reference/aaa_framework_gap_analysis.md` §3 — groundcover plan (separate pipeline)
