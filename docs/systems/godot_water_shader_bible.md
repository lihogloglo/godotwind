# Godot Water Shader Bible

Status: Godot-side rendering rules for ocean refraction and underwater effects.
Current as of 2026-05-14, researched against official Godot 4.6/stable
documentation. This document is about how Godot works; it is not a claim about
which Godotwind code path is currently active.

## Sources

- Godot 4.6 screen-reading shaders:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/screen-reading_shaders.html
- Godot 4.6 3D rendering limitations:
  https://docs.godotengine.org/en/4.6/tutorials/3d/3d_rendering_limitations.html
- Godot 4.6 advanced post-processing:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/advanced_postprocessing.html
- Godot stable `BaseMaterial3D` refraction:
  https://docs.godotengine.org/en/stable/classes/class_basematerial3d.html
- Godot 4.6 spatial shader reference:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/shader_reference/spatial_shader.html
- Godot stable `CompositorEffect` reference:
  https://docs.godotengine.org/en/stable/classes/class_compositoreffect.html

## The Non-Negotiable Screen Texture Rule

In 3D, `hint_screen_texture` is not a live read from the framebuffer. Godot
copies the rendered scene once after opaque geometry and before transparent
geometry. A spatial material that declares `hint_screen_texture` is itself
treated as transparent and does not appear in later screen textures.

Practical consequences:

1. Screen-texture refraction can only bend what was already present in the
   opaque copy.
2. Transparent objects, other screen-reading water, transparent particles, and
   later waterline/compositor output are not inside that copy.
3. Multiple overlapping 3D screen-reading materials cannot be fixed like 2D
   `BackBufferCopy` stacks. Godot documents that 3D has less flexibility because
   the screen texture is captured once.
4. If the water shader samples `SCREEN_UV` and a shifted UV, the straight sample
   and refracted sample are both samples from the same opaque-copy source. If
   both are composed into final output through different paths, a straight
   object plus refracted duplicate is expected.

Do not debug this as if the shader can "really" refract the live scene by
changing offset constants. The buffer being sampled is the architectural limit.

## Transparent Pipeline Rule

Godot draws transparent materials after opaque materials and sorts transparent
objects back-to-front by `Node3D` position, not by each vertex or pixel. Godot
does not provide order-independent transparency. Transparent objects also do
not render to the normal-roughness buffer.

For water this means:

- Keep the hot, full-screen ocean surface out of alpha blending unless the
  architecture explicitly accepts the transparency limitations and fill cost.
- Do not rely on transparent water to cast shadows, appear in other screen
  texture refraction, or contribute to normal-roughness driven effects.
- `Render Priority` and `Sorting Offset` can change ordering among transparent
  objects, but they do not make transparent objects appear in the screen texture.
- If only binary cutouts are needed, alpha scissor/hash/depth-prepass modes are
  more stable than broad alpha blending. They are not a substitute for true
  refractive water volume rendering.

## Refraction In Godot Materials

Godot's built-in `BaseMaterial3D` refraction is screen-texture based. Official
docs state that only opaque materials appear in that refraction because
transparent materials are absent from the screen texture.

Therefore the built-in material path confirms the same rule as custom shaders:
stock Godot refraction is a screen-space distortion of an opaque scene copy, not
a physically complete water volume. It is useful for cheap glass/water
distortion, but it cannot by itself solve submerged-object waterline ownership,
underwater sky transmission, transparent particles, or multi-pass water effects.

## Depth Texture Rule

Godot 4.3+ uses reverse-Z. Depth texture values run near-to-far as `1.0` to
`0.0`, are nonlinear, and must be reconstructed before comparing scene depths
to water depths. For Forward+ and Mobile, Godot's documented normalized device
coordinates are:

```glsl
vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
view.xyz /= view.w;
float linear_depth = -view.z;
```

Depth access is current-viewport only. If a system uses a SubViewport receiver
capture, its color/depth textures are separate sources with their own timing,
resolution, camera, layer mask, and latency contract. Do not mix main-viewport
depth and receiver depth without explicitly converting them into the same
screen/camera space.

## Correct Use Of `CompositorEffect`

`CompositorEffect` is Godot's official hook for adding rendering passes at
specific renderer stages. `EFFECT_CALLBACK_TYPE_POST_TRANSPARENT` runs after
transparent rendering and before built-in post-processing/output. That is the
correct Godot hook when an effect must see the resolved scene after normal
transparent objects have drawn.

Operational constraints:

- The callback runs on the rendering thread. Treat `RenderData` as valid only
  during the callback.
- `access_resolved_color` and `access_resolved_depth` trigger MSAA resolves
  before the effect can read those buffers. They are real costs and should be
  enabled only when the effect needs them.
- `needs_normal_roughness` is Forward+ only and produces data from the depth
  pre-pass. Transparent objects are not represented there.
- Imported compute shaders are `RDShaderFile` resources. Shader edits require
  clearing the matching `.godot/imported/<shader-name>-*.res` and `.md5`, then
  forcing import before visual verification.

## Canonical Godot Architecture For Water Effects

The Godot-compatible architecture is a deliberate split, not one giant surface
shader:

1. **Opaque scene first.** Terrain, world geometry, and ordinary receivers draw
   through the normal opaque/depth path.
2. **Visible ocean surface.** The ocean surface owns wave displacement, normals,
   foam, Fresnel/specular, shore blending, and Beer-Lambert tint from scene
   depth. If it declares `hint_screen_texture`, accept that it is transparent
   and limited to the opaque screen copy. If the project needs robust ordering,
   keep the surface opaque and avoid surface-owned screen-color refraction.
3. **Special receiver capture only when needed.** Half-submerged objects that
   must bend outside their original screen footprint need a separate color/depth
   source or another explicit renderer path. A receiver SubViewport is valid,
   but it must have documented layers, camera sync, resolution, and latency.
4. **Post-transparent compositor for final waterline/underwater treatment.**
   Effects that need the final scene color after transparent rendering belong
   in `CompositorEffect.POST_TRANSPARENT`, with explicit resolved color/depth
   access and measured GPU cost.
5. **Shared water state.** Surface shader, receiver capture, wetness, caustics,
   and underwater compositor must consume one water-body/surface contract for
   height, normal, coverage, optical constants, and units. Classification drift
   is a common source of edge artifacts.

## Why Straight Plus Refracted Duplicate Happens

The typical failure is not mysterious:

1. The normal scene already drew the object straight.
2. A water/refraction path samples a shifted copy of the object from a screen
   texture or receiver texture.
3. The combine fails to fully choose one source for that pixel, or the output
   mask is based on the receiver object's original silhouette instead of visible
   water pixels.
4. The final image contains both the original straight object and the shifted
   refracted copy.

Debug the ownership, mask, and source-buffer contract before tuning refraction
strength. A stronger offset usually makes the duplicate easier to see.

## Debug Path For Godotwind

Use Ocean Lab or a similarly interactive scene; do not use auto-capture for the
human visual pass.

1. Disable custom SSR, underwater wobble, caustics, particles, wetness, and
   environment SSR. Leave only base water color/refraction.
2. Show the raw source buffers as full-screen debug views: main scene color,
   main depth, receiver color, receiver depth, final water mask, shifted UV,
   and accepted/rejected refraction mask.
   For the current Godotwind ocean surface, use surface debug modes `13`
   straight source, `14` refracted candidate source, `15` classifier/mask, `17`
   depth edge/disocclusion, `19` final sample weight, and `20` Source Blend
   before absorption/Fresnel.
3. Prove the output domain. Final waterline refraction should be written from
   visible water pixels, not from the receiver object's original screen-space
   silhouette.
4. Force refraction offset to zero. If the duplicate remains, the bug is a
   double composition path, not refraction math.
5. Hide the receiver object from the main camera while keeping it in the
   receiver capture. If the straight copy disappears, the main camera is one
   contributor. If the refracted copy disappears, the receiver capture is the
   other contributor.
6. Swap to a flat water surface normal. If the duplicate becomes a perfectly
   aligned overlay, the issue is ownership/masking. If it vanishes only with
   normals removed, the guard rejects are too weak near edges.
7. Test full-resolution receiver capture before quarter/half resolution.
   Low-resolution edge dilation can look like a refraction bug when it is
   actually a reconstruction/mask problem.
8. Re-enable features one at a time in this order: absorption, surface
   specular/SSR, underwater wobble, Snell/sky transmission, caustics, particles,
   wetness. The first re-enabled feature that brings back the duplicate owns
   the next investigation.

For every shader edit in that loop, clear the relevant shader import/cache
artifacts before the visual run.

## Rules To Preserve

- Do not claim screen-texture water can see transparent objects in Godot 4.6.
- Do not mix main depth, receiver depth, and shifted screen UVs without a named
  space conversion and validity guard.
- Do not use color delta alone as a production refraction guard; shadows,
  albedo detail, and lighting changes can produce real color differences.
- Keep final surface refraction ownership binary. If color-delta or edge guards
  are used, they should hard reject suspect samples rather than blend straight
  and shifted source colors.
- Do not put underwater camera optics in a transparent spatial volume as a
  production fallback. Use the compositor path.
- Do not call a visual water fix done until an interactive launch exercises the
  changed path after shader cache/import invalidation.
