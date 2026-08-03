#!/bin/sh
set -e

# Helper: wait for user to press any key, then exit
wait_and_exit() {
  echo ""
  echo "Press any key to exit..."
  # If read fails, still exit with the intended code (not read's status)
  read -r -n 1 || true
  exit "$1"
}

# --- junie-ui:begin ---
# Presentation layer: the Junie logo, section headers, checked values, and
# downloads/extractions with a progress bar. Everything degrades to plain lines
# when stdout is not a terminal, CI=true, or JUNIE_NO_ANIM=1, so piped and
# logged runs stay readable.

ESC=$(printf '\033')
CSI="${ESC}["
RESET="${CSI}0m"
BOLD="${CSI}1m"
HIDE_CURSOR="${CSI}?25l"
SHOW_CURSOR="${CSI}?25h"
CLEAR_RIGHT="${CSI}0K"

# Brand colors, same values the Junie CLI uses for its logo and progress.
JUNIE_GREEN="${CSI}38;2;72;224;84m"
JUNIE_GREEN_DIM="${CSI}38;2;36;110;42m"
JUNIE_GREEN_BRIGHT="${CSI}38;2;140;255;150m"
GRAY="${CSI}38;2;150;150;150m"
GRAY_DIM="${CSI}38;2;92;92;92m"
RED="${CSI}38;2;255;107;107m"
YELLOW="${CSI}38;2;255;199;89m"
GREEN="$JUNIE_GREEN"
NC="$RESET"

# Cursor moves and animations need a real terminal.
INTERACTIVE=true
if [ ! -t 1 ] || [ "${CI:-}" = "true" ] || [ "${JUNIE_NO_ANIM:-}" = "1" ]; then
  INTERACTIVE=false
fi
TERM_COLS=$(tput cols 2>/dev/null || echo 80)

show_cursor() {
  if [ "$INTERACTIVE" = true ]; then
    printf '%s' "$SHOW_CURSOR"
  fi
  return 0
}

# The Junie J and wordmark, character-for-character the same art as the CLI.
LOGO_ART='       ///////       |       ///////       |       ///////       |///////      /////// |///////      /////// |///////     //////// |       ///////////   |       /////////     |       //////        '
WORDMARK_ART='      ///                           ///              |      ///                           ///              |      ///  ///     ///  /////////         ///////    |      ///  ///     ///  //////////  ///  //////////  |      ///  ///     ///  ///     /// /// ///     //// |      ///  ///     ///  ///     /// /// //////////// |      ///  ///    ////  ///     /// /// ///          | ////////  //////////   ///     /// ///  /////////// | //////     ////////    ///     /// ///   ////////   '

# Prints the logo. On a terminal the '/' cells ripple through a wave of ASCII
# glyphs once (the CLI's one-shot logo animation, replayed at ~1.5s instead of
# 10s); elsewhere a single static frame is printed. The wordmark is dropped on
# narrow terminals, matching the CLI's 80-column cutoff.
junie_logo() {
  logo_wordmark="$WORDMARK_ART"
  if [ "$TERM_COLS" -lt 80 ]; then
    logo_wordmark=""
  fi
  logo_ticks=0
  if [ "$INTERACTIVE" = true ]; then
    logo_ticks=201
    printf '%s' "$HIDE_CURSOR"
  fi
  printf '\n'
  awk -v logo="$LOGO_ART" -v mark="$logo_wordmark" -v ticks="$logo_ticks" \
      -v green="$JUNIE_GREEN" -v reset="$RESET" -v bold="$BOLD" -v csi="$CSI" '
    function frame_char(x, y, tick,   pos, center, dist, env, wave, nw, idx) {
      if (tick == 0) return "/"
      pos = (x + y) * 0.3
      center = tick * 0.2 - 5.0
      dist = center - pos
      if (dist < 0) dist = -dist
      if (dist > 8.0) return "/"
      env = 1.0 - dist / 8.0
      wave = (sin(tick * 0.15 - pos) * 0.7 + sin(tick * 0.1 + (x - y) * 0.2) * 0.3) * env
      if (wave < 0.2) return "/"
      nw = (wave - 0.2) / 0.8
      idx = int(nw * (nchars - 1))
      if (idx < 1) idx = 1
      if (idx > nchars - 1) idx = nchars - 1
      return chars[idx + 1]
    }
    # Renders one line, swapping only the slashes so the art keeps its shape.
    function render(line, y, xoff, color,   out, i, c) {
      out = color
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        out = out (c == "/" ? frame_char(i + xoff, y, tick) : c)
      }
      return out reset
    }
    BEGIN {
      nchars = split("/,\\,|,-,_,(,),{,},[,],<,>,+,=,*,.,:,;,~,^", chars, ",")
      rows = split(logo, logoline, "|")
      if (mark != "") split(mark, markline, "|")
      for (tick = 0; tick <= ticks; tick += 3) {
        for (y = 1; y <= rows; y++) {
          out = "  " render(logoline[y], y - 1, 0, green bold)
          if (mark != "") {
            out = out "  " render(markline[y], y - 1, length(logoline[y]) + 2, bold)
          }
          print out
        }
        if (tick >= ticks) break
        fflush()
        system("sleep 0.02")
        printf "%s", csi rows "A"
      }
    }'
  show_cursor
  printf '\n'
  return 0
}

# A section heading with an underline as wide as its title.
section() {
  printf '\n  %s%s%s%s\n' "$JUNIE_GREEN" "$BOLD" "$1" "$RESET"
  awk -v n="${#1}" -v c="$GRAY_DIM" -v r="$RESET" \
    'BEGIN { s = ""; for (i = 0; i < n; i++) s = s "─"; print "  " c s r }'
  printf '\n'
  return 0
}

# Helper: print a value in green if ok, yellow if warning, red if not ok
print_value() {
  label="$1"
  value="$2"
  ok="$3"
  warn="$4"
  requirement="$5"
  if [ "$ok" = true ] && [ "$warn" = false ]; then
    printf "  %s%-20s%s ${GREEN}%s${NC}\n" "$GRAY" "$label" "$RESET" "$value"
  elif [ "$warn" = true ]; then
    printf "  %s%-20s%s ${YELLOW}%s${NC}  %s(%s)%s\n" "$GRAY" "$label" "$RESET" "$value" "$GRAY_DIM" "$requirement" "$RESET"
  else
    printf "  %s%-20s%s ${RED}%s${NC}  %s(requirement: %s)%s\n" "$GRAY" "$label" "$RESET" "$value" "$GRAY_DIM" "$requirement" "$RESET"
  fi
}

# Bytes as a human-readable size, e.g. 6.1 GB.
human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1f GB", b / 1073741824
    else if (b >= 1048576) printf "%.1f MB", b / 1048576
    else if (b >= 1024) printf "%.0f KB", b / 1024
    else printf "%d B", b
  }'
}

BAR_WIDTH=32
PROGRESS_DREW=false
PROGRESS_LOGGED=-1

# Draws the progress bar: one line, redrawn in place with a carriage return.
# It must never wrap — a wrapped line puts the cursor on a row the carriage
# return cannot reach, and every frame would then leave its own leftovers on
# screen — so the label, the ETA and the speed are dropped, in that order, until
# the line fits the terminal, and the bar itself shrinks if that is still not
# enough. Off a terminal the numbers are logged once per 10% instead.
# Usage: progress_render <have-bytes> <total-bytes|0> <bytes-per-second> <label>
progress_render() {
  if [ "$INTERACTIVE" != true ]; then
    if [ "$2" -gt 0 ]; then
      progress_step=$(( $1 * 10 / $2 ))
      if [ "$progress_step" -gt "$PROGRESS_LOGGED" ]; then
        PROGRESS_LOGGED=$progress_step
        printf '  %d%% (%s of %s)\n' "$(( progress_step * 10 ))" "$(human_bytes "$1")" "$(human_bytes "$2")"
      fi
    fi
    return 0
  fi
  PROGRESS_DREW=true

  awk -v have="$1" -v total="$2" -v bps="$3" -v label="$4" \
      -v width="$BAR_WIDTH" -v cols="$TERM_COLS" -v clr="$CLEAR_RIGHT" \
      -v green="$JUNIE_GREEN" -v dim="$JUNIE_GREEN_DIM" -v gray="$GRAY" \
      -v graydim="$GRAY_DIM" -v reset="$RESET" '
    function human(b) {
      if (b >= 1073741824) return sprintf("%.1f GB", b / 1073741824)
      if (b >= 1048576) return sprintf("%.1f MB", b / 1048576)
      if (b >= 1024) return sprintf("%.0f KB", b / 1024)
      return sprintf("%d B", b)
    }
    BEGIN {
      ratio = total > 0 ? have / total : 0
      if (ratio > 1) ratio = 1

      # Every field is padded to a width that does not depend on the current
      # value, so the numbers do not shift as they grow and the fitting decision
      # below lands the same way on every frame. Deciding from the raw values
      # would make the ETA blink in and out whenever a size gained a digit.
      size_w = length(human(total))
      if (size_w < 9) size_w = 9
      pct_s = total > 0 ? sprintf("%3d%%", int(ratio * 100)) : ""
      size_s = total > 0 ? sprintf("%*s of %s", size_w, human(have), human(total)) \
                         : sprintf("%*s", size_w, human(have))
      speed_s = bps > 0 ? sprintf("%9s/s", human(bps)) : sprintf("%11s", "")
      if (bps > 0 && total > have) {
        eta_secs = int((total - have) / bps)
        eta_s = sprintf("eta %3d:%02d", eta_secs / 60, eta_secs % 60)
      } else {
        eta_s = sprintf("%9s", "")
      }

      # Two leading spaces, the bar, two spaces, then as many fields as fit on
      # the line. The label is dropped first, then the ETA, then the speed, and
      # the bar shrinks if even that is not enough.
      stats = pct_s (pct_s == "" ? "" : "  ") size_s
      show_speed = 1
      show_eta = total > 0
      while (1) {
        tail = show_speed ? "  " speed_s : ""
        if (show_eta) tail = tail "  " eta_s
        if (2 + width + 2 + length(stats tail) + (label != "" ? 2 + length(label) : 0) <= cols - 1) break
        if (label != "") { label = ""; continue }
        if (show_eta) { show_eta = 0; continue }
        if (show_speed) { show_speed = 0; continue }
        break
      }
      stats = stats tail
      room = cols - 1 - (2 + 2 + length(stats))
      if (room < width) width = room > 8 ? room : 8

      filled = int(ratio * width + 0.5)
      bar = ""; for (i = 0; i < filled; i++) bar = bar "█"
      rest = ""; for (i = filled; i < width; i++) rest = rest "░"

      printf "\r  %s%s%s%s  %s%s%s%s%s", green, bar, dim, rest, gray, stats, \
             (label != "" ? graydim "  " label : ""), reset, clr
      fflush()
    }'
  return 0
}

# Closes the progress line and gives the cursor back.
progress_end() {
  if [ "$PROGRESS_DREW" = true ] && [ "$INTERACTIVE" = true ]; then
    printf '\n'
  fi
  PROGRESS_DREW=false
  PROGRESS_LOGGED=-1
  show_cursor
  return 0
}

# Size of a local file in bytes, 0 when it does not exist yet.
file_size() {
  if [ ! -f "$1" ]; then
    echo 0
    return 0
  fi
  wc -c < "$1" | tr -d ' '
}

# Asks the server for the size of a file and whether it accepts ranged GETs,
# which is what makes an interrupted download resumable. Sets REMOTE_SIZE (empty
# when unknown) and REMOTE_RANGES.
probe_remote() {
  REMOTE_SIZE=""
  REMOTE_RANGES=false

  probe_headers=$(curl -sIL --max-time 30 "$1" 2>/dev/null | tr -d '\r') || probe_headers=""
  # Redirects mean several header blocks. Only the last one describes the file,
  # and only if it succeeded: an error page has a Content-Length too.
  # The size is only accepted as a plain number: everything downstream does
  # arithmetic on it, and `set -e` would kill the installer over a header a proxy
  # decided to reword.
  REMOTE_SIZE=$(printf '%s\n' "$probe_headers" | awk '
    /^[Hh][Tt][Tt][Pp]\// { status = $2; next }
    tolower($1) == "content-length:" { len = $2 }
    END { if (status ~ /^2/ && len ~ /^[0-9]+$/) print len }')
  if printf '%s\n' "$probe_headers" | awk '
    /^[Hh][Tt][Tt][Pp]\// { status = $2; ranges = 0; next }
    tolower($1) == "accept-ranges:" { ranges = (tolower($2) == "bytes") }
    END { exit(status ~ /^2/ && ranges ? 0 : 1) }'; then
    REMOTE_RANGES=true
  fi

  # Some CDNs answer HEAD without a size; a one-byte ranged GET settles both
  # questions at once, because only a 206 carries Content-Range.
  if [ -z "$REMOTE_SIZE" ]; then
    probe_headers=$(curl -sL --max-time 30 -r 0-0 -D - -o /dev/null "$1" 2>/dev/null | tr -d '\r') || probe_headers=""
    REMOTE_SIZE=$(printf '%s\n' "$probe_headers" | awk '
      /^[Hh][Tt][Tt][Pp]\// { status = $2; next }
      tolower($1) == "content-range:" { split($2, a, "/"); if (a[2] != "") total = a[2] }
      END { if (status == "206" && total ~ /^[0-9]+$/) print total }')
    if [ -n "$REMOTE_SIZE" ]; then
      REMOTE_RANGES=true
    fi
  fi
  return 0
}

CURL_PID=""
CURL_ERR_FILE=""

# Downloads <url> into <file> with a progress bar, continuing an interrupted
# transfer instead of starting over: curl runs with -C -, the partial file is
# kept on Ctrl-C and on network errors, and the next attempt picks up at its
# current size. A file that already has the remote size is left alone, so a
# re-run after a completed download costs one HEAD request.
# Usage: download_with_progress <url> <file> [label]
download_with_progress() {
  dl_url="$1"
  dl_out="$2"
  dl_label="${3:-}"

  probe_remote "$dl_url"
  dl_total="${REMOTE_SIZE:-0}"
  dl_have=$(file_size "$dl_out")

  if [ "$dl_total" -gt 0 ] && [ "$dl_have" -eq "$dl_total" ]; then
    printf '  %sAlready downloaded%s (%s)\n' "$JUNIE_GREEN" "$RESET" "$(human_bytes "$dl_total")"
    return 0
  fi
  if [ "$dl_total" -gt 0 ] && [ "$dl_have" -gt "$dl_total" ]; then
    printf '  %sLocal file is bigger than the remote one — starting over.%s\n' "$YELLOW" "$RESET"
    rm -f "$dl_out"
    dl_have=0
  fi
  if [ "$dl_have" -gt 0 ] && [ "$REMOTE_RANGES" != true ]; then
    printf '  %sServer will not resume this file — downloading it again.%s\n' "$YELLOW" "$RESET"
    rm -f "$dl_out"
    dl_have=0
  fi
  if [ "$dl_have" -gt 0 ]; then
    printf '  %sResuming at %s%s\n' "$GRAY" "$(human_bytes "$dl_have")" "$RESET"
  fi

  # Re-measure the terminal: it may have been resized since the last step, and
  # the bar sizes itself to fit.
  TERM_COLS=$(tput cols 2>/dev/null || echo 80)
  if [ "$INTERACTIVE" = true ]; then
    printf '%s' "$HIDE_CURSOR"
  fi

  # curl keeps stderr for the failure message: it would otherwise land in the
  # middle of the bar. The path is global so the interrupt trap can remove it.
  CURL_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/junie-curl.XXXXXX")
  dl_err="$CURL_ERR_FILE"
  curl --fail --silent --show-error --location -C - -o "$dl_out" "$dl_url" 2>"$dl_err" &
  CURL_PID=$!

  dl_prev_bytes=$dl_have
  dl_prev_time=$(date +%s)
  dl_bps=0
  while kill -0 "$CURL_PID" 2>/dev/null; do
    dl_now_bytes=$(file_size "$dl_out")
    dl_now_time=$(date +%s)
    if [ "$dl_now_time" -gt "$dl_prev_time" ]; then
      dl_bps=$(( (dl_now_bytes - dl_prev_bytes) / (dl_now_time - dl_prev_time) ))
      dl_prev_bytes=$dl_now_bytes
      dl_prev_time=$dl_now_time
    fi
    progress_render "$dl_now_bytes" "$dl_total" "$dl_bps" "$dl_label"
    sleep 0.2
  done

  dl_rc=0
  wait "$CURL_PID" || dl_rc=$?
  CURL_PID=""
  # One last frame so the bar lands on the final size — but only on success: a
  # failed download should not leave a bar behind at all.
  if [ "$dl_rc" -eq 0 ]; then
    progress_render "$(file_size "$dl_out")" "$dl_total" "$dl_bps" "$dl_label"
  fi
  progress_end

  # Exit 33/36 mean the server refused our resume offset. With no known size we
  # cannot tell a finished file from a broken one, so let the checksum decide.
  if [ "$dl_rc" -eq 33 ] || [ "$dl_rc" -eq 36 ]; then
    if [ "$dl_total" -eq 0 ]; then
      printf '  %sServer rejected the resume offset; verifying what we have.%s\n' "$YELLOW" "$RESET"
      rm -f "$dl_err"
      CURL_ERR_FILE=""
      return 0
    fi
  fi
  if [ "$dl_rc" -ne 0 ]; then
    if [ -s "$dl_err" ]; then
      printf '  %s%s%s\n' "$RED" "$(head -n 2 "$dl_err" | tr -d '\r')" "$RESET"
    fi
    rm -f "$dl_err"
    CURL_ERR_FILE=""
    return "$dl_rc"
  fi
  rm -f "$dl_err"
  CURL_ERR_FILE=""
  return 0
}

# Function to download a file with retry logic and exponential backoff.
# Every attempt resumes from the bytes already on disk, so a dropped connection
# costs the retry, not the download. An attempt that made progress resets the
# backoff, because a flaky link that keeps moving forward is worth staying on.
# Usage: download_with_retry <url> <output_file> [max_retries] [label]
download_with_retry() {
  url="$1"
  output_file="$2"
  max_retries="${3:-3}"
  label="${4:-}"
  attempt=1
  delay=2

  while [ "$attempt" -le "$max_retries" ]; do
    if [ "$attempt" -gt 1 ]; then
      printf '  %sAttempt %d of %d%s\n' "$GRAY_DIM" "$attempt" "$max_retries" "$RESET"
    fi
    before=$(file_size "$output_file")
    if download_with_progress "$url" "$output_file" "$label"; then
      return 0
    fi
    after=$(file_size "$output_file")

    if [ "$attempt" -lt "$max_retries" ]; then
      if [ "$after" -gt "$before" ]; then
        delay=2
      fi
      if [ "$after" -gt 0 ]; then
        printf '  %sDownload stopped at %s. Resuming in %ds...%s\n' \
          "$YELLOW" "$(human_bytes "$after")" "$delay" "$RESET"
      else
        printf '  %sDownload failed. Retrying in %ds...%s\n' "$YELLOW" "$delay" "$RESET"
      fi
      sleep "$delay"
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done

  printf '  %sERROR: Download failed after %d attempts.%s\n' "$RED" "$max_retries" "$RESET"
  if [ "$(file_size "$output_file")" -gt 0 ]; then
    printf '  %sThe partial file is kept — re-run this script to resume.%s\n' "$GRAY" "$RESET"
  fi
  return 1
}

UNZIP_PID=""

# Unzips <archive> into <dest> with a progress bar driven by the size of
# <watch-dir>, the directory the archive creates. Falls back to a plain quiet
# unzip when the uncompressed size is unavailable.
# Usage: extract_with_progress <archive> <dest> <watch-dir> [label]
extract_with_progress() {
  ex_zip="$1"
  ex_dest="$2"
  ex_watch="$3"
  ex_label="${4:-}"

  ex_total=$(unzip -Zt "$ex_zip" 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "bytes") { print $(i - 1); exit } }')
  if [ -z "$ex_total" ] || [ "$INTERACTIVE" != true ]; then
    unzip -q -o "$ex_zip" -d "$ex_dest"
    return 0
  fi

  TERM_COLS=$(tput cols 2>/dev/null || echo 80)
  printf '%s' "$HIDE_CURSOR"
  unzip -q -o "$ex_zip" -d "$ex_dest" &
  UNZIP_PID=$!
  ex_prev_bytes=0
  ex_prev_time=$(date +%s)
  ex_bps=0
  while kill -0 "$UNZIP_PID" 2>/dev/null; do
    ex_now_bytes=$(du -sk "$ex_watch" 2>/dev/null | awk '{ print $1 * 1024 }')
    ex_now_bytes=${ex_now_bytes:-0}
    ex_now_time=$(date +%s)
    if [ "$ex_now_time" -gt "$ex_prev_time" ]; then
      ex_bps=$(( (ex_now_bytes - ex_prev_bytes) / (ex_now_time - ex_prev_time) ))
      ex_prev_bytes=$ex_now_bytes
      ex_prev_time=$ex_now_time
    fi
    progress_render "$ex_now_bytes" "$ex_total" "$ex_bps" "$ex_label"
    sleep 0.5
  done

  ex_rc=0
  wait "$UNZIP_PID" || ex_rc=$?
  UNZIP_PID=""
  if [ "$ex_rc" -eq 0 ]; then
    progress_render "$ex_total" "$ex_total" "$ex_bps" "$ex_label"
  fi
  progress_end
  return "$ex_rc"
}

# Types a line out character by character. The line is peeled one character at a
# time with parameter expansion rather than indexed with a substring, which is a
# bash extension.
type_line() {
  if [ "$INTERACTIVE" != true ]; then
    printf '  %s\n' "$1"
    return 0
  fi
  printf '  %s' "${2:-$GRAY}"
  type_rest="$1"
  while [ -n "$type_rest" ]; do
    type_tail="${type_rest#?}"
    printf '%s' "${type_rest%"$type_tail"}"
    type_rest="$type_tail"
    sleep 0.012
  done
  printf '%s\n' "$RESET"
  return 0
}

# Reprints the J and pulses it, as the finishing beat of the install.
junie_pulse() {
  logo_rows=$(awk -v logo="$LOGO_ART" 'BEGIN { print split(logo, l, "|") }')
  printf '\n'
  awk -v logo="$LOGO_ART" -v green="$JUNIE_GREEN" -v bold="$BOLD" -v reset="$RESET" \
    'BEGIN { rows = split(logo, l, "|"); for (y = 1; y <= rows; y++) print "  " green bold l[y] reset }'
  if [ "$INTERACTIVE" != true ]; then
    printf '\n'
    return 0
  fi
  printf '%s' "$HIDE_CURSOR"
  pulse_i=0
  while [ "$pulse_i" -lt 5 ]; do
    for pulse_color in "$JUNIE_GREEN_BRIGHT" "$JUNIE_GREEN"; do
      printf '%s' "${CSI}${logo_rows}A"
      awk -v logo="$LOGO_ART" -v color="$pulse_color" -v bold="$BOLD" -v reset="$RESET" \
        'BEGIN { rows = split(logo, l, "|"); for (y = 1; y <= rows; y++) print "  " color bold l[y] reset }'
      sleep 0.06
    done
    pulse_i=$(( pulse_i + 1 ))
  done
  show_cursor
  printf '\n'
  return 0
}
# --- junie-ui:end ---

# The logo and the prompts run before the download traps below are installed, and
# they hide the cursor. Restore it if the user quits during that window; the
# cleanup trap replaces this one once there are downloads to protect.
trap 'show_cursor; echo ""; exit 130' INT
trap 'show_cursor; echo ""; exit 143' TERM

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
    wait_and_exit 1
  fi
fi

# ============================================================
# System info summary: evaluate & display
# ============================================================
junie_logo
type_line "Local model installer" "$GRAY"
section "System information"

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

# RAM allowance for inference (weights + KV cache)
OMLX_MODEL_RAM_GB="${1:-35}"
if ! is_valid_ram "$OMLX_MODEL_RAM_GB"; then
  printf "  ${RED}ERROR:${NC} RAM allowance must be a whole number of at least 18 GB (got: %s)\n" "$OMLX_MODEL_RAM_GB"
  wait_and_exit 1
fi

# oMLX status — in System Information if installed, in Install Configuration if not
# An installed oMLX older than the minimum version is a hard failure:
# the user must update it manually before re-running the installer.
if [ "$OMLX_INSTALLED" = true ]; then
  if [ "$OMLX_NEEDS_UPDATE" = true ]; then
    ALL_OK=false
    print_value "oMLX:" "v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}" false false "v${OMLX_MIN_VERSION} or higher — please update oMLX manually and re-run"
  else
    print_value "oMLX:" "v${OMLX_EXISTING_VERSION} on port ${OMLX_EXISTING_PORT}" true false ""
  fi
fi

# Install Configuration section
section "Install configuration"

if [ "$OMLX_INSTALLED" = false ]; then
  print_value "oMLX:" "not installed" true true "This script will install version v${OMLX_TARGET_VERSION} on port ${PORT_CANDIDATE}"
fi
print_value "RAM allowance:" "${OMLX_MODEL_RAM_GB} GB" true false ""
if [ "$OMLX_INSTALLED" = true ]; then
  echo ""
  printf '  %sNote: existing oMLX cache settings will be updated to match the RAM allowance.%s\n' "$GRAY_DIM" "$RESET"
fi
echo ""

# ============================================================
# Decision: proceed or exit
# ============================================================
if [ "$ALL_OK" = false ]; then
  printf '  %sSome system requirements are not met. Installation cannot proceed.%s\n' "$RED" "$RESET"
  wait_and_exit 1
fi

# All hard requirements met — ask user to confirm
printf '  %sDo you want to continue with these settings?%s %s[Y/n]%s ' "$BOLD" "$RESET" "$GRAY_DIM" "$RESET"
read -r CONTINUE_ANSWER
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

# Model archives, their SHA256 checksums, and corresponding oMLX model IDs
MODEL_ZIP_1="models--mlx-community--Qwen3.6-27B-4bit.zip"
MODEL_SHA256_1="adf7f8d832ed994dcc6d09372036b4d12f49a4ccda066179cc64dc2dd113f91d"
MODEL_ID_1="mlx-community--Qwen3.6-27B-4bit"
MODEL_ZIP_2="models--mlx-community--Qwen3.6-27B-MTP-4bit.zip"
MODEL_SHA256_2="9266c1ba244ec6176fc82474bbfd20614969eb28c4cfa24301e515fbd1f5a525"
MODEL_ID_2="mlx-community--Qwen3.6-27B-MTP-4bit"

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

  # Close the progress bar and give the cursor back before printing anything.
  progress_end
  if [ -n "$CURL_ERR_FILE" ]; then
    rm -f "$CURL_ERR_FILE"
  fi

  echo ""
  if [ -d "$DOWNLOAD_DIR" ]; then
    printf '  %sInterrupted — partial downloads preserved in %s%s\n' "$YELLOW" "$DOWNLOAD_DIR" "$RESET"
    printf '  %sRe-run this script to resume from where it stopped.%s\n' "$GRAY" "$RESET"
  else
    printf '  %sInterrupted.%s\n' "$YELLOW" "$RESET"
  fi

  # curl and unzip are killed, not their partial output: the bytes already on
  # disk are what the next run resumes from.
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
  JUNIE_CONFIG_FILE="$JUNIE_MODELS_DIR/${JUNIE_MODEL_ID}.json"
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

# Function to set the local model as the default in Junie settings
set_default_junie_model() {
  JUNIE_SETTINGS="$HOME/.junie/settings.json"

  if [ ! -f "$JUNIE_SETTINGS" ]; then
    echo "  WARNING: Junie settings not found at $JUNIE_SETTINGS"
    echo "  Skipping default model configuration."
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
section "Setting up oMLX"

install_omlx() {
  # Download oMLX DMG
  echo "  Downloading $OMLX_FILE..."
  download_with_retry "$OMLX_URL" "$DOWNLOAD_DIR/$OMLX_FILE" 3 "oMLX"

  # Verify SHA256 checksum
  actual_sha256=$(shasum -a 256 "$DOWNLOAD_DIR/$OMLX_FILE" | awk '{print $1}')
  if [ "$actual_sha256" != "$OMLX_SHA256" ]; then
    printf '  %sERROR: SHA256 mismatch for %s%s\n' "$RED" "$OMLX_FILE" "$RESET"
    echo "    Expected: $OMLX_SHA256"
    echo "    Actual:   $actual_sha256"
    # A resumed download that ends up corrupt would keep failing this check
    # forever, so drop the file and let the next run fetch it again.
    rm -f "$DOWNLOAD_DIR/$OMLX_FILE"
    printf '  %sThe damaged file was removed — re-run this script to download it again.%s\n' "$GRAY" "$RESET"
    wait_and_exit 1
  fi
  printf '  %sSHA256 verified%s %s%s%s\n' "$JUNIE_GREEN" "$RESET" "$GRAY_DIM" "$actual_sha256" "$RESET"

  # Mount DMG to a temporary location
  MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omlx-install.XXXXXX")
  echo "  Mounting oMLX DMG..."
  hdiutil attach "$DOWNLOAD_DIR/$OMLX_FILE" -nobrowse -readonly -mountpoint "$MOUNT_DIR" > /dev/null

  SOURCE="$MOUNT_DIR/oMLX.app"
  DESTINATION="$OMLX_INSTALL_DIR/oMLX.app"

  if [ ! -d "$SOURCE" ]; then
    echo "  ERROR: oMLX.app not found inside DMG."
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

# ============================================================
# Step 2: Download and install models
# ============================================================
section "Installing models"

# Function to download and verify a model archive
download_and_verify() {
  archive="$1"
  expected_sha256="$2"
  model_label="$3"

  echo "  Downloading $archive..."
  download_with_retry "$BASE_URL/$archive" "$DOWNLOAD_DIR/$archive" 3 "$model_label"
  printf '  %sChecking SHA256...%s\n' "$GRAY" "$RESET"

  actual=$(shasum -a 256 "$DOWNLOAD_DIR/$archive" | awk '{print $1}')
  if [ "$actual" != "$expected_sha256" ]; then
    printf '  %sERROR: SHA256 mismatch for %s%s\n' "$RED" "$archive" "$RESET"
    echo "    Expected: $expected_sha256"
    echo "    Actual:   $actual"
    # Keeping a corrupt archive would make every later run resume into the same
    # mismatch, so it is dropped and re-downloaded from scratch next time.
    rm -f "$DOWNLOAD_DIR/$archive"
    printf '  %sThe damaged archive was removed — re-run this script to download it again.%s\n' "$GRAY" "$RESET"
    wait_and_exit 1
  fi
  printf '  %sSHA256 verified%s %s%s%s\n' "$JUNIE_GREEN" "$RESET" "$GRAY_DIM" "$actual" "$RESET"
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

  if model_installed "$model_id"; then
    printf '  %sModel %s is already installed. Skipping.%s\n\n' "$GRAY" "$model_id" "$RESET"
    return 0
  fi

  printf '  %sModel %s is not installed. Proceeding...%s\n\n' "$GRAY" "$model_id" "$RESET"
  download_and_verify "$zip_file" "$sha256_sum" "$model_id"
  echo "  Extracting $zip_file..."
  # Remove leftovers from a previously interrupted extraction
  rm -rf "$MODELS_DIR/models--$model_id"
  extract_with_progress "$DOWNLOAD_DIR/$zip_file" "$MODELS_DIR" "$MODELS_DIR/models--$model_id" "$model_id"
  touch "$(model_completion_marker "$model_id")"
  printf '  %sExtraction complete.%s\n\n' "$JUNIE_GREEN" "$RESET"
}

install_model_if_needed "$MODEL_ZIP_1" "$MODEL_SHA256_1" "$MODEL_ID_1"
install_model_if_needed "$MODEL_ZIP_2" "$MODEL_SHA256_2" "$MODEL_ID_2"

# Cleanup model downloads
printf '  %sRemoving downloaded archives...%s\n' "$GRAY" "$RESET"
rm -rf "$DOWNLOAD_DIR"

# ============================================================
# Step 3: Configure oMLX
# ============================================================
section "Configuring oMLX"
configure_omlx_models_dir
configure_model_settings
configure_omlx_cache
restart_omlx
create_junie_model_config
set_default_junie_model

junie_pulse
type_line "Local model installed." "$JUNIE_GREEN$BOLD"
echo ""
print_value "Models:" "$MODELS_DIR" true false ""
print_value "oMLX SSD cache:" "$OMLX_SSD_CACHE_MAX" true false ""
print_value "oMLX hot cache:" "$OMLX_HOT_CACHE_MAX" true false ""
print_value "Model memory:" "~17 GB" true false ""
print_value "Total oMLX memory:" "${OMLX_MODEL_RAM_GB} GB" true false ""
print_value "Default model:" "$JUNIE_MODEL_ID" true false ""
echo ""
type_line "Restart Junie to apply the changes." "$GRAY"
wait_and_exit 0
