#!/bin/sh
set -e

# Configuration
BASE_URL="https://junie-local.erokhins.com"
BASE_DIR="$HOME/.local/share/junie-local"
MODELS_DIR="$BASE_DIR/models"
DOWNLOAD_DIR="$BASE_DIR/incomplete_downloads"

# oMLX DMG
OMLX_URL="https://github.com/jundot/omlx/releases/download/v0.5.3/oMLX-0.5.3-macos26-27.dmg"
OMLX_FILE="oMLX-0.5.3-macos26-27.dmg"
OMLX_SHA256="15a2a74e20bf4518d6f6133af4ecc0f3e4c6610f3127c1612ae6178ef749a4c8"

# Model archives and their MD5 checksums (tab-separated)
MODEL_ZIP_1="models--mlx-community--Qwen3.6-27B-4bit.zip"
MODEL_MD5_1="5ccc3a1cc4f09f91343a510a8704b02d"
MODEL_ZIP_2="models--mlx-community--Qwen3.6-27B-MTP-4bit.zip"
MODEL_MD5_2="5788dcff30df52fc90b65c0c9fc514db"

echo "=== Junie Local Model Installer ==="
echo ""

# Cleanup function — kills child processes on interrupt
cleanup() {
  exit_code="$1"

  # Avoid executing this trap recursively.
  trap - INT TERM

  echo ""
  echo "Interrupted — partial downloads preserved in $DOWNLOAD_DIR"
  echo "Re-run this script to resume."

  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true

  exit "$exit_code"
}

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# Create directories
echo "Creating directories..."
mkdir -p "$MODELS_DIR"
mkdir -p "$DOWNLOAD_DIR"

# Function to download and verify a model archive
download_and_verify() {
  archive="$1"
  expected_md5="$2"

  echo "Downloading $archive..."
  curl -SL -C - -o "$DOWNLOAD_DIR/$archive" "$BASE_URL/$archive"
  echo "  Download complete."

  actual=$(md5 -q "$DOWNLOAD_DIR/$archive")
  if [ "$actual" != "$expected_md5" ]; then
    echo "  ERROR: Checksum mismatch for $archive"
    echo "    Expected: $expected_md5"
    echo "    Actual:   $actual"
    exit 1
  fi
  echo "  Checksum verified: $actual"
}

# Download and verify model archives
download_and_verify "$MODEL_ZIP_1" "$MODEL_MD5_1"
download_and_verify "$MODEL_ZIP_2" "$MODEL_MD5_2"

# Extract model archives to models directory
echo "Extracting $MODEL_ZIP_1 to $MODELS_DIR..."
unzip -q "$DOWNLOAD_DIR/$MODEL_ZIP_1" -d "$MODELS_DIR"
echo "  Extraction complete."

echo "Extracting $MODEL_ZIP_2 to $MODELS_DIR..."
unzip -q "$DOWNLOAD_DIR/$MODEL_ZIP_2" -d "$MODELS_DIR"
echo "  Extraction complete."

# Download and install oMLX DMG
echo ""
echo "Downloading $OMLX_FILE..."
curl -SL -C - -o "$DOWNLOAD_DIR/$OMLX_FILE" "$OMLX_URL"
echo "  Download complete."

# Verify SHA256 checksum
actual_sha256=$(shasum -a 256 "$DOWNLOAD_DIR/$OMLX_FILE" | awk '{print $1}')
if [ "$actual_sha256" != "$OMLX_SHA256" ]; then
  echo "  ERROR: SHA256 mismatch for $OMLX_FILE"
  echo "    Expected: $OMLX_SHA256"
  echo "    Actual:   $actual_sha256"
exit 1
fi
echo "  SHA256 verified: $actual_sha256"

# Mount and open oMLX DMG
echo "Opening oMLX DMG..."
hdiutil attach "$DOWNLOAD_DIR/$OMLX_FILE" > /dev/null 2>&1
MOUNT_POINT=$(ls /Volumes/ | grep "^oMLX" | head -1)
MOUNT_POINT="/Volumes/$MOUNT_POINT"
open "$MOUNT_POINT"
echo ""
echo "  Drag the oMLX.app into the Applications folder."

# Cleanup downloads
echo "Removing downloaded archives..."
rm -rf "$DOWNLOAD_DIR"

echo ""
echo "=== Installation complete ==="
echo "Models installed to: $MODELS_DIR"
ls -la "$MODELS_DIR"
echo ""
echo "oMLX DMG mounted — please drag oMLX.app to /Applications/"