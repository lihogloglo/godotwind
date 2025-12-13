#!/bin/bash
# Run Godot with output logging for debugging

GODOT_PATH="/home/leo/Desktop/Godotwind/Godot_v4.5.1-stable_linux.x86_64"
PROJECT_PATH="/home/leo/Desktop/Godotwind/godotwind"
LOG_FILE="$PROJECT_PATH/godot_debug.txt"

echo "Starting Godot with logging to: $LOG_FILE"
echo "========================================" > "$LOG_FILE"
echo "Godot Debug Log - $(date)" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Run Godot and capture both stdout and stderr
cd "$PROJECT_PATH"
"$GODOT_PATH" --path "$PROJECT_PATH" 2>&1 | tee -a "$LOG_FILE"

echo ""
echo "Log saved to: $LOG_FILE"
