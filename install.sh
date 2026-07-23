#!/bin/bash
set -e

# Configuration
BASE_URL="https://junie-local.erokhins.com"
MODELS_DIR="$HOME/.local/share/junie-local/models"
TMP_DIR=$(mktemp -d)

# Model archives
ARCHIVES=(
  "models--mlx-community--Qwen3.6-27B-4bit.zip"
  "models--mlx-community--Qwen3.6-27B-MTP-4bit.zip"
)

# oMLX DMG
OMLX_URL="https://github.com/jundot/omlx/releases/download/v0.5.3/oMLX-0.5.3-macos26-27.dmg"
OMLX_FILE="oMLX-0.5.3-macos26-27.dmg"
OMLX_SHA256="15a2a74e20bf4518d6f6133af4ecc0f3e4c6610f3127c1612ae6178ef749a4c8"

# MD5 checksums
declare -A CHECKSUMS
CHECKSUMS["models--mlx-community--Qwen3.6-27B-4bit.zip"]="5ccc3a1cc4f09f91343a510a8704b02d"
CHECKSUMS["models--mlx-community--Qwen3.6-27B-MTP-4bit.zip"]="5788dcff30df52fc90b65c0c9fc514db"

echo "=== Junie Local Model Installer ==="
echo ""

# Create models directory
echo "Creating models directory: $MODELS_DIR"
mkdir -p "$MODELS_DIR"

# Download and verify each archive
for archive in "${ARCHIVES[@]}"; do
  echo "Downloading $archive..."
  curl -fSL -C - -o "$TMP_DIR/$archive" "$BASE_URL/$archive"
  echo "  Download complete."

  # Verify checksum
  expected="${CHECKSUMS[$archive]}"
  actual=$(md5 -q "$TMP_DIR/$archive")

  if [ "$actual" != "$expected" ]; then
    echo "  ERROR: Checksum mismatch for $archive"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    rm -rf "$TMP_DIR"
    exit 1
  fi
  echo "  Checksum verified: $actual"
done

# Extract model archives to models directory
for archive in "${ARCHIVES[@]}"; do
  echo "Extracting $archive to $MODELS_DIR..."
  unzip -q "$TMP_DIR/$archive" -d "$MODELS_DIR"
  echo "  Extraction complete."
done

# Download and install oMLX DMG
echo ""
echo "Downloading $OMLX_FILE..."
curl -fSL -C - -o "$TMP_DIR/$OMLX_FILE" "$OMLX_URL"
echo "  Download complete."

# Verify SHA256 checksum
actual_sha256=$(shasum -a 256 "$TMP_DIR/$OMLX_FILE" | awk '{print $1}')
if [ "$actual_sha256" != "$OMLX_SHA256" ]; then
  echo "  ERROR: SHA256 mismatch for $OMLX_FILE"
  echo "    Expected: $OMLX_SHA256"
  echo "    Actual:   $actual_sha256"
  rm -rf "$TMP_DIR"
  exit 1
fi
echo "  SHA256 verified: $actual_sha256"

# Mount and open oMLX DMG
echo "Opening oMLX DMG..."
hdiutil attach "$TMP_DIR/$OMLX_FILE" > /dev/null 2>&1
MOUNT_POINT=$(ls /Volumes/ | grep "^oMLX" | head -1)
MOUNT_POINT="/Volumes/$MOUNT_POINT"
open "$MOUNT_POINT"
echo ""
echo "  Drag the oMLX.app into the Applications folder."

# Cleanup
rm -rf "$TMP_DIR"

echo ""
echo "=== Installation complete ==="
echo "Models installed to: $MODELS_DIR"
ls -la "$MODELS_DIR"
echo ""
echo "oMLX DMG mounted — please drag oMLX.app to /Applications/"