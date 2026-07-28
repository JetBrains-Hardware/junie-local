#!/bin/sh
set -e

# Helper: wait for user to press any key, then exit
wait_and_exit() {
  echo ""
  echo "Press any key to exit..."
  read -r -n 1
  exit "$1"
}

# ============================================================
# Collect system information
# ============================================================

# OS detection
UNAME_OUT=$(uname -s)
OS_FULL_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
OS_VERSION=$(echo "$OS_FULL_VERSION" | cut -d '.' -f 1)

# CPU model
CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")

# Total memory in GB
MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
MEM_GB=$((MEM_BYTES / 1073741824))

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

# oMLX constants (needed early for detection)
OMLX_APP="/Applications/oMLX.app"
OMLX_SETTINGS="$HOME/.omlx/settings.json"
OMLX_MIN_VERSION="0.5.2"
OMLX_TARGET_VERSION="0.5.3"

# Detect existing oMLX installation
OMLX_INSTALLED=false
OMLX_NEEDS_UPDATE=false
OMLX_EXISTING_VERSION=""
OMLX_EXISTING_PORT=""

if [ -f "$OMLX_SETTINGS" ]; then
  OMLX_EXISTING_PORT=$(plutil -extract server.port raw "$OMLX_SETTINGS" 2>/dev/null || echo "")
fi

if [ -d "$OMLX_APP" ] && [ -n "$OMLX_EXISTING_PORT" ]; then
  OMLX_EXISTING_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OMLX_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
  OMLX_INSTALLED=true
  # Check if version meets minimum requirement
  if [ "$OMLX_EXISTING_VERSION" != "unknown" ]; then
    if ! version_ge "$OMLX_EXISTING_VERSION" "$OMLX_MIN_VERSION"; then
      OMLX_NEEDS_UPDATE=true
    fi
  fi
fi

# Find first free port starting from 8000
check_port_free() {
  # Uses nc (netcat) to test if a port is listening
  # Returns 0 if free, 1 if in use
  ! nc -z localhost "$1" 2>/dev/null
}

if [ "$OMLX_INSTALLED" = true ]; then
  # Use existing oMLX port
  PORT_CANDIDATE="$OMLX_EXISTING_PORT"
else
  # Find first free port
  PORT_CANDIDATE=8000
  while [ "$PORT_CANDIDATE" -lt 9000 ]; do
    if check_port_free "$PORT_CANDIDATE"; then
      break
    fi
    PORT_CANDIDATE=$((PORT_CANDIDATE + 1))
  done
fi

# ============================================================
# System info summary: evaluate & display
# ============================================================
echo "=== Junie Local Model Installer ==="
echo ""
echo "=== System Information ==="
echo ""

# ANSI color helpers
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Helper: print a value in green if ok, yellow if warning, red if not ok
print_value() {
  label="$1"
  value="$2"
  ok="$3"
  warn="$4"
  requirement="$5"
  if [ "$ok" = true ] && [ "$warn" = false ]; then
    printf "  %-20s ${GREEN}%s${NC}\n" "$label" "$value"
  elif [ "$warn" = true ]; then
    printf "  %-20s ${YELLOW}%s${NC}  (%s)\n" "$label" "$value" "$requirement"
  else
    printf "  %-20s ${RED}%s${NC}  (requirement: %s)\n" "$label" "$value" "$requirement"
  fi
}

ALL_OK=true

# OS check (hard requirement: macOS 26+)
OS_OK=true
if [ "$UNAME_OUT" != "Darwin" ]; then
  OS_OK=false
  ALL_OK=false
elif [ "$OS_VERSION" -lt 26 ]; then
  OS_OK=false
  ALL_OK=false
fi
print_value "OS:" "$UNAME_OUT $OS_FULL_VERSION" "$OS_OK" false "macOS 26 or higher"
echo ""

# CPU check (hard: Apple Silicon, recommended: M4 or M5)
CPU_OK=true
CPU_WARN=false
case "$CPU_MODEL" in
  *M4*|*M5*)
    # Fully recommended
    ;;
  *M*)
    # Has Apple Silicon but not M4/M5 — acceptable with warning
    CPU_WARN=true
    ;;
  *)
    # No Apple Silicon — hard fail
    CPU_OK=false
    ALL_OK=false
    ;;
esac
print_value "CPU:" "$CPU_MODEL" "$CPU_OK" "$CPU_WARN" "M4 or M5 recommended"
echo ""

# RAM check (hard: >= 40 GB, recommended: >= 60 GB)
RAM_OK=true
RAM_WARN=false
if [ "$MEM_GB" -lt 40 ]; then
  RAM_OK=false
  ALL_OK=false
elif [ "$MEM_GB" -lt 60 ]; then
  RAM_WARN=true
fi
print_value "RAM:" "${MEM_GB} GB" "$RAM_OK" "$RAM_WARN" "minimum 40 GB, 60 GB recommended"
echo ""

# RAM allowance for inference (weights + KV cache)
OMLX_MODEL_RAM_GB="${1:-35}"

# oMLX status — in System Information if installed, in Install Configuration if not
if [ "$OMLX_INSTALLED" = true ]; then
  if [ "$OMLX_NEEDS_UPDATE" = true ]; then
    print_value "oMLX:" "v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}" true true "will be updated to v${OMLX_TARGET_VERSION}"
  else
    print_value "oMLX:" "v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}" true false ""
  fi
fi
echo ""

# Install Configuration section
echo "=== Install Configuration ==="
echo ""

if [ "$OMLX_INSTALLED" = false ]; then
  print_value "oMLX:" "not installed" true true "will install v${OMLX_TARGET_VERSION} on port ${PORT_CANDIDATE}"
fi
print_value "RAM allowance:" "${OMLX_MODEL_RAM_GB} GB" true false ""
echo ""

# ============================================================
# Decision: proceed or exit
# ============================================================
if [ "$ALL_OK" = false ]; then
  echo "Some system requirements are not met. Installation cannot proceed."
  wait_and_exit 1
fi

# All hard requirements met — ask user to confirm
read -r -p "Do you want to continue with these settings? [Y/n] " CONTINUE_ANSWER
case "$CONTINUE_ANSWER" in
  [nN]|[nN][oO])
    echo ""
    echo "You can customize the configuration."
    echo ""
    if [ "$OMLX_INSTALLED" = false ]; then
      read -r -p "Port [${PORT_CANDIDATE}]: " CUSTOM_PORT
      CUSTOM_PORT="${CUSTOM_PORT:-$PORT_CANDIDATE}"
      PORT_CANDIDATE="$CUSTOM_PORT"
    fi
    read -r -p "RAM allowance (GB) [${OMLX_MODEL_RAM_GB}]: " CUSTOM_RAM
    CUSTOM_RAM="${CUSTOM_RAM:-$OMLX_MODEL_RAM_GB}"
    OMLX_MODEL_RAM_GB="$CUSTOM_RAM"
    echo ""
    echo "Updated configuration:"
    if [ "$OMLX_INSTALLED" = false ]; then
      print_value "oMLX:" "not installed" true true "will install v${OMLX_TARGET_VERSION} on port ${PORT_CANDIDATE}"
    fi
    print_value "RAM allowance:" "${OMLX_MODEL_RAM_GB} GB" true false ""
    echo ""
    read -r -p "Proceed with these settings? [Y/n] " FINAL_ANSWER
    case "$FINAL_ANSWER" in
      [nN]|[nN][oO])
        echo "Installation cancelled."
        wait_and_exit 1
        ;;
      *)
        echo ""
        ;;
    esac
    ;;
  *)
    echo ""
    ;;
esac

# Configuration
BASE_URL="https://junie-local.erokhins.com"
BASE_DIR="$HOME/.local/share/junie-local"
MODELS_DIR="$BASE_DIR/models"
DOWNLOAD_DIR="$BASE_DIR/incomplete_downloads"

# oMLX DMG
OMLX_URL="https://github.com/jundot/omlx/releases/download/v0.5.3/oMLX-0.5.3-macos26-27.dmg"
OMLX_FILE="oMLX-0.5.3-macos26-27.dmg"
OMLX_SHA256="15a2a74e20bf4518d6f6133af4ecc0f3e4c6610f3127c1612ae6178ef749a4c8"

# Model archives, their SHA256 checksums, and corresponding oMLX model IDs
MODEL_ZIP_1="models--mlx-community--Qwen3.6-27B-4bit.zip"
MODEL_SHA256_1="adf7f8d832ed994dcc6d09372036b4d12f49a4ccda066179cc64dc2dd113f91d"
MODEL_ID_1="mlx-community--Qwen3.6-27B-4bit"
MODEL_ZIP_2="models--mlx-community--Qwen3.6-27B-MTP-4bit.zip"
MODEL_SHA256_2="9266c1ba244ec6176fc82474bbfd20614969eb28c4cfa24301e515fbd1f5a525"
MODEL_ID_2="mlx-community--Qwen3.6-27B-MTP-4bit"

# oMLX cache configuration (default: 35 GB total RAM for oMLX)
OMLX_RAM_GB="${1:-35}"
OMLX_SSD_CACHE_MAX="50GB"
OMLX_HOT_CACHE_MAX="$((OMLX_RAM_GB - 17))GB"

# Junie model configuration
# TODO: calculate it
JUNIE_MAX_CONTEXT_LENGTH=90000


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

  wait_and_exit "$exit_code"
}

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# Create directories
echo "Creating directories..."
mkdir -p "$MODELS_DIR"
mkdir -p "$DOWNLOAD_DIR"

# Function to download a file with retry logic and exponential backoff
# Usage: download_with_retry <url> <output_file> [max_retries]
download_with_retry() {
  url="$1"
  output_file="$2"
  max_retries="${3:-3}"
  attempt=1
  delay=2

  while [ "$attempt" -le "$max_retries" ]; do
    echo "  Attempt $attempt of $max_retries..."
    if curl --progress-bar -SL -C - -o "$output_file" "$url"; then
      return 0
    fi

    if [ "$attempt" -lt "$max_retries" ]; then
      echo "  Download failed. Retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done

  echo "  ERROR: Download failed after $max_retries attempts."
  return 1
}

# Function to configure oMLX cache settings
configure_omlx_cache() {
  SETTINGS_FILE="$HOME/.omlx/settings.json"

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "  WARNING: oMLX settings file not found at $SETTINGS_FILE"
    echo "  Skipping cache configuration."
    return 1
  fi

  echo "  Configuring oMLX cache (hot: $OMLX_HOT_CACHE_MAX, SSD: $OMLX_SSD_CACHE_MAX)..."
  plutil -replace "cache.hot_cache_max_size" -string "$OMLX_HOT_CACHE_MAX" "$SETTINGS_FILE"
  plutil -replace "cache.ssd_cache_max_size" -string "$OMLX_SSD_CACHE_MAX" "$SETTINGS_FILE"
  echo "  Cache configuration updated."
  return 0
}

# Function to generate a random API key for oMLX
generate_api_key() {
  # Generate a random 24-character hex string
  printf 'sk-omlx-%s' "$(head -c 12 /dev/urandom | xxd -p)"
}

# Function to create oMLX settings.json for fresh installations
create_omlx_settings() {
  SETTINGS_DIR="$HOME/.omlx"
  SETTINGS_FILE="$SETTINGS_DIR/settings.json"

  if [ -f "$SETTINGS_FILE" ]; then
    echo "  oMLX settings already exist at $SETTINGS_FILE. Skipping."
    return 0
  fi

  # Create .omlx directory if it doesn't exist
  mkdir -p "$SETTINGS_DIR"

  # Generate a random API key
  OMLX_API_KEY=$(generate_api_key)

  echo "  Creating oMLX settings at $SETTINGS_FILE..."
  cat > "$SETTINGS_FILE" <<EOF
{
  "server": {
    "port": $PORT_CANDIDATE
  },
  "model": {
    "model_dirs": [
      "$HOME/.omlx/models",
      "$MODELS_DIR"
    ],
    "model_dir": "$HOME/.omlx/models"
  },
  "cache": {
    "ssd_cache_max_size": "$OMLX_SSD_CACHE_MAX",
    "hot_cache_max_size": "$OMLX_HOT_CACHE_MAX"
  },
  "auth": {
    "api_key": "$OMLX_API_KEY"
  }
}
EOF
  echo "  oMLX settings created."
  return 0
}

# Function to create Junie model config file
create_junie_model_config() {
  JUNIE_MODELS_DIR="$HOME/.junie/models"
  JUNIE_CONFIG_FILE="$JUNIE_MODELS_DIR/local-qwen3.6-27b-4bit.json"
  SETTINGS_FILE="$HOME/.omlx/settings.json"

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "  WARNING: oMLX settings file not found at $SETTINGS_FILE"
    echo "  Skipping Junie model config creation."
    return 1
  fi

  # Read port and API key from oMLX settings
  SERVER_PORT=$(plutil -extract "server.port" raw "$SETTINGS_FILE" 2>/dev/null || true)
  API_KEY=$(plutil -extract "auth.api_key" raw "$SETTINGS_FILE" 2>/dev/null || true)

  if [ -z "$SERVER_PORT" ] || [ -z "$API_KEY" ]; then
    echo "  WARNING: Could not read port or API key from oMLX settings."
    echo "  Skipping Junie model config creation."
    return 1
  fi

  # Create ~/.junie/models directory if it doesn't exist
  if [ ! -d "$JUNIE_MODELS_DIR" ]; then
    mkdir -p "$JUNIE_MODELS_DIR"
  fi

  # Write the Junie model config
  echo "  Creating Junie model config at $JUNIE_CONFIG_FILE..."
  cat > "$JUNIE_CONFIG_FILE" <<EOF
{
  "id": "$MODEL_ID_1",
  "baseUrl": "http://localhost:$SERVER_PORT/v1/chat/completions",
  "apiType": "OpenAICompletion",
  "apiKey": "$API_KEY",
  "temperature": 0.6,
  "maxContextLength": $JUNIE_MAX_CONTEXT_LENGTH,
  "extraBody": {
    "enable_thinking": false
  }
}
EOF
  echo "  Junie model config created."
  return 0
}

# Function to restart oMLX server to load new settings
restart_omlx() {
  OMLX_CLI="/Applications/oMLX.app/Contents/MacOS/omlx-cli"
  if [ ! -x "$OMLX_CLI" ]; then
    echo "  WARNING: omlx-cli not found at $OMLX_CLI"
    echo "  Please restart oMLX manually to apply settings."
    return 1
  fi
  echo "  Restarting oMLX server..."
  "$OMLX_CLI" restart
  echo "  oMLX server restarted."
  return 0
}

# Function to configure model settings for Qwen3.6-27B-4bit
configure_model_settings() {
  MODEL_SETTINGS_FILE="$HOME/.omlx/model_settings.json"
  MODEL_ID="mlx-community--Qwen3.6-27B-4bit"
  KEY_PATH="models.mlx-community--Qwen3\.6-27B-4bit"

  if [ ! -f "$MODEL_SETTINGS_FILE" ]; then
    echo "  Creating model_settings.json at $MODEL_SETTINGS_FILE..."
    echo '{"version": 1, "models": {}}' > "$MODEL_SETTINGS_FILE"
  fi

  # Check if model config already exists
  EXISTING=$(plutil -extract "$KEY_PATH" json -o - "$MODEL_SETTINGS_FILE" 2>/dev/null || true)
  if [ -n "$EXISTING" ]; then
    echo "  Model settings for $MODEL_ID already configured."
    return 0
  fi

  # Write the model configuration
  echo "  Configuring model settings for $MODEL_ID..."
  plutil -insert "$KEY_PATH" -json '{"force_sampling":false,"enable_thinking":false,"thinking_budget_enabled":false,"guided_grammar_enabled":false,"turboquant_kv_enabled":false,"turboquant_kv_bits":4.0,"turboquant_skip_last":true,"specprefill_enabled":false,"dflash_enabled":false,"dflash_draft_quant_enabled":false,"dflash_in_memory_cache":true,"dflash_in_memory_cache_max_entries":4,"dflash_in_memory_cache_max_bytes":8589934592,"dflash_ssd_cache":false,"dflash_ssd_cache_max_bytes":21474836480,"mtp_enabled":false,"vlm_mtp_enabled":true,"vlm_mtp_draft_model":"mlx-community--Qwen3.6-27B-MTP-4bit","vlm_mtp_draft_block_size":4,"is_pinned":false,"is_default":false,"is_hidden":false,"is_favorite":false,"trust_remote_code":false}' -r "$MODEL_SETTINGS_FILE"
  echo "  Model settings for $MODEL_ID configured."
  return 0
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


# ============================================================
# Step 1: oMLX setup
# ============================================================
echo "=== Setting up oMLX ==="
echo ""

install_omlx() {
  # Download and install oMLX DMG
  echo "  Downloading $OMLX_FILE..."
  download_with_retry "$OMLX_URL" "$DOWNLOAD_DIR/$OMLX_FILE"
  echo "  Download complete."

  # Verify SHA256 checksum
  actual_sha256=$(shasum -a 256 "$DOWNLOAD_DIR/$OMLX_FILE" | awk '{print $1}')
  if [ "$actual_sha256" != "$OMLX_SHA256" ]; then
    echo "  ERROR: SHA256 mismatch for $OMLX_FILE"
    echo "    Expected: $OMLX_SHA256"
    echo "    Actual:   $actual_sha256"
    wait_and_exit 1
  fi
  echo "  SHA256 verified: $actual_sha256"

  # Mount and open oMLX DMG
  echo "  Opening oMLX DMG..."
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
}

if [ "$OMLX_INSTALLED" = true ] && [ "$OMLX_NEEDS_UPDATE" = false ]; then
  # Path A: Reuse existing oMLX
  echo "  Reusing existing oMLX v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}."
  echo ""
elif [ "$OMLX_INSTALLED" = true ] && [ "$OMLX_NEEDS_UPDATE" = true ]; then
  # Path B: Update existing oMLX
  echo "  Updating oMLX from v${OMLX_EXISTING_VERSION} to v${OMLX_TARGET_VERSION}..."
  echo ""
  install_omlx
else
  # Path C: Fresh install
  echo "  Installing oMLX v${OMLX_TARGET_VERSION} on port ${PORT_CANDIDATE}..."
  echo ""
  install_omlx
  create_omlx_settings
fi

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
  download_with_retry "$BASE_URL/$archive" "$DOWNLOAD_DIR/$archive"
  echo "  Download complete."

  actual=$(shasum -a 256 "$DOWNLOAD_DIR/$archive" | awk '{print $1}')
  if [ "$actual" != "$expected_sha256" ]; then
    echo "  ERROR: SHA256 mismatch for $archive"
    echo "    Expected: $expected_sha256"
    echo "    Actual:   $actual"
    wait_and_exit 1
  fi
  echo "  SHA256 verified: $actual"
}

# Check if a model has been unzipped to the models directory
# The zip files are named models--<model_id>.zip, so the extracted dir has a "models--" prefix
model_installed() {
  model_id="$1"
  [ -d "$MODELS_DIR/models--$model_id" ]
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
# Step 3: Configure oMLX
# ============================================================
echo "=== Configuring oMLX ==="
echo ""
configure_omlx_models_dir
configure_model_settings
configure_omlx_cache
restart_omlx
create_junie_model_config

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Models installed to: $MODELS_DIR"
echo "  oMLX SSD cache: $OMLX_SSD_CACHE_MAX"
echo "  oMLX hot cache: $OMLX_HOT_CACHE_MAX"
echo "  Model memory: ~17 GB"
echo "  Total oMLX memory: ${OMLX_RAM_GB}GB"
echo ""
echo "  Now you can use your local model in Junie:"
echo "  Use /models command and choose local-qwen3.6-27b-4bit"
wait_and_exit 0
