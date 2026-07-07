# Morrowind Night Sky Adapter — Plan (2026-07-06)

**Status:** Plan draft, awaiting review.
**Chosen approach:** Panorama-bake the star field + two real moons (Masser + Secunda), plus MW night sky color. (User decision 2026-07-06.)
**Author:** implementation agent.

---

## 1. The problem

Godotwind's night sky is currently a **generic placeholder** with zero Morrowind
assets wired in. That is fine for the *framework default*, but the Morrowind
layer is supposed to show Morrowind's actual night sky, and it doesn't.

What we ship today ([sky_manager.gd](../../src/core/sky/sky_manager.gd),
[sky.gdshader](../../src/core/sky/shaders/sky.gdshader)):

| Piece | Today (generic) | Morrowind (target) |
|-------|-----------------|--------------------|
| Stars | Sky3D `Milkyway.jpg` equirect panorama, or a procedural 3D-hash starfield | Bethesda's authored star field from `sky_night_01.nif` |
| Moon  | ONE moon, Earth's `MoonMap.png`, phase from sun·moon dot product | TWO moons — Masser (large) + Secunda (small) — with real phase textures on a 3-day cycle |
| Night color | Computed atmospheric scatter + bluish `night_tint (0.6,0.7,1.0)` | Near-black authored `Sky_Night_Color` (Clear night = RGB 9,10,11) |

Net effect: the night reads like a modern Earth sky (bright-ish, blue, Milky
Way, one moon) instead of Morrowind's very dark sky with an authored star field
and two distinct moons.

Confirmed: grepping all of `src/` for `sky_night`, `masser`, `secunda`,
`mooncircle`, `tx_sun`, etc. returns **no files** — there is no MW sky adapter
at all today.

---

## 2. How OpenMW does it (reference)

From [sky.cpp](../../inspos/openmw/apps/openmw/mwrender/sky.cpp) +
[skyutil.cpp](../../inspos/openmw/apps/openmw/mwrender/skyutil.cpp) +
[weather.cpp](../../inspos/openmw/apps/openmw/mwworld/weather.cpp):

1. **Star dome is a NIF mesh**, not a computed sky. Loads `meshes/sky_night_02.nif`
   if present, else `meshes/sky_night_01.nif`. Star positions are authored into
   the mesh as **vertex colors**: `ModVertexAlphaVisitor::Stars` sets each
   vertex's alpha to 1 only where the original vertex red channel == 1
   (skyutil.cpp:1203).
2. **Star dome fades** with `mStarsOpacity = weather.mNightFade * weather.mGlareView`
   (a time-of-day curve: 1 at night, 0 by day, cross-fades through dawn/dusk),
   and **rotates 360° every 4 days** around the vertical axis (sky.cpp:583).
   Masked entirely off when `weather.mNight` is false.
3. **Night sky background color** is a flat authored constant per weather:
   `Weather_<Type>_Sky_Night_Color` (Clear = 9,10,11), applied as emission on the
   atmosphere dome. Not computed scatter.
4. **Two moons**, each a textured quad with 8 phase textures
   (`tx_masser_new/one_wax/half_wax/three_wax/one_wan/half_wan/three_wan/full.dds`,
   same for `secunda`) + a circle mask (`tx_mooncircle_full_m/s.dds`). Phase
   advances on a 3-day cycle (weather.cpp:513); each moon has its own rise/set
   arc, shadow blend, and atmosphere-tint blend.

We deliberately deviate from OpenMW on ONE thing (per user choice): instead of
keeping the star dome as live NIF geometry, we **bake it once into an
equirectangular panorama** and feed that into the star_panorama slot the sky
shader already samples. This keeps the runtime path unchanged and cheap. The
two moons DO become real geometry (billboards), matching OpenMW.

---

## 3. Architecture — generic core + Morrowind adapter

Non-negotiable per `.claude/CLAUDE.md` (translation-layer principle):
**`src/core/sky/` stays engine-agnostic. All MW-specific data lives in a new
`src/core/sky/morrowind/` adapter.** Litmus test: a different game plugs in its
own adapter (its own star panorama + moon set + night colors) without touching
`sky_manager.gd`.

```
src/core/sky/
  sky_manager.gd            (generic — GAINS a generic 2-moon billboard API + star fade/rotation hooks)
  celestial_manager.gd      (generic — GAINS optional second-body + phase-index outputs)
  moon_billboard.gd         (NEW, generic — one textured camera-relative moon quad)
  morrowind/
    mw_sky_adapter.gd       (NEW — reads MW weather/time, feeds SkyManager the MW data)
    mw_moon_model.gd        (NEW — MW 3-day phase + rise/set arc math, ported from weather.cpp MoonModel)

src/tools/prebaking/
  morrowind_night_sky_prebaker.gd   (NEW — bakes star panorama + moon phase atlas from BSA)
```

Everything MW-specific (asset paths, the 9,10,11 night color, 3-day phase cycle,
Masser/Secunda sizes) is confined to the `morrowind/` subdir + the prebaker.

---

## 4. Components

### A. Star-field panorama prebaker  → feeds `SkyManager.star_panorama`

**Goal:** produce `night_sky_panorama.png` (equirectangular) once, offline, from
Morrowind's own star mesh, and load it at runtime into the existing
`star_panorama` uniform. Runtime shader path is UNCHANGED.

**Bake method (primary):** render the real mesh.
1. Extract `meshes/sky_night_01.nif` (and `_02` if present) via
   `BSAManager.extract_file()`.
2. Convert with the existing `NIFConverter` (same path model_prebaker uses) →
   Godot mesh with its star geometry + vertex colors + any star sprite texture.
3. Instantiate into a `SubViewport`, camera at dome center, capture 6 cube faces,
   convert cubemap → equirect (small fullscreen shader) → save PNG to the cache
   prebake dir.

**Bake method (fallback, if the mesh render is fiddly):** vertex splat.
- Take the mesh's star vertices (those with vertex-color R==1, exactly OpenMW's
  test), project each direction → equirect UV, splat a small bright dot. Fully
  deterministic, no render-to-texture. Loses the exact star-sprite shape but
  preserves authored positions.

**Why bake, not runtime:** `[[feedback_no_runtime_generation]]` — never generate
assets at runtime. UI-triggered prebake only, following the existing
`prebaking_manager.gd` component pattern (new `Component.NIGHT_SKY`).

**Deliverable:** a panorama in the prebake cache. `mw_sky_adapter` loads it and
sets `sky_manager.star_panorama = <baked>`; the star rotation + fade already
exist in the shader/manager.

### B. Moon phase-texture atlas prebaker  → feeds the moon billboards

- Extract the 16 phase DDS (8 Masser + 8 Secunda) + 2 circle masks
  (`tx_mooncircle_full_m/s.dds`) + `tx_sun_05.dds` from BSA.
- Re-save as Godot-importable textures (or pack the 8 phases per moon into one
  atlas). Output to the prebake cache. Same UI-triggered prebaker as A.

### C. Generic moon billboard  (`moon_billboard.gd`)

One reusable camera-relative textured quad — the generic equivalent of OpenMW's
`CelestialBody`/`Moon`. Framework code, no MW knowledge.
- A `MeshInstance3D` quad (or `Sprite3D`) parented to a camera-relative pivot so
  it sits at infinity, positioned along a supplied direction * large radius.
- A small `moon.gdshader`: samples `phase_tex.rgb` for the lit surface and
  `circle_tex.a` for the disc silhouette; tint by an atmosphere color + overall
  transparency (mirrors OpenMW's MoonUpdater two-texture-unit composite).
- Public API: `set_direction()`, `set_phase_texture()`, `set_circle_texture()`,
  `set_size()`, `set_atmosphere_color()`, `set_transparency()`.

`SkyManager` owns a small generic list of these (0..N) so the framework isn't
hardwired to "two moons." The MW adapter creates exactly two and names them.

**Also:** disable the generic in-shader moon for the MW layer (the sky shader's
sphere-intersect moon) so we don't double-draw. Keep it behind a
`generic_moon_enabled` flag for the framework default.

### D. MW moon model  (`mw_moon_model.gd`)

Port the parts of `weather.cpp` `MoonModel` we need:
- **Phase index (0-7)** on the 3-day cycle: `(gameDay / 3) % 8` with the
  moon-not-yet-risen carry (weather.cpp:513-522). Masser and Secunda use the
  same formula but different fallback constants → different phases.
- **Rise/set arc angle** (weather.cpp:416 `angle()`), simplified as far as looks
  right — we don't need bit-exact vanilla, just two moons that rise/set on
  believable independent arcs.
- Maps phase index → the correct baked phase texture from B.

MW constants (Masser/Secunda size, axis offset, daily increment, fade angles)
live here as named constants sourced from the MW `Moons_*` fallbacks — MW-only,
correctly in the adapter layer.

### E. Night sky color  → route existing MW color into the sky

The MW night color already exists in-engine: `WeatherResult.sky_color` is a
4-phase `TimeOfDayColor` whose **night** value is MW's `Sky_Night_Color`. It is
currently computed but **never applied to the sky background** (only fog uses
it). Fix in the adapter path:
- At night, blend the sky background toward `WeatherResult.sky_color` (the
  near-black MW night) instead of leaving pure computed scatter + bluish
  `night_tint`. Concretely: drive `sky_manager.night_tint` (and reduce night
  scatter) from the MW night color, or add a `night_sky_color` override the
  shader mixes in as the sun drops below the horizon.
- Verify `WeatherData`'s CLEAR night sky_color is actually ~ (9,10,11)/255; if
  the current table has a lighter placeholder, correct it from MW values.

### F. Star fade + rotation (mostly already present)

- Fade: `SkyManager` already dims stars via `transmittance` + a night factor;
  align it with a `night_fade` from sun altitude so stars cross-fade at
  dawn/dusk like `mStarsOpacity`. Minor tuning, no new system.
- Rotation: `celestial.star_rotation` already rotates the panorama. Match
  OpenMW's cadence (360° / 4 days) instead of the current hour-based spin.

---

## 5. Wiring (where each piece plugs in)

- **Prebake:** new `Component.NIGHT_SKY` in
  [prebaking_manager.gd](../../src/tools/prebaking/prebaking_manager.gd) +
  `morrowind_night_sky_prebaker.gd`, surfaced in `prebaking_ui.gd`. Outputs
  panorama + moon atlas to the cache.
- **Adapter creation:** `mw_sky_adapter` is created alongside `SkyManager` where
  the sky is set up (via `EnvironmentControls`, referenced from
  [world_explorer.gd](../../src/tools/world_explorer.gd) `_env_controls.sky_manager`).
  On init it loads the baked panorama + moon atlas and creates the two moons.
- **Per-frame:** hook the existing `WeatherManager` signals — `game_hour_changed`
  (for moon/star position + phase) and `weather_updated` (for night color +
  star fade). The adapter translates `WeatherResult` → SkyManager calls. Cleanest
  insertion point is `WeatherRenderer._apply_sky()`
  ([weather_renderer.gd:188](../../src/core/weather/weather_renderer.gd#L188)),
  which already receives both the sky manager and the `WeatherResult`.

---

## 6. Assets (exact MW paths)

Meshes: `meshes/sky_night_01.nif`, `meshes/sky_night_02.nif` (optional HD).
Moon phase (×16): `textures/tx_{masser,secunda}_{new,one_wax,half_wax,three_wax,one_wan,half_wan,three_wan,full}.dds`
Moon masks: `textures/tx_mooncircle_full_m.dds`, `textures/tx_mooncircle_full_s.dds`
Sun: `textures/tx_sun_05.dds` (optional — replace generic sun disc later).
Night colors: MW `Weather_<Type>_Sky_Night_Color` (already in the weather tables;
verify values).

---

## 7. Phasing (each step independently verifiable in-scene)

1. **Night color first** (smallest, biggest immediate win). Route MW night
   sky_color into the sky; verify the night actually goes MW-dark. No assets yet.
2. **Star panorama prebaker + load.** Bake from `sky_night_01.nif`, feed
   `star_panorama`, retune fade + 4-day rotation. Verify authored star field
   replaces the Milky Way.
3. **Moon atlas prebaker + generic `moon_billboard`.** Get ONE MW-textured moon
   billboard rendering + positioned; disable the generic in-shader moon.
4. **Two moons + MW phase model.** Add Secunda, wire `mw_moon_model` phases +
   independent arcs. Verify both moons, correct phases advancing over days.
5. **Polish:** shadow/atmosphere blend on moons, sun disc swap (optional),
   weather-driven star opacity parity.

Verify each phase by launching the main scene interactively and flying at night
across a time-of-day sweep (`[[feedback_visual_testing]]`,
`[[feedback_never_launch_main_game_unprompted]]` — launch for visual confirm;
no auto-capture).

---

## 8. Risks / open questions

- **`sky_night_01.nif` structure:** need to confirm the stars are geometry with
  a sprite texture vs. plain vertex-colored points — decides whether the primary
  render-capture bake or the vertex-splat fallback is used. Resolve during
  Phase 2 by inspecting the converted mesh in the prebake asset viewer
  (`[[feedback_no_mesh_corruption_quarantine]]` — verify visually, don't assume).
- **Moon billboard blend at horizon:** OpenMW blends the moon disc toward the sky
  color near the horizon (shadowBlend). Approximate; exact vanilla curve is not
  required.
- **Cheap-clouds / cirrus interaction at night:** confirm baked stars + moons
  composite correctly behind the existing cirrus + cheap cloud layers.
- **Phase-cycle epoch:** vanilla anchors to "16 Last Seed, 427." We can pick any
  believable epoch; bit-exact vanilla phase on a given date is not a goal unless
  requested.

---

## 9. Out of scope (this pass)

- Sun glare/flash occlusion-query system (OpenMW's `SunFlashCallback`) — the
  generic sky already has sun halos; MW-exact glare is a later polish item.
- Weather particle occlusion, rain ripples, storm mesh rotation — unrelated
  weather-system work.
- Bit-exact vanilla moon rise/set and phase-on-date fidelity.
