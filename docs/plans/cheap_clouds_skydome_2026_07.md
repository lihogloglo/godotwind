# Cheap Clouds — Skydome Option (clayjohn volumetric-cloud-demo-v2 port)

**Status:** SHIPPED 2026-07-06 (same day). Files: `src/core/sky/clouds/cheap_cloud_layer.gd`,
`src/core/sky/clouds/cheap_clouds.glsl`, compositing in `sky.gdshader`, selector in Clouds tab.
Kept for the design rationale; pending visual calibration of the atmosphere color ramps
(`SkyManager._compute_cloud_atmo_colors`).
**Requested by:** user — "clouds are very nice but quite costly. We should provide a cheap option:
https://github.com/clayjohn/godot-volumetric-cloud-demo-v2"

---

## Why (canonical pattern)

SunshineClouds2 is a per-pixel compositor compute raymarch — quality is high, cost is
high, and it runs every frame at screen resolution. The canonical cheap alternative
(used by the demo, and in spirit by every skybox-cloud implementation since the
2000s) is: **raymarch the cloud hemisphere into a texture amortized over many
frames, then have the sky shader just sample that texture.**

Verified facts about the demo (fetched 2026-07-06):

- Clouds are rendered by a **compute shader into a hemisphere texture over 64
  frames**; two copies are cross-blended to hide the update seam. README: renders
  "the hemisphere to a texture over 64 frames" and "interpolates between two copies
  of that texture to hide changes"; "much faster (~20x)" than raymarching in the sky
  shader directly (v1).
- Needs Godot 4.2+ (TextureRD), Forward+/Mobile only. We're on 4.6 Forward+. OK.
- License: MIT (cloud shader/code: Godot Engine contributors; atmosphere shader:
  Fernando García Liñán). Attribution required — add to `assets/sky/ATTRIBUTION.txt`.
- Repo files that matter for the port (`cloud_sky/`): `clouds.glsl` (compute
  raymarcher), `clouds.gdshader` + `cloud_sky.gd` (sky-side compositing + RD
  texture/dispatch driver), noise/weather textures: `perlworlnoise.tga`,
  `worlnoise.bmp`, `weather.bmp`. The `sky-lut.glsl` / `transmittance-lut.glsl`
  atmosphere LUTs are **NOT ported** — Godotwind has its own analytical sky
  (`sky.gdshader`); we only take the cloud layer.

Known trade-offs of the technique (accept them — that's what "cheap" means):

- Clouds live at infinity on the skydome: no flying through clouds, no parallax
  against near terrain. Fine below the cloud deck, which is the Morrowind case.
- 64-frame amortization means fast sun movement shows blending lag (README calls
  this out). Our quantized sun steps (`SkyManager.shadow_update_angle_deg`) don't
  affect this — the cloud pass reads the smooth `sun_direction`, but our default
  time scales are slow enough.

## Integration design

New directory `src/core/sky/clouds/`:

- `cheap_cloud_layer.gd` — RefCounted driver owned by `SkyManager` (mirrors
  `cloud_sky.gd` from the demo): owns the RenderingDevice textures (2× hemisphere
  RGBA16F, ~512² to start), dispatches 1/64th of the hemisphere per frame,
  swaps/blends buffers, exposes `set_coverage/density/wind(...)`.
- `cheap_clouds.glsl` — the ported compute raymarcher. Inputs: our
  `SkyManager.get_sky_state()` (sun dir/color/energy, zenith transmittance) instead
  of the demo's LUTs; noise + weather textures from the repo.
- Textures under `assets/sky/clouds/` (downloaded from the repo, MIT attribution).

Sky shader (`sky.gdshader`): add `uniform sampler2D cheap_cloud_texture`,
`uniform float cheap_cloud_blend`, `uniform bool cheap_clouds_enabled`, and the
demo's hemisphere-UV mapping in `sky()`, composited between atmosphere and cirrus.
Uniform pushes go through `SkyManager._set_param` like everything else.

UI: the Clouds tab "Volumetric Clouds" checkbox (shipped 2026-07-06) becomes a
3-way renderer selector: **Off / Cheap (skydome) / SunshineClouds2**. Weather keeps
driving coverage for both paths (`WeatherRenderer.get_cloud_preset_for_coverage`).

## Steps

1. Vendor files: download `clouds.glsl`, `perlworlnoise.tga`, `worlnoise.bmp`,
   `weather.bmp` from the repo `main` branch; add ATTRIBUTION entry.
2. Port `cloud_sky.gd` → `cheap_cloud_layer.gd`; strip atmosphere LUT plumbing,
   feed sun state from `SkyManager`.
3. Sky shader compositing + `SkyManager` wiring (`cheap_clouds_enabled`).
4. UI selector + weather coverage wiring.
5. Verify interactively: toggle between Off / Cheap / SunshineClouds2 at noon,
   sunset, night; check FPS delta and the 64-frame blend under time scale.

## Success criteria

- Cheap mode costs ≲0.3 ms/frame GPU (vs. multiple ms for SunshineClouds2).
- No visible seam/popping during the amortized update at default time scale.
- Weather coverage presets visibly affect the cheap layer.
