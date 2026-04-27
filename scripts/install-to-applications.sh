#!/bin/bash
# Post-build script: copies the freshly-built Clicky.app to /Applications/Clicky.app.
# Add this as a "Run Script" Build Phase in Xcode (after the Compile Sources phase).
#
# In Xcode: Target → Build Phases → + → New Run Script Phase
# Paste the body of this file (the lines after this comment block) into the script field.
# Set "Based on dependency analysis" to OFF so it always runs.

set -e

BUILT_APP="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"
INSTALL_PATH="/Applications/Clicky.app"

if [ ! -d "$BUILT_APP" ]; then
  echo "warning: Built app not found at $BUILT_APP — skipping install"
  exit 0
fi

echo "Installing $BUILT_APP → $INSTALL_PATH"

# Kill the running Clicky (if any) before replacing the binary
pkill -x Clicky 2>/dev/null || true
sleep 0.5

# Copy the built app over, replacing the existing one
cp -Rf "$BUILT_APP" "$INSTALL_PATH"

echo "✅ Installed to $INSTALL_PATH"
