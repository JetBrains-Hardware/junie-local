#!/bin/sh
set -e

# ============================================================
# Platform check: must be macOS 26+
# ============================================================
UNAME_OUT=$(uname -s)
if [ "$UNAME_OUT" != "Darwin" ]; then
  echo "ERROR: This script requires macOS. Detected OS: $UNAME_OUT"
  exit 1
fi

OS_VERSION=$(sw_vers -productVersion | cut -d '.' -f 1)
if [ "$OS_VERSION" -lt 26 ]; then
  echo "ERROR: macOS 26 or higher is required. Detected version: $(sw_vers -productVersion)"
  exit 1
fi

# ============================================================
# CPU check: M4 or M5 recommended
# ============================================================
CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
case "$CPU_MODEL" in
  *M4*|*M5*)
    echo "  Detected processor: $CPU_MODEL (compatible)"
    ;;
  *)
    echo "  WARNING: Apple M4 or M5 processor is recommended for optimal performance."
    echo "  Detected processor: $CPU_MODEL"
    echo ""
    read -r -p "  Do you really want to continue? [y/N] " CPU_ANSWER
    case "$CPU_ANSWER" in
      [yY][eE][sS]|[yY])
        echo "  Continuing with installation..."
        ;;
      *)
        echo "  Installation cancelled."
        exit 1
        ;;
    esac
    ;;
esac

# ============================================================
# System requirements check: memory
# ============================================================
echo "=== Checking system requirements ==="
echo ""

# Get total memory in bytes from sysctl, then convert to GB
MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
MEM_GB=$((MEM_BYTES / 1073741824))

echo "  Detected memory: ${MEM_GB} GB"

if [ "$MEM_GB" -lt 32 ]; then
  echo ""
  echo "  ERROR: For the model to run you need at least 33 GB of memory, you have only ${MEM_GB} GB."
  exit 1
elif [ "$MEM_GB" -lt 63 ]; then
  echo ""
  echo "  WARNING: Recommended memory is 63 GB for optimal performance."
  echo "  You have ${MEM_GB} GB."
  echo ""
  read -r -p "  Do you really want to continue? [y/N] " MEM_ANSWER
  case "$MEM_ANSWER" in
    [yY][eE][sS]|[yY])
      echo "  Continuing with installation..."
      ;;
    *)
      echo "  Installation cancelled."
      exit 1
      ;;
  esac
fi

echo ""

# Configuration
BASE_URL="https://junie-local.erokhins.com"
BASE_DIR="$HOME/.local/share/junie-local"
MODELS_DIR="$BASE_DIR/models"
DOWNLOAD_DIR="$BASE_DIR/incomplete_downloads"

# oMLX DMG
OMLX_URL="https://github.com/jundot/omlx/releases/download/v0.5.3/oMLX-0.5.3-macos26-27.dmg"
OMLX_FILE="oMLX-0.5.3-macos26-27.dmg"
OMLX_SHA256="15a2a74e20bf4518d6f6133af4ecc0f3e4c6610f3127c1612ae6178ef749a4c8"
OMLX_APP="/Applications/oMLX.app"
OMLX_MIN_VERSION="0.5.2"
OMLX_TARGET_VERSION="0.5.3"

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

# Function to compare two version strings (returns 0 if v1 >= v2)
version_ge() {
  v1="$1"
  v2="$2"
  if [ "$v1" = "$v2" ]; then
    return 0
  fi
  # Use sort -V to compare versions
  highest=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -n 1)
  [ "$v1" = "$highest" ]
}

# ============================================================
# Step 1: Check and install oMLX (must happen before models)
# ============================================================
echo "=== Checking oMLX installation ==="
echo ""

if [ -d "$OMLX_APP" ]; then
  # Extract installed version from CFBundleShortVersionString
  INSTALLED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OMLX_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
  echo "  oMLX is already installed at $OMLX_APP"
  echo "  Installed version: $INSTALLED_VERSION"

  if [ "$INSTALLED_VERSION" = "unknown" ]; then
    echo "  WARNING: Could not determine installed version."
    echo "  Proceeding with update to version $OMLX_TARGET_VERSION."
    SKIP_OMLX=false
  elif version_ge "$INSTALLED_VERSION" "$OMLX_MIN_VERSION"; then
    echo "  Version $INSTALLED_VERSION meets minimum requirement ($OMLX_MIN_VERSION)."
    echo "  Skipping oMLX installation."
    SKIP_OMLX=true
  else
    echo "  Version $INSTALLED_VERSION is below minimum requirement ($OMLX_MIN_VERSION)."
    echo "  Proceeding with update to version $OMLX_TARGET_VERSION."
    SKIP_OMLX=false
  fi
else
  echo "  oMLX is not installed."
  echo "  Proceeding with installation of version $OMLX_TARGET_VERSION."
  SKIP_OMLX=false
fi

echo ""

if [ "$SKIP_OMLX" = false ]; then
  # Download and install oMLX DMG
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
  echo ""

  # Clean up oMLX download
  rm -f "$DOWNLOAD_DIR/$OMLX_FILE"
fi

# ============================================================
# Step 2: Download and install models
# ============================================================
echo "=== Installing models ==="
echo ""

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

# Cleanup model downloads
echo "Removing downloaded archives..."
rm -rf "$DOWNLOAD_DIR"

echo ""
echo "=== Installation complete ==="
echo "Models installed to: $MODELS_DIR"
ls -la "$MODELS_DIR"

if [ "$SKIP_OMLX" = true ]; then
  echo "oMLX is already installed at $OMLX_APP (version $INSTALLED_VERSION)"
else
  echo "oMLX DMG mounted — please drag oMLX.app to /Applications/"
fi