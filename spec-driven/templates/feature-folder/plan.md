# Plan: <Feature Name>

## Spec Link

`spec.md`

## Architecture Summary

Describe the chosen architecture and why it satisfies the spec.

## Layers

Framework layer:

- <Generic component>

Game-specific layer:

- <Adapter/importer/preset>

Reference-compatibility layer:

- <OpenMW-informed formulas, settings, or behavior that must stay out of the generic framework unless generalized intentionally>

Validation layer:

- <Test scene/tool/test>

## Godot Components

- Nodes:
- Resources:
- Shaders:
- Editor tools:
- Importers:
- Autoloads:
- Scenes:

## Data Model

Describe resources, serialized fields, runtime data, and ownership.

## Modding and Override Model

- Moddable resources, configs, or assets:
- Extension points:
- Override/load-order behavior:
- Validation fixtures for custom content:
- Boundaries that prevent mods from changing generic framework internals:

## Runtime Flow

1. <Step>
2. <Step>
3. <Step>

## Files to Change

- `<path>`: <reason>

## Documentation Plan

- Code comments needed:
- Feature docs to update:
- Architecture or data-flow docs to update:
- Validation docs to update:

## Validation Strategy

- Automated:
- Visual:
- Performance:
- Manual:

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| <Risk> | <Impact> | <Mitigation> |

## Migration and Compatibility

Describe any data, scene, resource, or API compatibility concerns.
