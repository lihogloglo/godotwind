# Lighting Roadmap

> Open roadmap. None of the items here have shipped yet. Items pulled verbatim from the 2026-04-05 lighting audit. Update status inline when shipping.

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
- New system: `src/core/world/distant_light_manager.gd`
- MultiMesh of billboard quads at known ESM light positions
- Additive blend, warm color, soft glow texture
- Size scales with distance for constant screen-space size
- Toggle based on time-of-day (sun elevation threshold)
- One draw call for hundreds of "distant lights"
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
