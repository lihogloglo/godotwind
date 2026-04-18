# NIF Feature Audit Results

Generated: 2026-04-05T20:13:55 | Total NIFs: 7319 | Parse errors: 44 | Time: 43.3s

## Texture Slot Usage

| Slot | Count | % of Base | Examples |
|------|-------|-----------|----------|
| Base (0) | 25600 | 100% | — |
| Dark (1) | 36 | 0.1% | meshes\o\contain_daedric_chest_01.nif, meshes\m\key_daedric_01.nif, meshes\m\misc_6th_ash_statue_01.nif, meshes\menu_help.nif, meshes\menu_main.nif |
| Detail (2) | 0 | 0.0% |  |
| Gloss (3) | 0 | 0.0% | — |
| Glow (4) | 20 | 0.1% | meshes\r\xice troll.nif, meshes\r\udyrfrykte.nif, meshes\r\xcr_draugr.nif, meshes\r\ice troll.nif, meshes\r\draugrlord.nif |
| Bump (5) | 0 | 0.0% |  |
| Decal (6) | 0 | 0.0% |  |

## Apply Modes

| Mode | Count |
|------|-------|
| REPLACE (0) | 0 |
| DECAL (1) | 0 |
| MODULATE (2) | 25322 |
| HILIGHT (3) | 283 |
| HILIGHT2 (4) | 0 |

HILIGHT examples: meshes\b\b_n_redguard_m_knee.nif, meshes\b\b_n_redguard_f_knee.nif, meshes\b\b_n_redguard_m_neck.nif, meshes\b\b_n_redguard_f_neck.nif, meshes\b\b_n_redguard_m_ankle.nif

## Animation Controllers

| Controller | Count |
|-----------|-------|
| NiKeyframeController | 5954 |
| NiUVController | 98 |
| NiAlphaController | 183 |
| NiMaterialColorController | 10 |
| NiFlipController | 0 |
| NiVisController | 309 |
| NiGeomMorpherController | 318 |
| NiPathController | 56 |
| NiRollController | 0 |
| NiLookAtController | 0 |
| NiParticleSystemController | 665 |

Morph examples: meshes\w\w_huntsman_crossbow.nif, meshes\r\hircine_bear_larger.nif, meshes\r\horker.nif, meshes\r\wolf_red.nif, meshes\r\swimmer.nif

## Properties

| Property | Count | Notes |
|----------|-------|-------|
| NiSpecularProperty | 8 | enabled: 8 |
| NiStencilProperty | 0 | stencil ops: 0 |
| NiZBufferProperty | 1330 | non-default: 1030 |
| NiWireframeProperty | 12 | |
| NiFogProperty | 0 | |

## Environment Maps

| Type | Count |
|------|-------|
| Total NiTextureEffect | 0 |
| Sphere map | 0 |
| Cube map | 0 |

Env map examples: 

## Routing Decision

Multi-texture slot usage: 56 instances across 25600 base textures (0.2%)

**Recommendation:** Hybrid SM3D + ShaderMaterial (0.2% need multi-texture)