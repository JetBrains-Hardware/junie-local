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

# Extract archives to models directory
for archive in "${ARCHIVES[@]}"; do
  echo "Extracting $archive to $MODELS_DIR..."
  unzip -q "$TMP_DIR/$archive" -d "$MODELS_DIR"
  echo "  Extraction complete."
done

# Cleanup
rm -rf "$TMP_DIR"

echo ""
echo "=== Installation complete ==="
echo "Models installed to: $MODELS_DIR"
ls -la "$MODELS_DIR"