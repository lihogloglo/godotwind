# Asset Management System

## Overview

Handles loading textures, models, and other resources from Morrowind's BSA archives. Includes texture loading (DDS, TGA), material deduplication, and caching.

## Key Files

| File | Purpose |
|------|---------|
| `src/core/bsa/bsa_manager.gd` | BSA archive reader (autoload) |
| `src/core/texture/texture_loader.gd` | DDS/TGA texture loading |
| `src/core/texture/material_library.gd` | Material deduplication |

## BSA Archives

Morrowind stores assets in BSA (Bethesda Softworks Archive) files:

```
Data Files/
├─ Morrowind.bsa    # ~1.4 GB base game
├─ Tribunal.bsa     # ~250 MB expansion
└─ Bloodmoon.bsa    # ~300 MB expansion
```

## BSAManager API

```gdscript
# Autoload: BSAManager

# Load archive (call on startup)
func load_archive(path: String) -> bool

# Check if file exists
func has_file(path: String) -> bool

# Extract file data
func extract_file(path: String) -> PackedByteArray

# Thread-safe (mutex-protected cache)
```

Path normalization is automatic: `"Meshes\\f\\flora.nif"` → `"meshes/f/flora.nif"`

## Texture Loading

```gdscript
# Load texture from BSA
var texture = TextureLoader.load_texture("textures/tx_rock_01.dds")

# Cached version (recommended)
var texture = TextureLoader.load_texture_cached("textures/tx_rock_01.dds")
```

### Supported Formats

| Format | Compression |
|--------|-------------|
| DDS | DXT1, DXT3, DXT5, Uncompressed |
| TGA | Uncompressed RGB/RGBA |

## Material Deduplication

Avoids creating duplicate materials:

```gdscript
# Bad: Creates new material every time
var mat = StandardMaterial3D.new()
mat.albedo_texture = texture

# Good: Shares material if texture matches
var mat = MaterialLibrary.get_or_create_material(albedo_tex, normal_tex)
```

**Result**: 10,000 kelp plants share 1 material instead of 10,000.

## Caching

### BSA Directory Cache
Pre-loaded on `load_archive()` for O(1) file lookups.

### Texture Cache
Avoids re-loading same texture.

### Extraction Cache
256MB LRU cache for extracted BSA files (thread-safe).

```gdscript
# Cache stats
var stats = BSAManager.get_cache_stats()
# Returns: {hits: 1234, misses: 56, size_mb: 128}
```

## Placeholder Assets

When files are missing, magenta checkerboard texture is used:

```gdscript
# Automatic fallback
var texture = TextureLoader.load_texture("missing.dds")
# Returns checkerboard, logs warning
```

## Usage Pattern

```gdscript
# On game start
func _ready():
    BSAManager.load_archive(morrowind_path + "/Morrowind.bsa")
    BSAManager.load_archive(morrowind_path + "/Tribunal.bsa")
    BSAManager.load_archive(morrowind_path + "/Bloodmoon.bsa")

# When loading models
var nif_data = BSAManager.extract_file("meshes/f/flora_kelp_01.nif")
var model = nif_converter.convert(nif_data, path)
```

## See Also

- [STATUS.md](STATUS.md) - Implementation status
- [06_NIF_SYSTEM.md](06_NIF_SYSTEM.md) - Model conversion
