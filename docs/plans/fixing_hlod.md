# Fixing HLOD

Date: 2026-05-06
Status: Runtime HLOD isolated; FPS and movement spikes still unacceptable.

## Current Read

HLOD is structurally isolated, but not yet cheap.

Recent checks showed:

- White/default-looking HLOD output was fixed by giving null/overflow surfaces a
  real fallback material.
- HLOD-only still performs badly: dense views remain low FPS, and movement
  spikes are still visible.
- Cached-publish budgeting and predictive cache-only prefetch did not remove
  the spikes.
- Re-enabling the OpenMW-style cost-benefit filter made distant content less
  visually complete without buying enough FPS. That change was reverted.

Current production posture:

- `RUNTIME_FORCE_MERGE_ELIGIBLE_REFS = true` is intentionally back on.
- Big buildings and landmarks must not disappear just because a merge-cost
  heuristic rejects them.
- Filtering remains desirable, but only after we have representation rules that
  preserve important coverage.
- We cannot rely on fully prebaking every possible HLOD chunk. Prior attempts
  were too large on disk.

The practical conclusion: dropping more objects is not the next fix. The next
fix is making the objects that remain cheap to publish and cheap to draw.

## Canonical Pattern

Good HLOD is not "one giant merged mesh." It is a distant representation system:

1. Cluster distant static content.
2. Reduce material and surface count.
3. Keep important silhouettes and landmarks.
4. Route unsuitable content to another distant representation.
5. Publish small, bounded render resources before they are visible.

OpenMW does this better than our current path because it filters candidates,
uses size tests, chooses when merging is worth it, can substitute LOD mesh names,
runs an OSG optimizer over static transforms/geometry, and schedules GPU compile
work incrementally.

Godot does not expose an exact equivalent of OSG's
`IncrementalCompileOperation`, so our translation must be:

- smaller runtime publish units;
- fewer materials/surfaces per unit;
- predictive warmup;
- strict publication budgets;
- no oversized `ArrayMesh` upload treated as acceptable runtime work.

## Evidence To Collect Next

Before changing policy again, capture one HLOD-only bad run and record:

- visible HLOD draw calls;
- visible HLOD chunk count;
- total and max surfaces per chunk;
- total and max materials per chunk;
- total and max vertices/indices per chunk;
- largest chunk publish time;
- largest merge completion/publish frame;
- number of chunks over the runtime surface target;
- negative/missing chunks by reason;
- whether bad FPS correlates more with draw calls or primitive count.

Acceptance should fail if HLOD-only reaches thousands of draw calls, even if the
chunk count looks low.

## Next Options

### 1. Bound Publish Units

Problem:

A frame budget can delay publication, but it cannot make one oversized mesh
upload cheap once publication starts.

Plan:

- Add hard publish limits for runtime HLOD chunks: surfaces, vertices, indices,
  estimated bytes, and material count.
- If a chunk exceeds limits, split it instead of publishing it whole.
- Split by cell, representation class, or material group.
- Keep previous/nearer representation alive until replacement parts are ready.

Expected effect:

- Movement spikes should become smaller and more frequent rather than rare huge
  frame hits.
- This does not solve steady low FPS by itself, but it attacks stutter directly.

### 2. Material Canonicalization

Problem:

The native merge groups surfaces by exact Godot `Material` instance identity.
Morrowind content creates many distinct material instances that are visually and
render-state equivalent at HLOD distance.

Plan:

- Derive a material signature from render-relevant properties:
  albedo texture path, normal texture path, alpha/cutout mode, shader family,
  blend mode, cull mode, and distant-relevant flags.
- Reuse one canonical material per signature.
- Preserve source visuals; do not replace materials with generated color buckets
  yet.
- Measure material/surface collapse before adding atlases.

Expected effect:

- Low-risk draw-call reduction if many duplicate-looking materials currently
  differ only by resource identity.

### 3. Targeted Atlases Or Texture Arrays

Problem:

Per-source-material surfaces keep HLOD draw calls high. Full per-chunk atlases
would likely recreate the disk-space problem.

Plan:

- Do not atlas every chunk.
- Start with high-repeat model/material families: common architecture sets,
  rocks, walls, and repeated settlement pieces.
- Prefer reusable source-family atlases or texture arrays over unique chunk
  atlases.
- Keep a small material budget per HLOD chunk.
- Add a debug view that shows atlas/proxy material assignment before using it
  broadly.

Expected effect:

- Steady FPS should improve by reducing texture/material state changes without
  exploding disk usage.

### 4. Representation Split

Problem:

HLOD geometry is currently asked to represent too many kinds of distant content.

Plan:

- Buildings, large rocks, bridges, and landmarks: HLOD geometry.
- Trees, shrubs, repeated organic clutter: impostors, billboards, or a dedicated
  vegetation renderer.
- Tiny clutter: drop by projected size once this is proven not to remove
  important silhouettes.
- Lights: distant-light system, not HLOD geometry.
- Doors/activators: geometry only when they are visually large or landmark-like.

Expected effect:

- Filtering becomes coverage-safe because rejected content has an intended
  alternate representation or an explicit screen-size reason to disappear.

### 5. Alternate LOD Mesh Names

Problem:

OpenMW can substitute alternate LOD mesh names when available. We currently tend
to merge near-ish source geometry.

Plan:

- Add Morrowind-adapter lookup for alternate LOD mesh names.
- Keep this outside the generic HLOD framework.
- Prefer LOD source meshes for HLOD inputs when they exist.
- Fall back to current source meshes when no alternate exists.

Expected effect:

- Lower vertex/index counts for compatible content without changing generic
  framework code.

## Recommended Order

1. Add one HLOD-only diagnostic capture that reports the worst chunks by publish
   time, surfaces, materials, vertices, and indices.
2. Enforce bounded publish units by splitting oversized runtime chunks.
3. Implement material canonicalization by render signature.
4. Prototype targeted atlas or texture-array reduction on one high-repeat content
   family.
5. Add representation-class routing so future filtering cannot delete large
   buildings or landmarks.
6. Revisit cost-benefit filtering only after representation routing exists.

This order avoids the failed pattern of trading visual coverage for little or no
performance win.

## Do Not Do

- Do not globally prebake every HLOD chunk; disk usage is already known to be too
  high.
- Do not re-enable cost-benefit filtering as a blind production default while it
  removes large buildings.
- Do not publish null-material HLOD surfaces.
- Do not use a frame budget as an excuse to publish a single oversized mesh.
- Do not solve HLOD holes by widening MID or pulling FAR inward; that hides the
  bug and makes the tier contract unclear.
- Do not put Morrowind-specific mesh-name or content rules into generic core
  HLOD code.

## Done Criteria

HLOD is not fixed until:

- HLOD-only interactive traversal holds acceptable FPS in dense views.
- Normal movement does not produce recurring visible publish spikes.
- Visible HLOD draw calls/materials/surfaces are bounded.
- Oversized chunks are split, deferred, or routed elsewhere.
- Large buildings and landmarks remain visible in the 300-1000m band.
- Missing content is intentional and explainable by representation policy.
- The generic HLOD framework remains data-source agnostic.

## Plain English

Filtering alone made the world cheaper-looking, not faster enough. That means
the problem is deeper than object count. The next fixes should make HLOD chunks
smaller to publish and cheaper to draw: fewer surfaces, fewer materials, smaller
upload units, and smarter routing for trees/clutter/lights. Once important
coverage has another safe path, filtering can come back as a scalpel instead of
an axe.
