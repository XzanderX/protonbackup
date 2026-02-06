#!/bin/bash

# Bundle rclone binary into the app
# This script copies rclone from the local bin directory into the app bundle's Resources folder

set -e

RCLONE_SOURCE=""

# Check for rclone in common locations
if [ -f "/opt/homebrew/bin/rclone" ]; then
    RCLONE_SOURCE="/opt/homebrew/bin/rclone"
elif [ -f "/usr/local/bin/rclone" ]; then
    RCLONE_SOURCE="/usr/local/bin/rclone"
elif [ -f "$HOME/.local/bin/rclone" ]; then
    RCLONE_SOURCE="$HOME/.local/bin/rclone"
elif command -v rclone &> /dev/null; then
    RCLONE_SOURCE=$(command -v rclone)
fi

# Check if we're in a build context
if [ -n "$BUILT_PRODUCTS_DIR" ] && [ -n "$UNLOCALIZED_RESOURCES_FOLDER_PATH" ]; then
    DEST_DIR="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
else
    # Manual execution - use current directory
    DEST_DIR="./build/ProtonBackup.app/Contents/Resources"
fi

# Create destination directory if needed
mkdir -p "$DEST_DIR"

if [ -n "$RCLONE_SOURCE" ]; then
    echo "Bundling rclone from: $RCLONE_SOURCE"
    cp "$RCLONE_SOURCE" "$DEST_DIR/rclone"
    chmod +x "$DEST_DIR/rclone"
    echo "rclone bundled successfully to: $DEST_DIR/rclone"
else
    echo "Warning: rclone not found. The app will look for rclone in system PATH at runtime."
    echo ""
    echo "To install rclone:"
    echo "  brew install rclone"
    echo ""
    echo "Or download from: https://rclone.org/downloads/"
fi
