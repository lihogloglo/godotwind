# Morrowind Settings Configuration

This document explains how to configure the Morrowind data path in Godotwind.

## Quick Start

### Option 1: Environment Variable (Recommended for Development)

Set the `MORROWIND_DATA_PATH` environment variable before running the project:

**Linux:**
```bash
export MORROWIND_DATA_PATH="/home/user/.steam/steam/steamapps/common/Morrowind/Data Files"
godot --path /path/to/godotwind
```

**Windows:**
```cmd
set MORROWIND_DATA_PATH=C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files
godot --path C:\path\to\godotwind
```

### Option 2: Settings UI Tool

1. Open the project in Godot
2. Run the Settings Tool scene: `res://scenes/settings_tool.tscn`
3. Click "Auto-Detect" to find your Morrowind installation automatically
4. Or click "Browse..." to manually select your Morrowind Data Files folder
5. Click "Save Settings"

Your settings will be saved to `user://settings.cfg` and will persist across sessions.

Note: The Settings Tool is also accessible from the World Explorer.

### Option 3: Manual Configuration

Edit the user config file at `user://settings.cfg`:

```ini
[morrowind]

data_path="/path/to/Morrowind/Data Files"
esm_file="Morrowind.esm"
```

The `user://` directory location varies by platform:
- **Linux:** `~/.local/share/godot/app_userdata/Godotwind/`
- **Windows:** `%APPDATA%\Godot\app_userdata\Godotwind\`
- **macOS:** `~/Library/Application Support/Godot/app_userdata/Godotwind/`

## Configuration Priority

Settings are loaded in this order (highest priority first):

1. **Environment Variables**
   - `MORROWIND_DATA_PATH` - Path to Morrowind Data Files directory
   - `MORROWIND_ESM_FILE` - Name of the ESM file (default: "Morrowind.esm")

2. **User Config File** (`user://settings.cfg`)
   - Saved by the Settings UI tool
   - Persists across sessions

3. **Project Settings** (`project.godot`)
   - Development fallback
   - Used if no other configuration is found

## Auto-Detection

The system automatically searches for Morrowind installations in common locations:

### Linux Paths
- `~/.steam/steam/steamapps/common/Morrowind/Data Files`
- `~/.local/share/Steam/steamapps/common/Morrowind/Data Files`
- `~/.var/app/com.valvesoftware.Steam/.steam/steam/steamapps/common/Morrowind/Data Files` (Flatpak)
- `/usr/share/games/morrowind/Data Files`
- `/usr/local/share/games/morrowind/Data Files`
- `~/GOG Games/Morrowind/Data Files`
- `~/Games/morrowind/Data Files` (Lutris)
- `~/.wine/drive_c/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files`

### Windows Paths
- `C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files`
- `C:\Program Files\Steam\steamapps\common\Morrowind\Data Files`
- `C:\Program Files (x86)\Bethesda Softworks\Morrowind\Data Files`
- `C:\GOG Games\Morrowind\Data Files`
- `D:\Games\Morrowind\Data Files`
- `D:\SteamLibrary\steamapps\common\Morrowind\Data Files`
- `E:\SteamLibrary\steamapps\common\Morrowind\Data Files`

## Integration Tests

For integration tests, you can also use the legacy `MORROWIND_ESM` environment variable to specify the full path to the ESM file:

```bash
export MORROWIND_ESM="/path/to/Morrowind/Data Files/Morrowind.esm"
```

Or use command-line arguments:

```bash
godot --headless -- "/path/to/Morrowind.esm"
```

## Programmatic Access

In your GDScript code, use the `SettingsManager` singleton:

```gdscript
# Get configured data path
var data_path := SettingsManager.get_data_path()

# Get ESM file name
var esm_file := SettingsManager.get_esm_file()

# Get full ESM path
var esm_path := SettingsManager.get_esm_path()

# Validate configuration
if SettingsManager.validate_configuration():
    print("Configuration is valid!")

# Auto-detect installation
var detected_path := SettingsManager.auto_detect_installation()
if not detected_path.is_empty():
    print("Found Morrowind at: ", detected_path)

# Save settings programmatically
SettingsManager.set_data_path("/new/path/to/Data Files")
SettingsManager.set_esm_file("Morrowind.esm")

# Check where the current setting comes from
print("Data path source: ", SettingsManager.get_data_path_source())
# Outputs: "environment variable", "user config", or "project settings"
```

## Troubleshooting

### "Morrowind data path not configured" Error

This means the system couldn't find a valid Morrowind installation. Try:

1. Set the `MORROWIND_DATA_PATH` environment variable
2. Use the Settings Tool to configure the path
3. Verify that the path exists and contains `Morrowind.esm`

### Settings Not Persisting

If settings aren't saving, check:

1. The user data directory has write permissions
2. You're using the Settings Tool's "Save" button
3. The path to `user://settings.cfg` is accessible

You can find the user data directory path by running:
```gdscript
print(OS.get_user_data_dir())
```

### Auto-Detect Not Finding Installation

If auto-detect doesn't find your installation:

1. Your Morrowind installation might be in a non-standard location
2. Use the "Browse..." button to manually select the directory
3. Make sure the directory contains `Morrowind.esm`

## Cross-Platform Notes

### Linux

The system checks both native Linux paths and Wine/Proton paths for Windows installations running through compatibility layers.

### Wine/Proton

If running Morrowind through Wine or Proton, the system will check:
- `~/.wine/drive_c/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files`
- Steam Proton compatibility data paths

### Case Sensitivity

On Linux, file paths are case-sensitive. Make sure the capitalization matches exactly:
- Correct: `Morrowind/Data Files`
- Incorrect: `morrowind/data files`
