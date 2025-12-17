# RTT Deformation System - Configuration Guide

## Overview

The deformation system is **completely optional** and **disabled by default**. This guide explains how to enable, configure, and fine-tune the system for your needs.

---

## Enabling the System

### Method 1: Project Settings (Recommended)

Add these settings to your `project.godot` file:

```ini
[deformation]

enabled=true
enable_terrain_integration=true
enable_recovery=false
enable_persistence=true
enable_streaming=true
```

### Method 2: Runtime Enable

```gdscript
# In your initialization code
func _ready():
    # Enable the entire system
    DeformationConfig.enable_system()

    # Or enable specific features
    DeformationConfig.enabled = true
    DeformationConfig.enable_terrain_integration = true
    DeformationConfig.enable_recovery = true
```

### Method 3: Via Godot Editor

1. Open **Project → Project Settings**
2. Scroll to **Deformation** section (will appear after first run)
3. Check **Enabled** to turn on the system
4. Configure other options as needed

---

## Configuration Options

### Master Controls

#### `deformation/enabled` (bool)
**Default:** `false`
**Description:** Master enable/disable for the entire deformation system.

- `false`: System completely disabled, no overhead
- `true`: System active and available

**When to enable:** Only enable if you want ground deformation in your game.

---

### Feature Flags

#### `deformation/enable_terrain_integration` (bool)
**Default:** `true`
**Description:** Enable integration with Terrain3D shader.

- `false`: Deformations processed but not visible on terrain
- `true`: Deformations visible on terrain surface (requires Terrain3D)

**When to disable:** Testing deformation logic without terrain, or if terrain shader isn't ready yet.

---

#### `deformation/enable_recovery` (bool)
**Default:** `false`
**Description:** Enable time-based recovery (deformations fade over time).

- `false`: Deformations are permanent until manually cleared
- `true`: Deformations gradually fade away

**When to enable:** For snow that melts, sand that settles back, etc.

---

#### `deformation/enable_persistence` (bool)
**Default:** `true`
**Description:** Save/load deformation data to disk.

- `false`: Deformations lost when regions unload
- `true`: Deformations persist across sessions

**When to disable:** Testing scenarios where you want fresh terrain each time.

---

#### `deformation/enable_streaming` (bool)
**Default:** `true`
**Description:** Automatically stream regions with terrain.

- `false`: Manual region management required
- `true`: Regions load/unload with terrain automatically

**When to disable:** Custom region management, testing single regions.

---

### Performance Settings

#### `deformation/performance/update_budget_ms` (float)
**Default:** `2.0`
**Range:** `0.1` to `16.0`
**Description:** Time budget per frame for deformation updates (milliseconds).

**Tuning:**
- `1.0` - Low-end hardware, minimal impact
- `2.0` - Balanced (recommended)
- `4.0` - High-end hardware, more responsive

---

#### `deformation/performance/max_active_regions` (int)
**Default:** `9`
**Range:** `1` to `25`
**Description:** Maximum number of active deformation regions.

**Memory Impact:**
- `9 regions` = ~36MB (3×3 grid)
- `16 regions` = ~64MB (4×4 grid)
- `25 regions` = ~100MB (5×5 grid)

**Tuning:**
- `4-6` - Mobile/low-memory
- `9` - Desktop (recommended)
- `16+` - High-end/server

---

#### `deformation/performance/texture_size` (int)
**Default:** `1024`
**Options:** `256`, `512`, `1024`, `2048`
**Description:** Resolution of deformation texture per region.

**Quality vs Performance:**
- `256` - Low quality, 1MB per region, fast
- `512` - Medium quality, 2MB per region, balanced
- `1024` - High quality, 4MB per region (recommended)
- `2048` - Ultra quality, 16MB per region, slow

---

### Recovery Settings

#### `deformation/recovery/rate` (float)
**Default:** `0.01`
**Description:** Recovery speed (units per second).

**Examples:**
- `0.005` - Very slow (200 seconds to fully recover)
- `0.01` - Slow (100 seconds to fully recover)
- `0.05` - Fast (20 seconds to fully recover)
- `0.1` - Very fast (10 seconds to fully recover)

---

#### `deformation/recovery/update_interval` (float)
**Default:** `1.0`
**Description:** How often to process recovery (seconds).

**Performance Impact:**
- `2.0` - Low impact, choppy recovery
- `1.0` - Balanced (recommended)
- `0.5` - High quality, smooth recovery, more CPU

---

### Persistence Settings

#### `deformation/persistence/format` (string)
**Default:** `"exr"`
**Options:** `"exr"`, `"png"`
**Description:** File format for saved deformation data.

**Format Comparison:**
- `exr`: Lossless 16-bit float, larger files (~2MB per region)
- `png`: Lossy compression, smaller files (~200KB per region)

---

#### `deformation/persistence/auto_save` (bool)
**Default:** `true`
**Description:** Automatically save dirty regions when they unload.

- `false`: Manual save required
- `true`: Auto-save on region unload

---

### Debug Settings

#### `deformation/debug/enabled` (bool)
**Default:** `false`
**Description:** Enable debug logging.

**When to enable:** Troubleshooting, development, performance profiling.

---

#### `deformation/debug/show_region_bounds` (bool)
**Default:** `false`
**Description:** Visualize deformation region boundaries.

**Requirement:** Needs DebugDraw addon or similar.

---

## Configuration Examples

### Example 1: Minimal (Testing)

```gdscript
# Minimal setup for testing
DeformationConfig.enabled = true
DeformationConfig.enable_terrain_integration = false  # Test logic only
DeformationConfig.enable_recovery = false
DeformationConfig.enable_persistence = false
DeformationConfig.texture_size = 512  # Lower quality for faster iteration
DeformationConfig.debug_mode = true
```

### Example 2: Production (Snow Deformation)

```gdscript
# Production snow deformation
DeformationConfig.enabled = true
DeformationConfig.enable_terrain_integration = true
DeformationConfig.enable_recovery = true  # Snow melts over time
DeformationConfig.recovery_rate = 0.01  # Slow melt
DeformationConfig.enable_persistence = true
DeformationConfig.texture_size = 1024  # High quality
DeformationConfig.max_active_regions = 9
```

### Example 3: Performance Optimized

```gdscript
# Low-end hardware optimization
DeformationConfig.enabled = true
DeformationConfig.enable_terrain_integration = true
DeformationConfig.enable_recovery = false  # Disable recovery for performance
DeformationConfig.enable_persistence = true
DeformationConfig.texture_size = 512  # Lower resolution
DeformationConfig.max_active_regions = 4  # Fewer regions
DeformationConfig.update_budget_ms = 1.0  # Smaller budget
```

### Example 4: High-End (Maximum Quality)

```gdscript
# Maximum quality for high-end systems
DeformationConfig.enabled = true
DeformationConfig.enable_terrain_integration = true
DeformationConfig.enable_recovery = true
DeformationConfig.recovery_rate = 0.02  # Faster recovery
DeformationConfig.recovery_update_interval = 0.5  # Smoother updates
DeformationConfig.enable_persistence = true
DeformationConfig.save_format = "exr"  # Lossless
DeformationConfig.texture_size = 2048  # Ultra quality
DeformationConfig.max_active_regions = 16
DeformationConfig.update_budget_ms = 4.0
```

---

## Checking System Status

```gdscript
# Check if system is enabled and initialized
if DeformationManager.is_system_enabled():
    print("Deformation system is active")

if DeformationManager.is_initialized():
    print("Deformation system fully initialized")

# Check configuration
print("Texture size: ", DeformationConfig.texture_size)
print("Max regions: ", DeformationConfig.max_active_regions)
print("Recovery enabled: ", DeformationConfig.enable_recovery)
```

---

## Disabling the System

### Temporary Disable (Runtime)

```gdscript
# Disable temporarily without unloading
DeformationManager.set_deformation_enabled(false)

# Re-enable
DeformationManager.set_deformation_enabled(true)
```

### Permanent Disable (Project Settings)

```ini
[deformation]

enabled=false
```

Or in code:

```gdscript
DeformationConfig.disable_system()
```

### Complete Removal

If you want to completely remove the deformation system:

1. Remove from `project.godot` autoload:
```ini
# Remove this line:
# DeformationManager="*res://src/core/deformation/deformation_manager.gd"
```

2. Delete the directory:
```bash
rm -rf src/core/deformation/
```

---

## Performance Monitoring

```gdscript
# Monitor active regions
func _process(_delta):
    var active_count = DeformationManager._active_regions.size()
    var pending_count = DeformationManager._pending_deformations.size()

    print("Active regions: ", active_count)
    print("Pending deformations: ", pending_count)
```

---

## Common Configuration Scenarios

### Scenario 1: "I want footprints in snow that last forever"

```gdscript
DeformationConfig.enabled = true
DeformationConfig.enable_recovery = false  # No recovery
DeformationConfig.enable_persistence = true  # Save them
```

### Scenario 2: "I want footprints that fade after 30 seconds"

```gdscript
DeformationConfig.enabled = true
DeformationConfig.enable_recovery = true
DeformationConfig.recovery_rate = 0.033  # 1/30 = fade in 30 sec
```

### Scenario 3: "I want deformation but my game has no terrain"

```gdscript
DeformationConfig.enabled = true
DeformationConfig.enable_terrain_integration = false
# Use deformation data for other purposes (grass, particles, etc.)
```

### Scenario 4: "I want to test without saving anything"

```gdscript
DeformationConfig.enabled = true
DeformationConfig.enable_persistence = false  # Don't save
DeformationConfig.enable_streaming = false  # Manual control
```

---

## Troubleshooting Configuration

### Problem: System not starting

**Solution:** Check that `deformation/enabled` is `true` in project settings.

### Problem: High memory usage

**Solutions:**
- Reduce `max_active_regions` (9 → 4)
- Reduce `texture_size` (1024 → 512)

### Problem: Performance issues

**Solutions:**
- Reduce `update_budget_ms` (2.0 → 1.0)
- Disable `enable_recovery`
- Reduce `texture_size`
- Reduce `max_active_regions`

### Problem: Deformations not visible

**Solutions:**
- Enable `enable_terrain_integration`
- Check that Terrain3D shader is configured
- Verify terrain exists in scene

---

## Advanced: Runtime Configuration Changes

```gdscript
# Change configuration at runtime
func reconfigure_for_quality_level(quality: int):
    match quality:
        0:  # Low
            DeformationConfig.texture_size = 512
            DeformationConfig.max_active_regions = 4
            DeformationConfig.enable_recovery = false
        1:  # Medium
            DeformationConfig.texture_size = 1024
            DeformationConfig.max_active_regions = 9
            DeformationConfig.enable_recovery = true
        2:  # High
            DeformationConfig.texture_size = 2048
            DeformationConfig.max_active_regions = 16
            DeformationConfig.enable_recovery = true

    # Reload manager to apply changes
    # Note: This would require restarting the system
```

---

## Summary

- **Default:** System is **disabled** - opt-in only
- **Enable:** Set `deformation/enabled = true`
- **Configure:** Tune performance, quality, and features
- **Disable:** Set to `false` or remove autoload entirely
- **No overhead when disabled:** Zero performance impact

For more information, see:
- `README.md` - Integration guide
- `RTT_DEFORMATION_IMPLEMENTATION.md` - Technical details
- `docs/RTT_DEFORMATION_SYSTEM_DESIGN.md` - Full design
