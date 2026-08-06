#!/bin/sh
set -e

# ============================================================
# Command-line arguments
# ============================================================

PROTOCOL_VERSION=1

MACHINE_OUTPUT=false
CHECK_ONLY=false
ASSUME_YES=false
ARG_RAM=""
ARG_PORT=""

usage() {
  echo "Usage: install.sh [RAM_GB] [options]"
  echo ""
  echo "Options:"
  echo "  --ram N       RAM allowance in GB for inference (default: 35, min 18)"
  echo "  --port N      Port for a fresh oMLX install (default: first free port in 8000-8999)"
  echo "  --yes, -y     Skip the confirmation prompt"
  echo "  --check-only  Report system information and install configuration, then exit"
  echo "  --json        Emit machine-readable events on stdout, human output on stderr (implies --yes)"
  echo "  --help, -h    Show this help"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) MACHINE_OUTPUT=true; ASSUME_YES=true ;;
    --check-only) CHECK_ONLY=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --ram) shift; ARG_RAM="${1:-}" ;;
    --ram=*) ARG_RAM="${1#--ram=}" ;;
    --port) shift; ARG_PORT="${1:-}" ;;
    --port=*) ARG_PORT="${1#--port=}" ;;
    --help|-h) usage; exit 0 ;;
    -*) echo "ERROR: Unknown option: $1"; usage; exit 1 ;;
    *) ARG_RAM="$1" ;;
  esac
  shift
done

if [ "$MACHINE_OUTPUT" = true ]; then
  # stdout carries only machine events; human-oriented output goes to stderr
  exec 3>&1 1>&2
fi

# ============================================================
# Machine-readable events (--json): one JSON object per line on stdout
#   {"event":"hello","protocol":1}
#   {"event":"check","name":"os|cpu|ram|omlx","status":"ok|warn|fail","value":"...","requirement":"..."}
#   {"event":"config","port":N,"ram_gb":N,"omlx_installed":true|false,"omlx_version":"...","checks_passed":true|false}
#   {"event":"step_start","id":"omlx|models|configure","title":"..."}
#   {"event":"progress","file":"...","bytes":N,"total":N,"label":"..."}
#   {"event":"activity","action":"verifying|extracting","file":"...","label":"..."}
#   {"event":"step_done","id":"omlx|models|configure"}
#   {"event":"warning","message":"..."}
#   {"event":"error","message":"..."}
#   {"event":"done","model_id":"...","port":N}
# Consumers must check the protocol version in "hello" and ignore
# unknown event types and fields.
# ============================================================

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit_event() {
  if [ "$MACHINE_OUTPUT" = true ]; then
    printf '{%s}\n' "$1" >&3
  fi
}

emit_check() {
  emit_event "\"event\":\"check\",\"name\":\"$1\",\"status\":\"$2\",\"value\":\"$(json_escape "$3")\",\"requirement\":\"$(json_escape "$4")\""
}

emit_step_start() {
  emit_event "\"event\":\"step_start\",\"id\":\"$1\",\"title\":\"$(json_escape "$2")\""
}

emit_step_done() {
  emit_event "\"event\":\"step_done\",\"id\":\"$1\""
}

emit_progress() {
  emit_event "\"event\":\"progress\",\"file\":\"$(json_escape "$1")\",\"bytes\":${2:-0},\"total\":${3:-0},\"label\":\"$(json_escape "$4")\""
}

emit_activity() {
  emit_event "\"event\":\"activity\",\"action\":\"$1\",\"file\":\"$(json_escape "$2")\",\"label\":\"$(json_escape "$3")\""
}

emit_warning() {
  emit_event "\"event\":\"warning\",\"message\":\"$(json_escape "$1")\""
}

emit_error() {
  emit_event "\"event\":\"error\",\"message\":\"$(json_escape "$1")\""
}

# Map an ok/warn flag pair to a check status
check_status() {
  if [ "$1" != true ]; then
    echo "fail"
  elif [ "$2" = true ]; then
    echo "warn"
  else
    echo "ok"
  fi
}

emit_event "\"event\":\"hello\",\"protocol\":$PROTOCOL_VERSION"

# Helper: wait for user to press any key, then exit
wait_and_exit() {
  if [ "$MACHINE_OUTPUT" != true ]; then
    echo ""
    echo "Press any key to exit..."
    # If read fails, still exit with the intended code (not read's status)
    read -r -n 1 || true
  fi
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

# RAM allowance must be a whole number of at least 18 GB
# (17 GB is reserved for model weights, the rest goes to the hot cache)
is_valid_ram() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 18 ]
}

# Port must be a whole number in 1024-65535
is_valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

# oMLX constants (needed early for detection)
OMLX_SETTINGS="$HOME/.omlx/settings.json"
OMLX_MIN_VERSION="0.5.2"
OMLX_TARGET_VERSION="0.5.3"
OMLX_INSTALL_DIR="$HOME/Applications"

# Detect existing oMLX installation in /Applications or ~/Applications
find_omlx_app() {
  if [ -d "/Applications/oMLX.app" ]; then
    echo "/Applications/oMLX.app"
  elif [ -d "$HOME/Applications/oMLX.app" ]; then
    echo "$HOME/Applications/oMLX.app"
  else
    echo ""
  fi
}

OMLX_APP=$(find_omlx_app)

# Detect existing oMLX installation
OMLX_INSTALLED=false
OMLX_NEEDS_UPDATE=false
OMLX_EXISTING_VERSION=""
OMLX_EXISTING_PORT=""

if [ -f "$OMLX_SETTINGS" ]; then
  OMLX_EXISTING_PORT=$(plutil -extract server.port raw "$OMLX_SETTINGS" 2>/dev/null || echo "")
fi

if [ -n "$OMLX_APP" ] && [ -n "$OMLX_EXISTING_PORT" ]; then
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
  if [ "$PORT_CANDIDATE" -ge 9000 ]; then
    echo "ERROR: No free port found in range 8000-8999."
    emit_error "No free port found in range 8000-8999"
    wait_and_exit 1
  fi
fi

# Port override from --port (only meaningful for a fresh install)
if [ -n "$ARG_PORT" ]; then
  if [ "$OMLX_INSTALLED" = true ]; then
    echo "WARNING: --port is ignored because oMLX is already installed on port ${OMLX_EXISTING_PORT}."
    emit_warning "--port is ignored because oMLX is already installed on port ${OMLX_EXISTING_PORT}"
  elif is_valid_port "$ARG_PORT"; then
    PORT_CANDIDATE="$ARG_PORT"
  else
    echo "ERROR: Invalid port '$ARG_PORT' (must be 1024-65535)."
    emit_error "Invalid port '$ARG_PORT' (must be 1024-65535)"
    wait_and_exit 1
  fi
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

if [ "$MACHINE_OUTPUT" = true ]; then
  GREEN=''
  RED=''
  YELLOW=''
  NC=''
fi

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
emit_check "os" "$(check_status "$OS_OK" false)" "$UNAME_OUT $OS_FULL_VERSION" "macOS 26 or higher"
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
emit_check "cpu" "$(check_status "$CPU_OK" "$CPU_WARN")" "$CPU_MODEL" "M4 or M5 recommended"
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
emit_check "ram" "$(check_status "$RAM_OK" "$RAM_WARN")" "${MEM_GB} GB" "minimum 40 GB, 60 GB recommended"
echo ""

# RAM allowance for inference (weights + KV cache)
OMLX_MODEL_RAM_GB="${ARG_RAM:-35}"
if ! is_valid_ram "$OMLX_MODEL_RAM_GB"; then
  printf "  ${RED}ERROR:${NC} RAM allowance must be a whole number of at least 18 GB (got: %s)\n" "$OMLX_MODEL_RAM_GB"
  emit_error "RAM allowance must be a whole number of at least 18 GB (got: $OMLX_MODEL_RAM_GB)"
  wait_and_exit 1
fi

# oMLX status — in System Information if installed, in Install Configuration if not
# An installed oMLX older than the minimum version is a hard failure:
# the user must update it manually before re-running the installer.
if [ "$OMLX_INSTALLED" = true ]; then
  if [ "$OMLX_NEEDS_UPDATE" = true ]; then
    ALL_OK=false
    print_value "oMLX:" "v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}" false false "v${OMLX_MIN_VERSION} or higher — please update oMLX manually and re-run"
    emit_check "omlx" "fail" "v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}" "v${OMLX_MIN_VERSION} or higher — please update oMLX manually and re-run"
  else
    print_value "oMLX:" "v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}" true false ""
    emit_check "omlx" "ok" "v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}" ""
  fi
fi
echo ""

# Install Configuration section
echo "=== Install Configuration ==="
echo ""

if [ "$OMLX_INSTALLED" = false ]; then
  print_value "oMLX:" "not installed" true true "This script will install version v${OMLX_TARGET_VERSION} on port ${PORT_CANDIDATE}"
fi
print_value "RAM allowance:" "${OMLX_MODEL_RAM_GB} GB" true false ""
if [ "$OMLX_INSTALLED" = true ]; then
  echo ""
  echo "  Note: existing oMLX cache settings will be updated to match the RAM allowance."
fi
echo ""

emit_event "\"event\":\"config\",\"port\":$PORT_CANDIDATE,\"ram_gb\":$OMLX_MODEL_RAM_GB,\"omlx_installed\":$OMLX_INSTALLED,\"omlx_version\":\"$(json_escape "$OMLX_EXISTING_VERSION")\",\"checks_passed\":$ALL_OK"

if [ "$CHECK_ONLY" = true ]; then
  if [ "$ALL_OK" = true ]; then
    exit 0
  else
    exit 1
  fi
fi

# ============================================================
# Decision: proceed or exit
# ============================================================
if [ "$ALL_OK" = false ]; then
  echo "Some system requirements are not met. Installation cannot proceed."
  emit_error "Some system requirements are not met. Installation cannot proceed."
  wait_and_exit 1
fi

# All hard requirements met — ask user to confirm (skipped with --yes/--json)
if [ "$ASSUME_YES" = true ]; then
  CONTINUE_ANSWER="y"
else
  read -r -p "Do you want to continue with these settings? [Y/n] " CONTINUE_ANSWER
fi
case "$CONTINUE_ANSWER" in
  [nN]|[nN][oO])
    echo ""
    echo "You can customize the configuration."
    echo ""
    if [ "$OMLX_INSTALLED" = false ]; then
      read -r -p "Port [${PORT_CANDIDATE}]: " CUSTOM_PORT
      CUSTOM_PORT="${CUSTOM_PORT:-$PORT_CANDIDATE}"
      if is_valid_port "$CUSTOM_PORT"; then
        PORT_CANDIDATE="$CUSTOM_PORT"
      else
        echo "  Invalid port '$CUSTOM_PORT' (must be 1024-65535) — keeping ${PORT_CANDIDATE}."
      fi
    fi
    read -r -p "RAM allowance (GB) [${OMLX_MODEL_RAM_GB}]: " CUSTOM_RAM
    CUSTOM_RAM="${CUSTOM_RAM:-$OMLX_MODEL_RAM_GB}"
    if is_valid_ram "$CUSTOM_RAM"; then
      OMLX_MODEL_RAM_GB="$CUSTOM_RAM"
    else
      echo "  Invalid RAM allowance '$CUSTOM_RAM' (whole number, min 18) — keeping ${OMLX_MODEL_RAM_GB} GB."
    fi
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
BASE_URL="https://download.jetbrains.com/resources/junie-local"
BASE_DIR="$HOME/.local/share/junie-local"
MODELS_DIR="$BASE_DIR/models"
DOWNLOAD_DIR="$BASE_DIR/incomplete_downloads"

# oMLX DMG
OMLX_URL="https://github.com/jundot/omlx/releases/download/v0.5.3/oMLX-0.5.3-macos26-27.dmg"
OMLX_FILE="oMLX-0.5.3-macos26-27.dmg"
OMLX_SHA256="15a2a74e20bf4518d6f6133af4ecc0f3e4c6610f3127c1612ae6178ef749a4c8"
OMLX_LABEL="oMLX server"

# Model archives, their SHA256 checksums, corresponding oMLX model IDs, and display labels
MODEL_ZIP_1="models--mlx-community--Qwen3.6-27B-4bit.zip"
MODEL_SHA256_1="adf7f8d832ed994dcc6d09372036b4d12f49a4ccda066179cc64dc2dd113f91d"
MODEL_ID_1="mlx-community--Qwen3.6-27B-4bit"
MODEL_LABEL_1="Local Qwen 3.6 27B 4bit"
MODEL_ZIP_2="models--mlx-community--Qwen3.6-27B-MTP-4bit.zip"
MODEL_SHA256_2="9266c1ba244ec6176fc82474bbfd20614969eb28c4cfa24301e515fbd1f5a525"
MODEL_ID_2="mlx-community--Qwen3.6-27B-MTP-4bit"
MODEL_LABEL_2="MTP draft model"

# oMLX cache configuration (derived from the RAM allowance, default 35 GB)
OMLX_SSD_CACHE_MAX="50GB"
OMLX_HOT_CACHE_MAX="$((OMLX_MODEL_RAM_GB - 17))GB"

# Junie model configuration
JUNIE_MODEL_ID="local-qwen3.6-27b-4bit"
JUNIE_CUSTOM_MODEL_ID="custom:local-qwen3.6-27b-4bit"
# TODO: calculate it
JUNIE_MAX_CONTEXT_LENGTH=90000


# Cleanup function — kills child processes on interrupt
cleanup() {
  exit_code="$1"

  # Avoid executing this trap recursively.
  trap - INT TERM

  echo ""
  if [ -d "$DOWNLOAD_DIR" ]; then
    echo "Interrupted — partial downloads preserved in $DOWNLOAD_DIR"
    echo "Re-run this script to resume."
    emit_error "Interrupted — partial downloads preserved, re-run to resume"
  else
    echo "Interrupted."
    emit_error "Interrupted"
  fi

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

# Download while emitting progress events, polling the output file size.
# The total comes from a HEAD request; with resumed downloads the file size
# is absolute, so bytes/total stays correct across re-runs.
download_with_progress_events() {
  url="$1"
  output_file="$2"
  label="$3"
  file_name=$(basename "$output_file")

  total=$(curl -sIL "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "content-length:" { len = $2 } END { print len + 0 }')

  curl -sSL -C - -o "$output_file" "$url" &
  download_pid=$!
  while kill -0 "$download_pid" 2>/dev/null; do
    bytes=$(stat -f %z "$output_file" 2>/dev/null || echo 0)
    emit_progress "$file_name" "$bytes" "$total" "$label"
    sleep 1
  done
  if wait "$download_pid"; then
    emit_progress "$file_name" "$(stat -f %z "$output_file" 2>/dev/null || echo 0)" "$total" "$label"
    return 0
  fi
  return 1
}

# Function to download a file with retry logic and exponential backoff
# Usage: download_with_retry <url> <output_file> <label> [max_retries]
download_with_retry() {
  url="$1"
  output_file="$2"
  dl_label="$3"
  max_retries="${4:-3}"
  attempt=1
  delay=2

  while [ "$attempt" -le "$max_retries" ]; do
    echo "  Attempt $attempt of $max_retries..."
    if [ "$MACHINE_OUTPUT" = true ]; then
      if download_with_progress_events "$url" "$output_file" "$dl_label"; then
        return 0
      fi
    elif curl --progress-bar -SL -C - -o "$output_file" "$url"; then
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
  emit_error "Download failed after $max_retries attempts"
  return 1
}

# Function to configure oMLX cache settings
configure_omlx_cache() {
  SETTINGS_FILE="$HOME/.omlx/settings.json"

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "  WARNING: oMLX settings file not found at $SETTINGS_FILE"
    echo "  Skipping cache configuration."
    emit_warning "oMLX settings file not found — skipped cache configuration"
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
  JUNIE_CONFIG_FILE="$JUNIE_MODELS_DIR/${JUNIE_MODEL_ID}.json"
  SETTINGS_FILE="$HOME/.omlx/settings.json"

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "  WARNING: oMLX settings file not found at $SETTINGS_FILE"
    echo "  Skipping Junie model config creation."
    emit_warning "oMLX settings file not found — skipped Junie model config creation"
    return 1
  fi

  # Read port and API key from oMLX settings
  SERVER_PORT=$(plutil -extract "server.port" raw "$SETTINGS_FILE" 2>/dev/null || true)
  API_KEY=$(plutil -extract "auth.api_key" raw "$SETTINGS_FILE" 2>/dev/null || true)

  if [ -z "$SERVER_PORT" ] || [ -z "$API_KEY" ]; then
    echo "  WARNING: Could not read port or API key from oMLX settings."
    echo "  Skipping Junie model config creation."
    emit_warning "Could not read port or API key from oMLX settings — skipped Junie model config creation"
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

# Function to set the local model as the default in Junie settings
set_default_junie_model() {
  JUNIE_SETTINGS="$HOME/.junie/settings.json"

  if [ ! -f "$JUNIE_SETTINGS" ]; then
    echo "  WARNING: Junie settings not found at $JUNIE_SETTINGS"
    echo "  Skipping default model configuration."
    emit_warning "Junie settings not found — the local model was not set as default"
    return 1
  fi

  echo "  Setting local model as default in Junie..."
  plutil -replace "modelForLaunch" -string "$JUNIE_CUSTOM_MODEL_ID" "$JUNIE_SETTINGS"
  echo "  Default model set to $JUNIE_MODEL_ID."
  return 0
}

# Function to find oMLX CLI in either /Applications or ~/Applications
find_omlx_cli() {
  if [ -x "/Applications/oMLX.app/Contents/MacOS/omlx-cli" ]; then
    echo "/Applications/oMLX.app/Contents/MacOS/omlx-cli"
  elif [ -x "$HOME/Applications/oMLX.app/Contents/MacOS/omlx-cli" ]; then
    echo "$HOME/Applications/oMLX.app/Contents/MacOS/omlx-cli"
  else
    echo ""
  fi
}

# Function to restart oMLX server to load new settings
restart_omlx() {
  OMLX_CLI=$(find_omlx_cli)
  if [ -z "$OMLX_CLI" ]; then
    echo "  WARNING: omlx-cli not found."
    echo "  Please restart oMLX manually to apply settings."
    emit_warning "omlx-cli not found — restart oMLX manually to apply settings"
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
  MODEL_ID="$MODEL_ID_1"
  # Dots in the model ID must be escaped in plutil key paths
  KEY_PATH="models.$(printf '%s' "$MODEL_ID" | sed 's/\./\\./g')"

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
  plutil -insert "$KEY_PATH" -json '{"force_sampling":false,"enable_thinking":false,"thinking_budget_enabled":false,"guided_grammar_enabled":false,"turboquant_kv_enabled":false,"turboquant_kv_bits":4.0,"turboquant_skip_last":true,"specprefill_enabled":false,"dflash_enabled":false,"dflash_draft_quant_enabled":false,"dflash_in_memory_cache":true,"dflash_in_memory_cache_max_entries":4,"dflash_in_memory_cache_max_bytes":8589934592,"dflash_ssd_cache":false,"dflash_ssd_cache_max_bytes":21474836480,"mtp_enabled":false,"vlm_mtp_enabled":true,"vlm_mtp_draft_model":"'"$MODEL_ID_2"'","vlm_mtp_draft_block_size":4,"is_pinned":false,"is_default":false,"is_hidden":false,"is_favorite":false,"trust_remote_code":false}' -r "$MODEL_SETTINGS_FILE"
  echo "  Model settings for $MODEL_ID configured."
  return 0
}

# Function to add MODELS_DIR to oMLX model_dirs if not already present
configure_omlx_models_dir() {
  SETTINGS_FILE="$HOME/.omlx/settings.json"

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "  WARNING: oMLX settings file not found at $SETTINGS_FILE"
    echo "  Skipping model_dirs configuration."
    emit_warning "oMLX settings file not found — skipped model_dirs configuration"
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
emit_step_start "omlx" "Setting up oMLX"

install_omlx() {
  # Download oMLX DMG
  echo "  Downloading $OMLX_FILE..."
  download_with_retry "$OMLX_URL" "$DOWNLOAD_DIR/$OMLX_FILE" "$OMLX_LABEL"
  echo "  Download complete."

  # Verify SHA256 checksum
  emit_activity "verifying" "$OMLX_FILE" "$OMLX_LABEL"
  actual_sha256=$(shasum -a 256 "$DOWNLOAD_DIR/$OMLX_FILE" | awk '{print $1}')
  if [ "$actual_sha256" != "$OMLX_SHA256" ]; then
    echo "  ERROR: SHA256 mismatch for $OMLX_FILE"
    echo "    Expected: $OMLX_SHA256"
    echo "    Actual:   $actual_sha256"
    emit_error "SHA256 mismatch for $OMLX_FILE"
    wait_and_exit 1
  fi
  echo "  SHA256 verified: $actual_sha256"

  # Mount DMG to a temporary location
  MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omlx-install.XXXXXX")
  echo "  Mounting oMLX DMG..."
  hdiutil attach "$DOWNLOAD_DIR/$OMLX_FILE" -nobrowse -readonly -mountpoint "$MOUNT_DIR" > /dev/null

  SOURCE="$MOUNT_DIR/oMLX.app"
  DESTINATION="$OMLX_INSTALL_DIR/oMLX.app"

  if [ ! -d "$SOURCE" ]; then
    echo "  ERROR: oMLX.app not found inside DMG."
    emit_error "oMLX.app not found inside DMG"
    hdiutil detach "$MOUNT_DIR" -quiet > /dev/null 2>&1 || true
    rmdir "$MOUNT_DIR" > /dev/null 2>&1 || true
    wait_and_exit 1
  fi

  # Create user Applications directory if needed
  mkdir -p "$OMLX_INSTALL_DIR"

  # Remove previous version if it exists
  if [ -e "$DESTINATION" ]; then
    echo "  Removing existing version..."
    rm -rf "$DESTINATION"
  fi

  # Copy oMLX.app to user Applications
  echo "  Installing oMLX to $DESTINATION..."
  /usr/bin/ditto "$SOURCE" "$DESTINATION"

  # Unmount DMG and clean up
  hdiutil detach "$MOUNT_DIR" -quiet > /dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" > /dev/null 2>&1 || true
  rm -f "$DOWNLOAD_DIR/$OMLX_FILE"

  echo "  oMLX installed successfully."
  echo ""
}

if [ "$OMLX_INSTALLED" = true ]; then
  # Reuse existing oMLX (an outdated version already failed the system check above)
  echo "  Reusing existing oMLX v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}."
  echo ""
else
  # Fresh install
  echo "  Installing oMLX v${OMLX_TARGET_VERSION} on port ${PORT_CANDIDATE}..."
  echo ""
  install_omlx
  create_omlx_settings
fi
emit_step_done "omlx"

# ============================================================
# Step 2: Download and install models
# ============================================================
echo "=== Installing models ==="
echo ""
emit_step_start "models" "Installing models"

# Function to download and verify a model archive
download_and_verify() {
  archive="$1"
  expected_sha256="$2"
  archive_label="$3"

  echo "Downloading $archive..."
  download_with_retry "$BASE_URL/$archive" "$DOWNLOAD_DIR/$archive" "$archive_label"
  echo "  Download complete. Checking SHA256..."

  emit_activity "verifying" "$archive" "$archive_label"
  actual=$(shasum -a 256 "$DOWNLOAD_DIR/$archive" | awk '{print $1}')
  if [ "$actual" != "$expected_sha256" ]; then
    echo "  ERROR: SHA256 mismatch for $archive"
    echo "    Expected: $expected_sha256"
    echo "    Actual:   $actual"
    emit_error "SHA256 mismatch for $archive"
    wait_and_exit 1
  fi
  echo "  SHA256 verified: $actual"
}

# Check if a model has been fully unzipped to the models directory.
# The zip files are named models--<model_id>.zip, so the extracted dir has a
# "models--" prefix. A completion marker file is written after extraction —
# a model directory without it is a leftover from an interrupted extraction.
model_completion_marker() {
  echo "$MODELS_DIR/.models--$1.installed"
}

model_installed() {
  model_id="$1"
  [ -d "$MODELS_DIR/models--$model_id" ] && [ -f "$(model_completion_marker "$model_id")" ]
}

# Download and install each model only if not already present in oMLX
install_model_if_needed() {
  zip_file="$1"
  sha256_sum="$2"
  model_id="$3"
  model_label="$4"

  if model_installed "$model_id"; then
    echo "  Model $model_id is already installed. Skipping."
    echo ""
    return 0
  fi

  echo "  Model $model_id is not installed. Proceeding..."
  echo ""
  download_and_verify "$zip_file" "$sha256_sum" "$model_label"
  echo "Extracting $zip_file to $MODELS_DIR..."
  emit_activity "extracting" "$zip_file" "$model_label"
  # Remove leftovers from a previously interrupted extraction
  rm -rf "$MODELS_DIR/models--$model_id"
  unzip -q "$DOWNLOAD_DIR/$zip_file" -d "$MODELS_DIR"
  touch "$(model_completion_marker "$model_id")"
  echo "  Extraction complete."
  echo ""
}

install_model_if_needed "$MODEL_ZIP_1" "$MODEL_SHA256_1" "$MODEL_ID_1" "$MODEL_LABEL_1"
install_model_if_needed "$MODEL_ZIP_2" "$MODEL_SHA256_2" "$MODEL_ID_2" "$MODEL_LABEL_2"

# Cleanup model downloads
echo "Removing downloaded archives..."
rm -rf "$DOWNLOAD_DIR"
emit_step_done "models"

# ============================================================
# Step 3: Configure oMLX
# ============================================================
echo "=== Configuring oMLX ==="
echo ""
emit_step_start "configure" "Configuring oMLX"
# These degrade gracefully with warnings; without `|| true` a return 1
# would abort the script under `set -e`.
configure_omlx_models_dir || true
configure_model_settings || true
configure_omlx_cache || true
restart_omlx || true
create_junie_model_config || true
set_default_junie_model || true
emit_step_done "configure"

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Models installed to: $MODELS_DIR"
echo "  oMLX SSD cache: $OMLX_SSD_CACHE_MAX"
echo "  oMLX hot cache: $OMLX_HOT_CACHE_MAX"
echo "  Model memory: ~17 GB"
echo "  Total oMLX memory: ${OMLX_MODEL_RAM_GB}GB"
echo ""
echo "  Default model set to $JUNIE_MODEL_ID."
echo "  Restart Junie to apply the changes."
emit_event "\"event\":\"done\",\"model_id\":\"$JUNIE_MODEL_ID\",\"port\":$PORT_CANDIDATE"
wait_and_exit 0
