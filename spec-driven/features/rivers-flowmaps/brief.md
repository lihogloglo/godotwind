# Seed Brief: Rivers With Flowmaps

This is a seed idea, not a completed research document.
Use it to start a future feature folder for a GodotWind river system.

## Idea

Add a generic river and flowmap framework that can support high-quality outdoor water motion while keeping Morrowind-specific data as an adapter layer.

## Desired Direction

- Research how modern open-world games represent rivers, flow direction, shore interaction, and water material variation.
- Include target-quality references such as Red Dead Redemption 2 and The Witcher 3 as visual and design benchmarks.
- Check OpenMW's codebase for any relevant Morrowind water settings, formulas, data interpretation, or compatibility behavior.
- Translate the research into a Godot-specific plan that accounts for Godot's renderer, shader pipeline, terrain integration, resources, and tooling.
- Keep the core system reusable for non-Morrowind projects.
- Design river materials, flowmaps, presets, and placement data so mods can add, replace, or override river content without editing generic framework code.
- Add a visual test scene early, because shader and water behavior cannot be trusted from code alone.

## Questions for Research

- Should rivers be represented as splines, meshes, flowmap textures, terrain masks, or a hybrid?
- How are flow direction, speed, foam, banks, depth, and intersections authored?
- Which parts should be editable in Godot?
- Which parts should be imported from external tools or generated from terrain data?
- What debug views make flow direction and speed obvious?
- What is the minimum useful version that can be built without locking the project into a bad architecture?

## Likely Feature Folder

```text
spec-driven/features/rivers-flowmaps/
  research.md
  spec.md
  plan.md
  tasks.md
  validation.md
  review.md
```

## Non-Negotiables

- The generic river system must not reference Morrowind directly.
- Any Morrowind-specific loading, naming, or data conversion must live in an adapter/import layer.
- Any OpenMW-informed formulas or settings should be cited in research and isolated from the generic framework unless they are intentionally generalized.
- River content and water behavior intended for creators should be data-driven and override-friendly.
- A visual validation scene must be included before the feature is considered complete.
- Performance constraints should be documented before full-world integration.
