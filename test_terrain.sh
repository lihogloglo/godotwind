#!/bin/bash
# Quick test script for world_explorer scene with logging

GODOT_PATH="/home/leo/Desktop/Godotwind/Godot_v4.5.1-stable_linux.x86_64"
PROJECT_PATH="/home/leo/Desktop/Godotwind/godotwind"
LOG_FILE="$PROJECT_PATH/terrain_test.txt"
SCENE="res://scenes/world_explorer.tscn"

echo "Testing world_explorer scene..."
echo "Log will be saved to: $LOG_FILE"

# Clear previous log
echo "========================================" > "$LOG_FILE"
echo "World Explorer Test - $(date)" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Run the specific scene directly
cd "$PROJECT_PATH"
"$GODOT_PATH" --path "$PROJECT_PATH" "$SCENE" --verbose 2>&1 | tee -a "$LOG_FILE"

echo ""
echo "Test complete. Check $LOG_FILE for output"
