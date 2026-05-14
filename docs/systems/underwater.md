# Underwater

This page is superseded for underwater shader/rendering architecture.

Use these two living docs instead:

- `docs/systems/ocean_optics_current_architecture.md` - what the current
  Godotwind source actually does.
- `docs/systems/godot_water_shader_bible.md` - the Godot renderer rules and
  debug workflow for water shaders.

The old content in this file described the receiver-only
`WaterlineCompositorEffect` path as production. Source inspection on
2026-05-14 showed that Ocean Lab currently uses
`UnderwaterCompositorEffect`, while the receiver-only stack is present but not
the normal runtime path. The old page was intentionally collapsed to avoid
reintroducing that contradiction.
