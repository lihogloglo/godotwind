# Godot 4.6 Water Rendering Rules

Status: stable renderer-rule document for Godot 4.6. Last fact-checked against
primary sources on 2026-05-22.

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

## Consequences For Godotwind

Each architecture consequence below is derived from the claim ledger above.

| Consequence | Evidence |
| --- | --- |
| Surface, underwater, wetness, receiver capture, and buoyancy systems should consume one shared water contract for water height, coverage, body ID, shore data, render mesh metadata, and optical coefficients. | G46-WATER-003, G46-WATER-009, IND-WATER-001, IND-WATER-003 |
| The visible ocean mesh should own wave displacement, normals, foam, Fresnel/specular, and shore waves as an opaque baseline. Above-water refraction that needs controlled source ownership should be a separate bounded layer with explicit source capture, not a screen-reading mutation of the main ocean material. | G46-WATER-001, G46-WATER-002, G46-WATER-006, IND-WATER-001, IND-WATER-002, IND-WATER-003 |
| Whole-frame underwater absorption/fog and later camera-underwater wobble or sky transmission should be compositor-owned. | G46-WATER-004, G46-WATER-005, IND-WATER-001 |
| Half-submerged receiver refraction needs an explicit capture/compositor path with documented layer, source, mask, depth, latency, and budget contracts. | G46-WATER-002, G46-WATER-003, G46-WATER-004, G46-WATER-005, G46-WATER-009, IND-WATER-002 |
| Wetness should stay separate from underwater optical medium and receiver waterline ownership. | G46-WATER-004, G46-WATER-008, IND-WATER-004 |

## Debug Rules

| Debug rule | Evidence |
| --- | --- |
| Debug source ownership before tuning refraction strength. | G46-WATER-001, G46-WATER-002, IND-WATER-002 |
| Debug depth-space conversion before tuning water thickness. | G46-WATER-003 |
| Disable optional effects first: custom SSR, underwater wobble, caustics, particles, wetness, and receiver waterline. | G46-WATER-004, G46-WATER-005, G46-WATER-006, IND-WATER-004 |
| A final production pixel should choose one visible owner for a submerged receiver silhouette instead of preserving both a straight and shifted readable copy. | G46-WATER-001, G46-WATER-002, IND-WATER-002 |
| Use an interactive Ocean Lab launch for human visual acceptance after visual water changes. | Godotwind project verification rule in root `AGENTS.md` instructions. |
