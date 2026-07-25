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

# Model archives, their SHA256 checksums, and corresponding oMLX model IDs
MODEL_ZIP_1="models--mlx-community--Qwen3.6-27B-4bit.zip"
MODEL_SHA256_1="adf7f8d832ed994dcc6d09372036b4d12f49a4ccda066179cc64dc2dd113f91d"
MODEL_ID_1="mlx-community--Qwen3.6-27B-4bit"
MODEL_ZIP_2="models--mlx-community--Qwen3.6-27B-MTP-4bit.zip"
MODEL_SHA256_2="9266c1ba244ec6176fc82474bbfd20614969eb28c4cfa24301e515fbd1f5a525"
MODEL_ID_2="mlx-community--Qwen3.6-27B-MTP-4bit"

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

# Function to add MODELS_DIR to oMLX model_dirs if not already present
configure_omlx_models_dir() {
  SETTINGS_FILE="$HOME/.omlx/settings.json"

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "  WARNING: oMLX settings file not found at $SETTINGS_FILE"
    echo "  Skipping model_dirs configuration."
    return 1
  fi

  # Check if MODELS_DIR is already in model_dirs
  # Extract actual model_dirs entries via plutil (raw output is already unescaped)
  i=0
  while true; do
    DIR=$(plutil -extract "model.model_dirs.$i" raw "$SETTINGS_FILE" 2>/dev/null || true)
    if [ -z "$DIR" ]; then
      break
    fi
    if [ "$DIR" = "$MODELS_DIR" ]; then
      echo "  $MODELS_DIR is already in oMLX model_dirs."
      return 0
    fi
    i=$((i + 1))
  done

  # Append MODELS_DIR to model_dirs using plutil -append
  echo "  Adding $MODELS_DIR to oMLX model_dirs..."
  plutil -insert model.model_dirs -string "$MODELS_DIR" -append -r "$SETTINGS_FILE"
  echo "  Added $MODELS_DIR to oMLX model_dirs."
  return 0
}

# Function to list models available in oMLX
# Stores result in global OMLX_MODELS variable (newline-separated IDs)
list_omlx_models() {
  OMLX_MODELS=""
  SETTINGS_FILE="$HOME/.omlx/settings.json"

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "  ERROR: oMLX settings file not found at $SETTINGS_FILE"
    return 1
  fi

  # Read port and API key from settings using plutil
  OMLX_PORT=$(plutil -extract server.port raw "$SETTINGS_FILE" 2>/dev/null || echo "")
  OMLX_API_KEY=$(plutil -extract auth.api_key raw "$SETTINGS_FILE" 2>/dev/null || echo "")

  if [ -z "$OMLX_PORT" ] || [ -z "$OMLX_API_KEY" ]; then
    echo "  ERROR: Could not read port or API key from oMLX settings"
    return 1
  fi

  echo "  Connecting to oMLX on localhost:$OMLX_PORT ..."

  # Fetch model list from the API and save to temp file
  TMP_RESPONSE=$(mktemp)
  curl -s -H "Authorization: Bearer $OMLX_API_KEY" "http://localhost:$OMLX_PORT/v1/models" -o "$TMP_RESPONSE" 2>/dev/null

  if [ ! -s "$TMP_RESPONSE" ]; then
    echo "  ERROR: Could not connect to oMLX API"
    rm -f "$TMP_RESPONSE"
    return 1
  fi

  # Use plutil to iterate over the data array and extract IDs
  # plutil doesn't support counting array elements, so we loop until extraction fails
  i=0
  FOUND=0
  while true; do
    MODEL_ID=$(plutil -extract "data.$i.id" raw "$TMP_RESPONSE" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$MODEL_ID" ]; then
      break
    fi
    if [ -z "$OMLX_MODELS" ]; then
      OMLX_MODELS="$MODEL_ID"
    else
      OMLX_MODELS="$OMLX_MODELS
$MODEL_ID"
    fi
    FOUND=$((FOUND + 1))
    i=$((i + 1))
  done

  rm -f "$TMP_RESPONSE"

  return 0
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

  # Pause and ask user to start oMLX
  echo "  Please start oMLX from the Applications folder."
  read -r -p "  Press Enter once oMLX is running..."
  echo ""
fi

# ============================================================
# Connect to oMLX and fetch model list (with retries)
# ============================================================
MAX_RETRIES=3
RETRY=1
OMLX_CONNECTED=false
while [ "$RETRY" -le "$MAX_RETRIES" ]; do
  if [ "$RETRY" -gt 1 ]; then
    echo "  Please make sure oMLX is running."
    read -r -p "  Press Enter to retry (attempt $RETRY of $MAX_RETRIES)..."
    echo ""
  fi

  echo "  === Connecting to oMLX (attempt $RETRY of $MAX_RETRIES) ==="
  if list_omlx_models; then
    OMLX_CONNECTED=true
    break
  fi

  echo ""
  echo "  Could not connect to oMLX."
  RETRY=$((RETRY + 1))
done

if [ "$OMLX_CONNECTED" = false ]; then
  echo ""
  echo "  ERROR: Could not connect to oMLX after $MAX_RETRIES attempts."
  echo "  Please start oMLX and try running this script again."
  exit 1
fi

echo ""
if [ -n "$OMLX_MODELS" ]; then
  echo "  Available models in oMLX:"
  echo "$OMLX_MODELS" | while read -r model_id; do
    echo "    - $model_id"
  done
else
  echo "  No models currently loaded in oMLX (this is expected for a fresh installation)."
fi
echo ""

# ============================================================
# Step 2: Download and install models
# ============================================================
echo "=== Installing models ==="
echo ""

# Function to download and verify a model archive
download_and_verify() {
  archive="$1"
  expected_sha256="$2"

  echo "Downloading $archive..."
  curl -SL -C - -o "$DOWNLOAD_DIR/$archive" "$BASE_URL/$archive"
  echo "  Download complete."

  actual=$(shasum -a 256 "$DOWNLOAD_DIR/$archive" | awk '{print $1}')
  if [ "$actual" != "$expected_sha256" ]; then
    echo "  ERROR: SHA256 mismatch for $archive"
    echo "    Expected: $expected_sha256"
    echo "    Actual:   $actual"
    exit 1
  fi
  echo "  SHA256 verified: $actual"
}

# Check if a model ID is present in the OMLX_MODELS list
model_installed() {
  model_id="$1"
  echo "$OMLX_MODELS" | grep -qx "$model_id"
}

# Download and install each model only if not already present in oMLX
install_model_if_needed() {
  zip_file="$1"
  sha256_sum="$2"
  model_id="$3"

  if model_installed "$model_id"; then
    echo "  Model $model_id is already installed. Skipping."
    echo ""
    return 0
  fi

  echo "  Model $model_id is not installed. Proceeding..."
  echo ""
  download_and_verify "$zip_file" "$sha256_sum"
  echo "Extracting $zip_file to $MODELS_DIR..."
  unzip -q "$DOWNLOAD_DIR/$zip_file" -d "$MODELS_DIR"
  echo "  Extraction complete."
  echo ""
}

install_model_if_needed "$MODEL_ZIP_1" "$MODEL_SHA256_1" "$MODEL_ID_1"
install_model_if_needed "$MODEL_ZIP_2" "$MODEL_SHA256_2" "$MODEL_ID_2"

# Cleanup model downloads
echo "Removing downloaded archives..."
rm -rf "$DOWNLOAD_DIR"

# ============================================================
# Step 3: Configure oMLX to include our models directory
# ============================================================
echo "=== Configuring oMLX ==="
echo ""
configure_omlx_models_dir

echo ""
echo "=== Installation complete ==="
echo "Models installed to: $MODELS_DIR"
ls -la "$MODELS_DIR"

if [ "$SKIP_OMLX" = true ]; then
  echo "oMLX is already installed at $OMLX_APP (version $INSTALLED_VERSION)"
else
  echo "oMLX DMG mounted — please drag oMLX.app to /Applications/"
fi