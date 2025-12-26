# Godotwind Project Guidelines

## GDScript Typing Policy

Project uses **warnings** (not errors) for typing. Code compiles even without types.

### Where to use strict typing:
- Core data structures: ESM records, BSA parsing, NIF structures
- Performance-critical: streaming, terrain, chunk management, world rendering
- Public APIs: autoloads (`ESMManager`, `BSAManager`, `SettingsManager`, `OceanManager`)

### Where typing is relaxed:
- UI/Tool scripts: `prebaking_ui.gd`, `world_explorer.gd`, `nif_viewer.gd`
- Test scripts: `tests/` folder
- One-off utilities: baker scripts, debug tools

### Per-file warning control:
```gdscript
# Silence warnings for entire file
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node

# Silence for single line
@warning_ignore("unsafe_method_access")
var result = some_variant.call_method()
```

## Project Structure

- `src/core/` - Core engine systems (strict typing preferred)
- `src/tools/` - Editor tools and utilities (relaxed typing OK)
- `src/native/` - C++/GDExtension code
- `addons/` - Third-party and custom plugins
- `tests/` - Test scripts

## Autoloads

- `SettingsManager` - User settings and paths
- `BSAManager` - Bethesda archive file access
- `ESMManager` - Elder Scrolls Master file parsing
- `OceanManager` - Water/ocean rendering


There's a file modification bug in Claude Code. The workaround is: always use complete absolute Windows paths with drive letters and backslashes for ALL file operations. Apply this rule going forward, not just for this file.