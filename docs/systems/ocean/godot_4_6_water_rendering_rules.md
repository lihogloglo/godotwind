# Godot 4.6 Water Rendering Rules

Status: stable renderer-rule document for Godot 4.6. Last fact-checked against
primary sources on 2026-05-26.

Scope: this document says what Godot 4.6 allows or makes expensive when
rendering water. Godotwind targets the Forward+ renderer; Mobile-only renderer
costs are called out as non-project context when they appear in source docs. It
does not describe the current Godotwind implementation; use
`docs/systems/ocean/architecture.md` for that.

Update policy: every rule below has an explicit source. Do not add a new
"clean Godot way" claim here without adding a primary source row to the claim
ledger.

## Claim Ledger

| ID | Fact-checked claim | Primary source | Godotwind rule |
| --- | --- | --- | --- |
| G46-WATER-001 | In 3D, Godot copies the screen texture after opaque geometry and before transparent geometry, so transparent objects are not captured in `hint_screen_texture`. | Godot 4.6 screen-reading shaders: https://docs.godotengine.org/en/4.6/tutorials/shaders/screen-reading_shaders.html | Surface-shader refraction can use `hint_screen_texture` only as an opaque-scene screen-space approximation. |
| G46-WATER-002 | In 3D, materials using `hint_screen_texture` are considered transparent, the 3D screen texture is captured once, and Godot recommends a Viewport with a matching camera when that back-buffer contract is not enough. | Godot 4.6 screen-reading shaders: https://docs.godotengine.org/en/4.6/tutorials/shaders/screen-reading_shaders.html | Do not try to fix missing transparent/later water content by tuning screen-texture offsets. Use an explicit capture path when the source buffer must be controlled. |
| G46-WATER-003 | Godot depth texture values are current-viewport values, reverse-Z in Godot 4.3+, nonlinear, and must be reconstructed before world/view-space comparison. | Godot 4.6 advanced post-processing: https://docs.godotengine.org/en/4.6/tutorials/shaders/advanced_postprocessing.html | Every water depth test must name its depth space and reconstruction path. |
| G46-WATER-004 | `CompositorEffect` is Godot's custom render-pass hook; `POST_TRANSPARENT` runs after transparent rendering and before built-in post-processing/output. Godot marks the API experimental, so exact API details may change across engine versions. | Godot 4.6 `CompositorEffect`: https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html | Full-frame underwater medium and final waterline treatments that need the rendered transparent scene belong in a compositor, not in a transparent spatial volume; isolate the integration behind Godotwind code instead of scattering direct API assumptions. |
| G46-WATER-005 | `CompositorEffect.access_resolved_color` and `access_resolved_depth` trigger MSAA color/depth resolves when MSAA is enabled. | Godot 4.6 `CompositorEffect`: https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html | Compositor water effects must declare exactly which resolved buffers they read and must be profiled. |
| G46-WATER-006 | Godot's Mobile/tile renderer docs say screen/depth texture reads can force intermediate render results to be written out, limiting subpass-friendly rendering and causing a notable performance penalty. This specific subpass penalty is Mobile/tile-renderer context, not a Forward+ project rule. | Godot 4.6 internal rendering architecture: https://docs.godotengine.org/en/4.6/engine_details/architecture/internal_rendering_architecture.html | Godotwind is Forward+ only: do not cite Mobile subpass costs as the reason for a design decision. Still treat full-screen screen/depth reads as budgeted water features because Forward+ screen capture, depth reconstruction, MSAA resolves, and bandwidth are real renderer costs that must be profiled locally. |
| G46-WATER-007 | Reading or writing `ALPHA` in a spatial shader sends the material through the transparent pipeline, and transparent shaders can have sorting issues. | Godot 4.6 spatial shader reference: https://docs.godotengine.org/en/4.6/tutorials/shaders/shader_reference/spatial_shader.html | Keep the hot ocean surface out of broad alpha blending unless the architecture explicitly accepts transparent sorting and fill-cost tradeoffs. |
| G46-WATER-008 | Godot draws transparent materials after opaque materials, sorts transparent objects by `Node3D` position, does not write transparent objects to the normal-roughness buffer, and does not provide order-independent transparency. | Godot 4.6 3D rendering limitations: https://docs.godotengine.org/en/4.6/tutorials/3d/3d_rendering_limitations.html | Do not design production waterline ownership around many overlapping transparent spatial materials. |
| G46-WATER-009 | A `SubViewport` is a render target whose texture can be sampled elsewhere. | Godot 4.6 Viewports tutorial: https://docs.godotengine.org/en/4.6/tutorials/rendering/viewports.html | Receiver-only waterline refraction may use a SubViewport capture, but the capture must document camera sync, layer masks, resolution, frame age, and depth-space conversion. |
| IND-WATER-001 | Unreal Single Layer Water uses a custom water pass that can use opaque or masked materials; the pass reads already rendered/lit scene color and depth for refraction/translucency and can downsample those inputs for performance. | Unreal 4.27 Single Layer Water: https://dev.epicgames.com/documentation/unreal-engine/single-layer-water-shading-model?application_version=4.27 | The industry shape is explicit water passes with named scene color/depth inputs, not an ordinary transparent material pretending it owns the whole frame. |
| IND-WATER-002 | GPU Gems 2's refraction method renders non-refractive scene content into a source image, then uses a mask to avoid perturbing the wrong pixels. | GPU Gems 2, Chapter 19: https://developer.nvidia.com/gpugems/gpugems2/part-ii-shading-lighting-and-shadows/chapter-19-generic-refraction-simulation | Straight-plus-refracted duplicate bugs are source/mask ownership bugs before they are offset-strength bugs. |
| IND-WATER-003 | Crest uses water depth information to attenuate large waves in shallow water, generate shoreline foam, and support shallow-water shading; its documented path is an ocean-depth cache. | Crest Shorelines and Shallows: https://crest.readthedocs.io/en/4.10/user/shallows-and-shorelines.html?rp=hdrp | Godotwind shore behavior should remain data-driven from a shore/depth mask instead of ad hoc fragment-only shoreline tricks. |
| IND-WATER-004 | GPU Gems describes real-time caustics as an approximation; its chapter explicitly frames the method as aesthetics-driven rather than physically exact. | GPU Gems, Chapter 2: https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-2-rendering-water-caustics?lang=en | Caustics should stay a separate visual layer and should not be allowed to decide waterline ownership or submerged-object classification. |
| OBS-WATER-001 | Boujie Water Shader is a Godot 4.x screen-reading water shader with refraction, Snell's window, depth fog, distance fade, and feature fade controls. | Chrisknyfe/boujie_water_shader README: https://github.com/Chrisknyfe/boujie_water_shader | Treat Boujie as a practical Godot-native reference for visually stable screen-space water, not as proof that Godot screen textures solve exact receiver ownership. |
| OBS-WATER-002 | Boujie's `zb/fix_refraction_distance_fade` shader branch scales refraction down with camera distance, writes sampled screen color through `EMISSION`, darkens `ALBEDO` by the same blend amount, and deliberately avoids setting `ALPHA` as the refraction opacity. | Chrisknyfe/boujie_water_shader branch `zb/fix_refraction_distance_fade`, commit `444067b4a39b28d0b9e2e0caf541ccf485723b73`, `addons/boujie_water_shader/shader/water.gdshader`; local adaptation: `src/core/water/shaders/ocean_boujie_experimental_common.gdshaderinc` | For Godotwind's production surface refraction refactor, prefer the Boujie-style perceptual method over the current controlled-source compositor unless exact receiver replacement is explicitly required. |

## Consequences For Godotwind

Each architecture consequence below is derived from the claim ledger above.

| Consequence | Evidence |
| --- | --- |
| Surface, underwater, wetness, receiver capture, and buoyancy systems should consume one shared water contract for water height, coverage, body ID, shore data, render mesh metadata, and optical coefficients. | G46-WATER-003, G46-WATER-009, IND-WATER-001, IND-WATER-003 |
| The visible ocean mesh should own wave displacement, normals, foam, Fresnel/specular, and shore waves as an opaque baseline. Above-water refraction that needs controlled source ownership should be a separate bounded layer with explicit source capture, not a screen-reading mutation of the main ocean material. | G46-WATER-001, G46-WATER-002, G46-WATER-006, IND-WATER-001, IND-WATER-002, IND-WATER-003 |
| Whole-frame underwater absorption/fog and later camera-underwater wobble or sky transmission should be compositor-owned. | G46-WATER-004, G46-WATER-005, IND-WATER-001 |
| Half-submerged receiver refraction needs an explicit capture/compositor path with documented layer, source, mask, depth, latency, and budget contracts. | G46-WATER-002, G46-WATER-003, G46-WATER-004, G46-WATER-005, G46-WATER-009, IND-WATER-002 |
| Wetness should stay separate from underwater optical medium and receiver waterline ownership. | G46-WATER-004, G46-WATER-008, IND-WATER-004 |
| Production surface refraction should use the Boujie-style screen/emission method as the default practical path, while keeping controlled-source replacement as a quarantined exactness path for special receiver-waterline cases. | G46-WATER-001, G46-WATER-002, G46-WATER-007, G46-WATER-008, OBS-WATER-001, OBS-WATER-002 |

## Nota Bene: Correctness Versus Shipping Water

The previous Godotwind docs often described the controlled source/compositor
architecture as "the correct way" to do refraction in Godot. That statement is
too broad.

The controlled-source architecture is still the cleanest known answer for one
specific problem: exact ownership of a pixel where a receiver object crosses
the waterline. It gives us an explicit color source, explicit depth source,
explicit water/receiver masks, explicit source camera matrices, and a final pass
that can choose one owner for the pixel. In renderer-design terms, that is the
right family of solution for preventing straight-plus-refracted duplicate
silhouettes.

But it has not been the right practical answer for Godotwind's open-ocean
surface refraction. It has stayed expensive and fragile across many sessions:
source capture, copy timing, full-screen compute, MSAA resolves, depth-space
reconstruction, dynamic FFT/shore classification, candidate ray/depth solves,
and rejection masks all have to agree. When any one of those contracts drifts by
a little, the failure is not subtle: halos, double outlines, missing refracted
pixels, stale source frames, or visible hard gates.

Therefore the production policy is:

- Use the Boujie-style perceptual refraction method for the default visible
  ocean surface.
- Keep controlled-source compositor refraction quarantined as an exact
  receiver-waterline tool, not as the main ocean-surface path.
- Do not call the controlled-source path "best possible" without the qualifier
  "for exact receiver ownership." For shipped surface water, "works, is stable,
  and looks good in motion" wins over a purer model that repeatedly fails its
  visual acceptance test.

This is not a retreat from the industry-standard rule. It is applying the rule
honestly. Unreal's Single Layer Water and GPU Gems both point toward explicit
water passes and named buffers when the renderer gives you those facilities.
Stock Godot 4.6 does not expose the same mature water pass. Godot's screen
texture path is limited, and `CompositorEffect` is powerful but experimental.
Boujie succeeds by designing around those constraints instead of trying to make
stock Godot behave like a finished AAA water renderer.

## Boujie Refraction Method

Boujie is not doing physically exact refraction and it is not solving exact
receiver ownership. It is a very strong Godot-specific screen-space illusion.
The important point is that the illusion is arranged so the usual Godot artifact
is much harder to see.

### 1. It Does Not Use Alpha As The Refraction Blend

The most important detail is the final composition model.

The common fragile water pattern is:

1. Draw the opaque receiver normally.
2. Draw transparent water on top.
3. Sample the screen at a shifted UV.
4. Alpha-blend the shifted sample over the straight receiver already visible in
   the framebuffer.

That preserves two readable copies of the same object: the straight opaque
object and the shifted refracted object. At silhouettes and waterline crossings,
that becomes the familiar double outline.

Boujie avoids leaning on that blend. In the refractive path, it starts with
`ALPHA = 1.0`, computes a `screen_read_blend_amount`, adds the shifted screen
sample to `EMISSION`, and multiplies `ALBEDO` down by the inverse amount. The
upstream shader comment is direct: screen-reading shader features use
`EMISSION` to simulate alpha, and the shader should not set `ALPHA` for that
part.

Practical effect: the water pixel becomes an opaque-looking shaded surface that
contains some transmitted scene color. It is not a normal transparent material
where refraction opacity equals framebuffer alpha. The straight background still
exists in Godot's opaque screen copy, but the final water pixel is not simply
"straight object plus shifted object blended together." The water surface owns
the pixel more decisively.

Godotwind's adaptation follows the same idea in
`ocean_boujie_experimental_common.gdshaderinc`: `screen_color` is sampled from
`screen_texture`, multiplied by `screen_read_blend_amount`, assigned to
`EMISSION`, and the visible `ALBEDO` contribution is reduced by
`1.0 - screen_read_blend_amount`.

### 2. It Accepts Godot's Screen Texture Contract

Boujie uses `hint_screen_texture` and `hint_depth_texture`. In Godot 3D, that
means the source is the opaque scene copy captured before transparent objects.
It will not contain later transparent water, particles, glass, or other
transparent materials. It may contain opaque objects that are in front of the
water material according to the screen copy.

Boujie does not try to turn this into exact optical truth. It treats the screen
texture as a cheap transmitted-light source. That is the key mindset shift: the
screen sample is an ingredient in the water color, not an ownership authority
for the whole frame.

This matters for Godotwind because many prior iterations treated the screen
sample as if enough depth tests and UV rejection rules could make it behave like
a real refractive render target. That is where the complexity exploded.

### 3. It Makes Refraction Small Where It Would Break

Boujie's `zb/fix_refraction_distance_fade` branch adds distance scaling:

```glsl
r_final *= clamp(
    pow(refraction_scaling_distance_min / distance_from_camera,
        refraction_scaling_power),
    0.0,
    1.0
);
```

The default power is squared falloff. Near the camera, refraction can be visible.
Farther away, it rapidly collapses toward no offset.

This is a practical fix for a common screen-space water failure: distant
objects, horizon geometry, and far shorelines can move too much in screen space
from a tiny normal perturbation. If the offset is large at distance, it samples
unrelated pixels and creates crawling outlines. Boujie simply refuses to spend
refraction budget there.

For Godotwind, this should become a first-class production rule: screen-space
surface refraction is a near/mid visual detail, not a horizon-scale optical
simulation.

### 4. It Blurs The Refracted Source As Water Gets Visually Deeper

Boujie computes water thickness by comparing the water surface's view-space
depth with the background depth sampled at the refracted UV. It then applies a
Beer-Lambert-like depth blend and uses that value to raise the mip level for the
screen texture read.

In plain English: the deeper or foggier the water looks, the blurrier the
sampled scene becomes.

That does two useful things:

- It makes the water feel optically thicker.
- It hides small UV/depth mismatch errors exactly where clear refraction would
  expose them.

Godotwind should preserve this behavior. A sharp refracted source is only safe
for very shallow, near-camera water with small offsets. Deep water should be
mostly color, fog, Fresnel, foam, and blurred transmitted light.

### 5. It Lets Water Color Dominate The Screen Sample

Boujie does not just paste the screen sample through the surface. After sampling
`screen_texture`, it mixes the sample strongly toward shallow/deep water colors
based on depth fog. Godotwind's adaptation similarly mixes toward
`color_shallow` and `medium_color`.

This is another reason the shader looks stable. The refracted scene is
subordinate to the water material. The user reads "water" first and "distorted
object behind it" second. That is the right priority for an open-world ocean.

Previous Godotwind attempts often made the refracted receiver too literal. That
made every bad pixel obvious.

### 6. It Uses A Crude But Effective Snell Gate

Boujie's Snell's-window logic is not a physically complete underwater optical
model. It computes a thresholded factor from the normal/view dot product,
modifies it with the refraction offset, gates `final_refraction_opacity`, and
mixes the surface color toward a darker Snell color when the gate closes.

The practical effect is valuable even if the math is simple:

- At angles where screen-space refraction is likely to look wrong, transmitted
  screen color is reduced.
- The water becomes more surface-colored and less see-through.
- The transition reads as an optical feature instead of a failure.

Godotwind should treat this as a perceptual guardrail. A physically richer Snell
window can come later, but the first production goal is to stop showing broken
screen samples at angles where Godot cannot support them robustly.

### 7. Foam And Shore Effects Override Refraction

Boujie lets foam block or replace transmitted emission. Shore foam is driven by
depth difference, and wave foam is driven by wave/foam texture inputs. In both
cases, foam pushes the pixel back toward a surface material instead of letting
refracted screen color dominate.

This is useful because silhouettes and contact edges are exactly where
refraction artifacts are easiest to see. Foam is not only decoration; it is a
masking layer over the places where the screen-space approximation is least
trustworthy.

Godotwind should preserve this ordering: foam and contact film should be allowed
to suppress transmitted screen emission.

### 8. It Has A Much Smaller Runtime Surface Area

The Boujie path is one spatial material path plus Godot's normal screen/depth
texture facilities. It pays for screen/depth sampling and transparency sorting
constraints, but it avoids:

- an extra water-excluded scene render;
- explicit color/depth copy timing;
- source frame age checks;
- renderer-native matrix transport for a second camera;
- full-screen compute dispatch;
- storage image writes;
- candidate receiver ray marching;
- water-ownership rejection masks;
- debug counter buffers;
- compositor MSAA resolve management.

That smaller runtime surface area is why it is easier to make visually stable.
There are fewer contracts that can disagree.

This does not mean it is free. Screen texture, depth texture, transparent
sorting, overdraw, and mip reads still need profiling. It means the failure
mode is usually "less physically exact" rather than "obvious double outline."

## Refraction Refactor Plan

Use this plan when replacing Godotwind's current surface-refraction path.

1. Keep the FFT/projected ocean displacement, shore mask, SSS, foam, spray, and
   `WaterSurfaceState` contracts.
2. Replace production above-water surface refraction with a Boujie-style
   material path:
   - `hint_screen_texture` and `hint_depth_texture`;
   - refracted UV from surface normal plus a refraction texture/noise term;
   - squared distance falloff for offset strength;
   - depth-derived Beer-Lambert fog;
   - roughness/depth-driven screen mip reads;
   - Snell/Fresnel gates that reduce transmitted screen color at unsafe angles;
   - transmitted screen color through `EMISSION`;
   - inverse darkening of `ALBEDO`;
   - no alpha-as-refraction-opacity blend.
3. Treat refraction as a near/mid detail. At distance, water should transition
   toward surface color, Fresnel/specular, fog, foam, and SSS rather than
   shifted screen pixels.
4. Let foam/contact/shore film suppress transmitted emission at silhouettes and
   depth discontinuities.
5. Keep the controlled-source compositor disabled by default and rename its docs
   around exact receiver-waterline replacement. It should not be presented as
   the main surface-water refraction solution.
6. Underwater should be reconsidered through the same lens. The accepted
   underwater pass can remain a compositor for whole-frame absorption/wobble,
   but it should prefer bounded, perceptual distortion and color grading over
   exact multi-owner receiver replacement unless a dedicated scene proves that
   exactness is necessary.

Acceptance for the refactor is visual first and architectural second:

- no obvious double outline on receiver silhouettes;
- no hard rejection halos at waterline crossings;
- stable motion during free camera movement in Ocean Lab;
- surface water reads as attractive water before it reads as a correct optical
  simulation;
- performance measured against the current compositor path with source render,
  copy, and final pass costs removed from the default route.

## Debug Rules

| Debug rule | Evidence |
| --- | --- |
| Debug source ownership before tuning refraction strength. | G46-WATER-001, G46-WATER-002, IND-WATER-002 |
| Debug depth-space conversion before tuning water thickness. | G46-WATER-003 |
| Disable optional effects first: custom SSR, underwater wobble, caustics, particles, wetness, and receiver waterline. | G46-WATER-004, G46-WATER-005, G46-WATER-006, IND-WATER-004 |
| A final production pixel should choose one visible owner for a submerged receiver silhouette instead of preserving both a straight and shifted readable copy. | G46-WATER-001, G46-WATER-002, IND-WATER-002 |
| For the Boujie-style path, debug composition before physics: verify the screen sample, emission amount, inverse albedo darkening, distance falloff, and depth-fog mip level before changing water-surface classification. | OBS-WATER-001, OBS-WATER-002 |
| Use an interactive Ocean Lab launch for human visual acceptance after visual water changes. | Godotwind project verification rule in root `AGENTS.md` instructions. |
