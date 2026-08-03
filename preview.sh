#!/bin/sh
# Preview for the junie-local installer UI.
#
# The presentation code is not duplicated here: it is extracted out of
# install.sh between the junie-ui markers and sourced, so whatever you see is
# the code that would ship. Nothing is installed, no oMLX settings are touched,
# and downloads (in --real modes) go to a preview cache directory.
#
#   ./preview.sh                 screens and animations only, no network
#   ./preview.sh --real          real resumable download of the model archive
#   ./preview.sh --resume-demo   pre-seed a partial file, then show it resuming
#   JUNIE_NO_ANIM=1 ./preview.sh how it degrades in a pipe or in CI
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL_SH="$HERE/install.sh"

if [ ! -f "$INSTALL_SH" ]; then
  echo "install.sh not found next to this script" >&2
  exit 1
fi

UI_FILE=$(mktemp "${TMPDIR:-/tmp}/junie-ui.XXXXXX")
sed -n '/^# --- junie-ui:begin ---$/,/^# --- junie-ui:end ---$/p' "$INSTALL_SH" > "$UI_FILE"
if [ ! -s "$UI_FILE" ]; then
  echo "no junie-ui block found in $INSTALL_SH" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$UI_FILE"
rm -f "$UI_FILE"

MODEL_URL="https://download.jetbrains.com/resources/junie-local/models--mlx-community--Qwen3.6-27B-4bit.zip"
CACHE_DIR="${JUNIE_PREVIEW_DIR:-$HOME/.cache/junie-local-preview}"
# Roughly what the real archives weigh, so the numbers on screen look right.
MODEL_BYTES=16081501198
SEED_BYTES=${JUNIE_PREVIEW_SEED:-157286400}

preview_cleanup() {
  trap - INT TERM
  progress_end
  printf '\n  %sPreview stopped.%s\n' "$YELLOW" "$RESET"
  if [ -f "$CACHE_DIR/model.zip" ]; then
    printf '  %sPartial file kept: %s (%s)%s\n' "$GRAY" "$CACHE_DIR/model.zip" \
      "$(human_bytes "$(file_size "$CACHE_DIR/model.zip")")" "$RESET"
    printf '  %sRun the same command again to watch it resume.%s\n' "$GRAY" "$RESET"
  fi
  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true
  exit 130
}
trap preview_cleanup INT
trap preview_cleanup TERM

# Replays the bar without a network transfer. `start` lets the scene begin
# mid-file, the way a resumed download does.
fake_progress() {
  fp_total=$1
  fp_label=$2
  fp_seconds=${3:-4}
  fp_start=${4:-0}
  fp_frames=$(( fp_seconds * 5 ))
  fp_step=$(( (fp_total - fp_start) / fp_frames ))
  fp_i=0
  while [ "$fp_i" -le "$fp_frames" ]; do
    progress_render "$(( fp_start + fp_step * fp_i ))" "$fp_total" "$(( fp_step * 5 ))" "$fp_label"
    sleep 0.2
    fp_i=$(( fp_i + 1 ))
  done
  progress_render "$fp_total" "$fp_total" "$(( fp_step * 5 ))" "$fp_label"
  progress_end
}

# The header and both value tables, filled in with this machine's real numbers
# so the layout is judged against realistic content.
scene_screens() {
  junie_logo
  type_line "Local model installer" "$GRAY"

  section "System information"
  os_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
  mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  print_value "OS:" "Darwin $os_version" true false "macOS 26 or higher"
  print_value "CPU:" "$cpu_model" true false "M4 or M5 recommended"
  print_value "RAM:" "${mem_gb} GB" true false "minimum 40 GB, 60 GB recommended"

  section "Install configuration"
  print_value "oMLX:" "not installed" true true "This script will install version v0.5.3 on port 8000"
  print_value "RAM allowance:" "35 GB" true false ""
  echo ""
  printf '  %sDo you want to continue with these settings?%s %s[Y/n]%s ' "$BOLD" "$RESET" "$GRAY_DIM" "$RESET"
  read -r answer || answer=Y
  case "$answer" in
    [nN]|[nN][oO])
      printf '\n  %sThat branch asks for a port and a RAM allowance — unchanged by this patch.%s\n' "$GRAY" "$RESET"
      ;;
  esac
}

scene_fake_download() {
  section "Installing models"
  echo "  Downloading models--mlx-community--Qwen3.6-27B-4bit.zip..."
  fake_progress "$MODEL_BYTES" "Qwen3.6-27B-4bit" 5
  printf '  %sSHA256 verified%s %sadf7f8d832ed994dcc6d09372036b4d12f49a4ccda066179cc64dc2dd113f91d%s\n' \
    "$JUNIE_GREEN" "$RESET" "$GRAY_DIM" "$RESET"
  echo "  Extracting models--mlx-community--Qwen3.6-27B-4bit.zip..."
  fake_progress "$MODEL_BYTES" "unpacking" 3
  printf '  %sExtraction complete.%s\n' "$JUNIE_GREEN" "$RESET"
}

# What a run looks like after a dropped connection: the same lines the real
# download_with_progress prints when it finds bytes already on disk.
scene_fake_resume() {
  section "Resuming an interrupted download"
  echo "  Downloading models--mlx-community--Qwen3.6-27B-4bit.zip..."
  printf '  %sResuming at %s%s\n' "$GRAY" "$(human_bytes 6871947673)" "$RESET"
  fake_progress "$MODEL_BYTES" "Qwen3.6-27B-4bit" 4 6871947673
  printf '  %sSHA256 verified%s\n' "$JUNIE_GREEN" "$RESET"
}

scene_finale() {
  section "Installation complete"
  junie_pulse
  type_line "Local model installed." "$JUNIE_GREEN$BOLD"
  echo ""
  print_value "Models:" "$HOME/.local/share/junie-local/models" true false ""
  print_value "Default model:" "local-qwen3.6-27b-4bit" true false ""
  echo ""
  type_line "Restart Junie to apply the changes." "$GRAY"
  echo ""
}

# Downloads the real archive with the real function. Interrupt it whenever you
# like: the bytes stay in the cache directory and the next run continues.
scene_real_download() {
  mkdir -p "$CACHE_DIR"
  junie_logo
  section "Real download — Ctrl-C any time, then run this again"
  printf '  %sCache: %s%s\n' "$GRAY_DIM" "$CACHE_DIR" "$RESET"
  echo ""
  if [ "$1" = "seed" ] && [ "$(file_size "$CACHE_DIR/model.zip")" -eq 0 ]; then
    printf '  %sPre-seeding %s so there is something to resume from...%s\n' \
      "$GRAY" "$(human_bytes "$SEED_BYTES")" "$RESET"
    curl -sSL -r "0-$(( SEED_BYTES - 1 ))" -o "$CACHE_DIR/model.zip" "$MODEL_URL"
    printf '  %sDone — now the same URL is downloaded again, and it should pick up from there.%s\n\n' \
      "$GRAY" "$RESET"
  fi
  echo "  Downloading models--mlx-community--Qwen3.6-27B-4bit.zip..."
  download_with_retry "$MODEL_URL" "$CACHE_DIR/model.zip" 3 "Qwen3.6-27B-4bit"
  printf '  %sDownload complete: %s%s\n' "$JUNIE_GREEN" "$(human_bytes "$(file_size "$CACHE_DIR/model.zip")")" "$RESET"
}

case "${1:-}" in
  --real)
    scene_real_download nothing
    ;;
  --resume-demo)
    scene_real_download seed
    ;;
  -h|--help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  "")
    scene_screens
    scene_fake_download
    scene_fake_resume
    scene_finale
    ;;
  *)
    echo "unknown option: $1 (try --help)" >&2
    exit 64
    ;;
esac
