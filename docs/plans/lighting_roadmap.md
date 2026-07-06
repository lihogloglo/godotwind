# Lighting Roadmap

> Open roadmap. Items pulled from the 2026-04-05 lighting audit; update status inline when shipping. Boundary rule: core lighting systems consume generic light descriptors, and source-specific light flags are translated in source adapters.

> **2026-07-06 lighting pass — SHIPPED:** SDFGI (was P1), emissive light models
> (was P1), distant REAL point lights 150-600m in `distant_light_manager.gd`
> (was P2 "billboard only" — upgraded: Forward+ is already a clustered-forward
> renderer, the same architecture upstream adopted in its MR 5212, so real
> shadowless omnis are cheap), interior ReflectionProbes (was P2), interior
> environment post-stack inheritance + per-cell ambient/fog, the model-material
> specular gate (whitish-container fix, see `docs/systems/lighting.md` §4c),
> and prebaked interior VoxelGI (`interior_gi_bake_runner.tscn`) standing in
> for lightmaps — LightmapGI.bake() is not scriptable (godot-proposals#8656),
> so batch lightmap baking is impossible in stock Godot. Current state:
> `docs/systems/lighting.md`. Still open below: extended NEAR light fade,
> night impostor variants, FogVolumes, contact-shadow equivalent (NOTE:
> `shadow_contact` is Godot 3 API — does not exist in Godot 4; needs a
> different approach if pursued).

---

## Priority 1: Quick Wins (Configuration Only)

**Enable SDFGI:**
```gdscript
env.sdfgi_enabled = true
env.sdfgi_cascades = 4
env.sdfgi_use_occlusion = true
env.sdfgi_bounce_feedback = 0.5
env.sdfgi_energy = 1.0
env.sdfgi_normal_bias = 1.1
env.sdfgi_probe_bias = 1.1
```
- Instant GI quality improvement across entire world
- Note: check for 4.6 regression ([#115599](https://github.com/godotengine/godot/issues/115599)) — may need to wait for patch

**Extend light distance fade:**
```gdscript
# In reference_instantiator.gd, change from:
omni.distance_fade_begin = 120.0
omni.distance_fade_length = 30.0
# To:
omni.distance_fade_begin = 200.0
omni.distance_fade_length = 100.0
omni.distance_fade_shadow = 60.0  # Disable shadow early, keep light visible longer
```
- Lights visible to 300m (unshadowed beyond 60m)
- Immediate visual improvement at moderate cost

**Add emissive to existing light-associated meshes:**
- Torch meshes, lantern meshes, candle meshes should have `emission_enabled = true`
- Fire textures should emit with `emission_energy_multiplier = 2.0–3.0` to trigger bloom
- Lava terrain textures should have emission channel

---

## Priority 2: Medium-Term Systems

**Billboard Light MultiMesh (Distant Town Lights):**
- **Shipped foundation:** `src/core/world/distant_light_manager.gd`
- MultiMesh of billboard quads at provider-supplied distant-light records
- Additive blend, warm color, soft glow texture
- Size scales with distance for constant screen-space size
- Toggle based on time-of-day (sun elevation threshold)
- One draw call for hundreds of "distant lights"
- Morrowind light flags are translated in `src/core/world/morrowind/morrowind_world_object_source.gd`; core stores generic animation/fire metadata.
- **This is the highest-impact visual feature for open-world night scenes**

**Interior ReflectionProbes:**
- Place one ReflectionProbe per interior cell
- Update mode: Once (cheap — bake on cell load)
- `interior = true` to prevent sky leaking in
- Dramatically improves metallic/shiny material quality indoors

**Emissive Material System:**
- Material variant system that swaps emission on/off based on time-of-day
- For MW: light-source objects get an emission texture derived from their albedo
- Applied at object instantiation time in reference_instantiator

---

## Priority 3: Polish

**Night Impostor Variants:**
- Extend `impostor_baker_v2.gd` to bake a "night" atlas pass
- During night pass: enable emission on light-source objects
- At runtime: blend between day/night impostor based on sun elevation
- Allows towns to glow at FAR tier (500m–5km)

**FogVolume for Localized Effects:**
- Lava pools: FogVolume (box shape) with warm emission
- Caves: FogVolume with dense fog at entrance
- Swamps: FogVolume with ground-hugging fog

**Contact Shadows:**
```gdscript
# On DirectionalLight3D:
light.shadow_contact = 0.3  # Small-scale contact darkening
```
