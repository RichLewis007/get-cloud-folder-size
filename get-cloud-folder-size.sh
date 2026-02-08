#!/usr/bin/env bash
# get-cloud-folder-size.sh
#
# Version: 1.10
# Date: 2026-02-08
# Author: Rich Lewis - GitHub: @RichLewis007
#
# Summary: Interactive rclone folder size checker with TUI menus.
#
# Purpose:
# - Browse rclone remotes and measure top-level folder sizes.
# - Cache size results locally for quick re-display.
#
# Usage:
# - ./get-cloud-folder-size.sh
# - RCLONE_SIZE_ARGS="--fast-list" ./get-cloud-folder-size.sh
# - ./get-cloud-folder-size.sh --fast-list
# - ./get-cloud-folder-size.sh --no-fast-list
# - ./get-cloud-folder-size.sh --help
# - ./get-cloud-folder-size.sh -- --tpslimit 10
#
# Inputs:
# - rclone remotes from `rclone listremotes`
# - top-level folders from `rclone lsf -d --max-depth 1 <remote>:`
#
# Outputs:
# - Terminal TUI + live progress (Listed N,NNN / Elapsed time)
# - Cache file with folder sizes (bytes)
# - History log in Markdown (get-cloud-folder-size-history.md)
#
# Config (env vars):
# - SIZE_DATA_FILE: cache file (default: ./get-cloud-folder-size-data.txt)
# - HISTORY_FILE: history log file (default: ./get-cloud-folder-size-history.md)
# - RCLONE_SIZE_ARGS: extra args appended to `rclone size`
# - FAST_LIST_MODE: auto|on|off (default: auto)
# - DEBUG_UI_NO_FZF: force-disable fzf UI (default: unset)
# - DEBUG_UI_NO_GUM: force-disable gum UI (default: unset)
#
# Dependencies:
# - rclone (required)
# - fzf or gum (optional; falls back to bash select)
#
# Safety:
# - Read-only: uses `rclone size` and `rclone lsf` only.
#
# Notes:
# - Live updates use --stats 1s for smoother progress.
# - Google Drive defaults to --fast-list in auto mode.
# - OneDrive uses --onedrive-delta only when --fast-list is enabled.
# - Unknown args are passed through to rclone size; use -- to force pass-through.
# - History log captures terminal output after folder selection.

EXTRA_RCLONE_ARGS=()
HISTORY_ACTIVE="0"
HISTORY_WARNED="0"
HISTORY_ENTRY_FILE=""
MENU_COLOR="${MENU_COLOR:-1}"
# - rclone size works by listing objects and summing sizes.
# --fast-list changes how rclone lists directories (including for rclone size). When a backend supports ListR, it can reduce API calls and speed up deep listings.
# 
#
# -----------------------------------------------------------------------------
#
# set -euo pipefail

###############################################################################
# UI Functions (self-contained, no external dependencies)
###############################################################################

# Color constants
COLOR_RESET=$'\033[0m'
COLOR_BOLD=$'\033[1m'
COLOR_ACCENT=$'\033[36m'
COLOR_BLUE=$'\033[34m'
COLOR_LABEL="${COLOR_BOLD}${COLOR_ACCENT}"
COLOR_MENU_LABEL="${COLOR_BOLD}"

# Logging functions
log_info() {
  local msg="ℹ  $*"
  echo "$msg" >&2
  if [[ "$HISTORY_ACTIVE" == "1" ]]; then
    history_write_line "$msg"
  fi
}

log_error() {
  local msg="✗ ERROR: $*"
  echo "$msg" >&2
  if [[ "$HISTORY_ACTIVE" == "1" ]]; then
    history_write_line "$msg"
  fi
}

log_warn() {
  local msg="⚠  WARNING: $*"
  echo "$msg" >&2
  if [[ "$HISTORY_ACTIVE" == "1" ]]; then
    history_write_line "$msg"
  fi
}

log_ok() {
  local msg="✓ $*"
  echo "$msg" >&2
  if [[ "$HISTORY_ACTIVE" == "1" ]]; then
    history_write_line "$msg"
  fi
}

# Pick option - interactive menu selection with fzf/gum/basic fallback
pick_option() {
  local prompt="$1"
  shift
  local items=("$@")

  if [[ ${#items[@]} -eq 0 ]]; then
    return 1
  fi

  # Split into header and prompt_line on first newline
  local header prompt_line
  header="${prompt%%$'\n'*}"
  if [[ "$prompt" == *$'\n'* ]]; then
    prompt_line="${prompt#*$'\n'}"
    # Remove any remaining newlines from prompt_line (keep only first line after header)
    prompt_line="${prompt_line%%$'\n'*}"
  else
    prompt_line="$prompt"
  fi

  local has_fzf="0"
  local has_gum="0"
  if [[ "${DEBUG_UI_NO_FZF:-}" != "1" ]] && command -v fzf >/dev/null 2>&1; then
    has_fzf="1"
  fi
  if [[ "${DEBUG_UI_NO_GUM:-}" != "1" ]] && command -v gum >/dev/null 2>&1; then
    has_gum="1"
  fi

  local ui_status="UI: fzf=$has_fzf gum=$has_gum"

  if [[ "$has_fzf" == "0" ]]; then
    local stripped_items=()
    local item
    for item in "${items[@]}"; do
      stripped_items+=( "$(strip_ansi "$item")" )
    done
    items=( "${stripped_items[@]}" )
  fi

  # Try fzf first (best experience)
  if [[ "$has_fzf" == "1" ]]; then
    local fzf_header="$header"
    local fzf_prompt="$prompt_line"
    if [[ -z "$fzf_prompt" ]]; then
      fzf_prompt="$fzf_header"
    fi
    fzf_header="${fzf_header}  |  ${ui_status}  |  using: fzf"

    # Calculate height based on terminal size and number of items
    local term_height
    term_height=$(tput lines 2>/dev/null || echo "24")
    local item_count=${#items[@]}
    # Calculate height: items + 3 lines for header/status/padding
    # This shows all items without large gaps
    local fzf_height=$((item_count + 3))
    # Cap at terminal height minus 1 to avoid overflow
    if [[ $fzf_height -gt $((term_height - 1)) ]]; then
      fzf_height=$((term_height - 1))
    fi
    # Ensure minimum height of 5
    if [[ $fzf_height -lt 5 ]]; then
      fzf_height=5
    fi

    printf '%s\n' "${items[@]}" | fzf \
      --ansi \
      --border=rounded \
      --header="$fzf_header" \
      --prompt="${fzf_prompt} " \
      --layout=reverse-list \
      --height="$fzf_height" \
      --cycle
    return $?
  fi

  # Try gum second (modern alternative)
  if [[ "$has_gum" == "1" ]]; then
    # Calculate height based on terminal size (leave room for header and padding)
    local term_height
    term_height=$(tput lines 2>/dev/null || echo "24")
    local item_count=${#items[@]}
    # Use terminal height minus 4 (for header/padding), but at least 5, max term_height-2
    local gum_height=$((term_height - 4))
    if [[ $gum_height -lt 5 ]]; then
      gum_height=5
    fi
    if [[ $gum_height -gt $item_count ]]; then
      gum_height=$item_count
    fi

    local gum_items=()
    local item
    for item in "${items[@]}"; do
      gum_items+=( "$(strip_ansi "$item")" )
    done
    printf '%s\n' "${gum_items[@]}" | gum choose --header="${header}  |  ${ui_status}  |  using: gum" --height="$gum_height" --cursor=">" --border
    return $?
  fi

  # Fallback to basic select menu
  # Remove numbers from items since select adds its own numbers
  # But keep "0) Quit" items as-is and handle "0" input specially
  local select_items=()
  local quit_index=-1
  local item i=0
  for item in "${items[@]}"; do
    local item_no_ansi
    item_no_ansi="$(strip_ansi "$item")"
    # Check if this is "0) Quit" or similar
    if [[ "$item_no_ansi" =~ ^[[:space:]]*0\)[[:space:]]+Quit ]]; then
      # Keep "0) Quit" as-is and remember its index
      select_items+=( "$item_no_ansi" )
      quit_index=$i
    else
      # Remove leading number and ") " pattern (e.g., " 1) " or "1) ")
      select_items+=( "${item_no_ansi#*[0-9]) }" )
    fi
    i=$((i + 1))
  done

  echo "${prompt}" >&2
  echo "${ui_status}  |  using: select" >&2
  echo "" >&2
  select choice in "${select_items[@]}"; do
    # Handle "0" input specially for Quit option
    if [[ "$REPLY" == "0" ]] && [[ $quit_index -ge 0 ]]; then
      echo "${items[$quit_index]}"
      return 0
    fi
    if [[ -n "$choice" ]]; then
      # Find the original item that matches this choice
      local i
      for ((i = 0; i < ${#select_items[@]}; i++)); do
        if [[ "${select_items[$i]}" == "$choice" ]]; then
          echo "${items[$i]}"
          return 0
        fi
      done
      # Fallback: return the choice as-is
      echo "$choice"
      return 0
    fi
  done
}

###############################################################################
# Script dir and config
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SIZE_DATA_FILE="${SIZE_DATA_FILE:-"$SCRIPT_DIR/get-cloud-folder-size-data.txt"}"
HISTORY_FILE="${HISTORY_FILE:-"$SCRIPT_DIR/get-cloud-folder-size-history.md"}"

ACTION_RETURN="Return to remote list"
ACTION_SIZE_ALL="Get size for all folders"
ACTION_CLEAR="Clear size data for displayed remotes/folders"
ACTION_SORT_SIZE="Sort by size (desc)"
ACTION_QUIT="Quit"

# Persistent cache arrays (parallel arrays for macOS bash compatibility)
SIZE_REMOTE_KEYS=()
SIZE_FOLDER_KEYS=()
SIZE_BYTES_VALUES=()

# Last run values from run_size_for_folder
LAST_TOTAL_BYTES=""
LAST_TOTAL_TIME=""
LAST_TOTAL_OBJECTS=""

###############################################################################
# Helpers
###############################################################################

pause_any_key() {
  # Drain any pending input so stray Enter doesn't auto-continue.
  while read -r -n 1 -t 0; do :; done
  printf "Press any key to continue..."
  if [[ "$HISTORY_ACTIVE" == "1" ]]; then
    history_write_line "Press any key to continue..."
  fi
  read -r -n 1 -s || true
  echo
  # if [[ "$HISTORY_ACTIVE" == "1" ]]; then
  #   history_write_line ""
  # fi
}

require_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    log_error "rclone not found in PATH."
    exit 1
  fi
}

clear_screen() {
  if command -v clear >/dev/null 2>&1; then
    clear
  else
    printf '\033[2J\033[H'
  fi
}

extract_first_line_matching() {
  local pattern="$1"
  local file="$2"
  awk -v pattern="$pattern" 'index($0, pattern) { print; exit }' "$file" 2>/dev/null || true
}

extract_last_line_matching() {
  local pattern="$1"
  local file="$2"
  awk -v pattern="$pattern" 'index($0, pattern) { line = $0 } END { if (line != "") print line }' "$file" 2>/dev/null || true
}

extract_bytes_from_total_line() {
  local total_line="$1"
  printf '%s\n' "$total_line" | sed -nE 's/.*\(([0-9]+)[[:space:]]+Byte[s]?\).*/\1/p' | head -n 1
}

extract_human_from_total_line() {
  local total_line="$1"
  local human
  human=$(printf '%s\n' "$total_line" | sed -nE 's/^Total size:[[:space:]]*([^()]+).*$/\1/p' | head -n 1)
  human=$(trim_spaces "$human")
  if [[ -n "$human" ]]; then
    printf '%s\n' "$human"
  fi
}

format_bytes_compact() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN {
    unit_count = split("B KB MB GB TB PB", units, " ")
    size = bytes + 0
    idx = 1
    while (size >= 1000 && idx < unit_count) {
      size /= 1000
      idx++
    }
    printf "%.2f %s", size, units[idx]
  }'
}

format_integer_with_commas() {
  local value="$1"
  value="$(printf '%s' "$value" | tr -cd '0-9')"
  [[ -n "$value" ]] || return 0

  local len=${#value}
  local out=""
  while (( len > 3 )); do
    out=",${value:len-3:3}${out}"
    len=$((len - 3))
  done
  out="${value:0:len}${out}"
  printf '%s\n' "$out"
}

trim_spaces() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_ansi() {
  local s="$1"
  printf '%s' "$s" | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g'
}

history_start_entry() {
  local remote="$1"
  local folder="$2"
  local command_display="$3"
  local ts
  ts="$(date '+%Y-%m-%d %-I:%M %p')"

  mkdir -p "$(dirname "$HISTORY_FILE")" 2>/dev/null || true

  HISTORY_ENTRY_FILE="$(mktemp "${TMPDIR:-/tmp}/gcfs-history.XXXXXX")"

  if ! {
    printf '\n---\n\n'
    printf '## %s\n\n' "$ts"
    printf -- '- Remote: %s\n' "$remote"
    printf -- '- Folder: %s\n' "$folder"
    printf -- '- Command: `%s`\n\n' "$command_display"
    printf '```\n'
  } >> "$HISTORY_ENTRY_FILE" 2>/dev/null; then
    HISTORY_ACTIVE="0"
    if [[ "$HISTORY_WARNED" == "0" ]]; then
      printf '⚠  WARNING: Unable to write history log: %s\n' "$HISTORY_FILE" >&2
      HISTORY_WARNED="1"
    fi
    return
  fi
  HISTORY_ACTIVE="1"
}

history_write_line() {
  local line="$1"
  line="${line//$'\r'/}"
  line="$(strip_ansi "$line")"
  if [[ "$HISTORY_ACTIVE" == "1" ]]; then
    printf '%s\n' "$line" >> "$HISTORY_ENTRY_FILE" 2>/dev/null || true
  fi
}

history_end_entry() {
  if [[ "$HISTORY_ACTIVE" == "1" ]]; then
    {
      printf '```\n\n'
      printf '---\n'
    } >> "$HISTORY_ENTRY_FILE" 2>/dev/null || true

    local tmp_out
    tmp_out="$(mktemp "${TMPDIR:-/tmp}/gcfs-history-out.XXXXXX")"
    if [[ -s "$HISTORY_FILE" ]]; then
      cat "$HISTORY_ENTRY_FILE" "$HISTORY_FILE" > "$tmp_out" 2>/dev/null || true
    else
      cat "$HISTORY_ENTRY_FILE" > "$tmp_out" 2>/dev/null || true
    fi
    if [[ -s "$tmp_out" ]]; then
      mv "$tmp_out" "$HISTORY_FILE" 2>/dev/null || true
    else
      rm -f "$tmp_out" 2>/dev/null || true
    fi
  fi
  HISTORY_ACTIVE="0"
  if [[ -n "$HISTORY_ENTRY_FILE" ]]; then
    rm -f "$HISTORY_ENTRY_FILE" 2>/dev/null || true
  fi
  HISTORY_ENTRY_FILE=""
}

get_remote_type() {
  local remote_name="$1"
  local depth=0

  while [[ -n "$remote_name" && $depth -lt 5 ]]; do
    local cfg type remote_ref
    cfg="$(rclone config show "$remote_name" 2>/dev/null || true)"
    if [[ -z "$cfg" ]]; then
      echo ""
      return
    fi

    type="$(printf '%s\n' "$cfg" | awk -F'=' '/^[[:space:]]*type[[:space:]]*=/{print $2; exit}')"
    type="$(trim_spaces "$type")"
    remote_ref="$(printf '%s\n' "$cfg" | awk -F'=' '/^[[:space:]]*remote[[:space:]]*=/{print $2; exit}')"
    remote_ref="$(trim_spaces "$remote_ref")"

    if [[ "$type" == "crypt" || "$type" == "alias" ]]; then
      if [[ -n "$remote_ref" ]]; then
        remote_name="${remote_ref%%:*}"
        depth=$((depth + 1))
        continue
      fi
    fi

    echo "$type"
    return
  done

  echo ""
}

array_has_arg() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

filter_args_without() {
  local needle="$1"
  shift
  local out=()
  local arg
  for arg in "$@"; do
    if [[ "$arg" != "$needle" ]]; then
      out+=( "$arg" )
    fi
  done
  printf '%s\n' "${out[@]}"
}

format_total_objects_line() {
  local line="$1"
  local objects_count objects_count_fmt objects_human

  objects_count=$(printf '%s\n' "$line" | sed -nE 's/.*\(([0-9]+)\).*/\1/p' | head -n 1)
  if [[ -n "$objects_count" ]]; then
    objects_count_fmt=$(format_integer_with_commas "$objects_count")
    objects_human=$(printf '%s\n' "$line" | sed -nE 's/^Total objects:[[:space:]]*([^()]*)[[:space:]]*\([0-9]+\).*/\1/p' | head -n 1)
    objects_human=$(trim_spaces "$objects_human")
    if [[ -n "$objects_human" ]]; then
      printf 'Total objects: %s (%s)\n' "$objects_human" "$objects_count_fmt"
    else
      printf 'Total objects: %s\n' "$objects_count_fmt"
    fi
    return 0
  fi

  objects_count=$(printf '%s\n' "$line" | sed -nE 's/^Total objects:[[:space:]]*([0-9]+).*$/\1/p' | head -n 1)
  if [[ -n "$objects_count" ]]; then
    objects_count_fmt=$(format_integer_with_commas "$objects_count")
    printf 'Total objects: %s\n' "$objects_count_fmt"
    return 0
  fi

  printf '%s\n' "$line"
}

extract_last_elapsed_time() {
  local file="$1"
  awk -F'Elapsed time:[[:space:]]*' '
    NF > 1 { value = $2 }
    END {
      gsub(/^[[:space:]]+/, "", value)
      sub(/Transferred:.*/, "", value)
      gsub(/[[:space:]]+$/, "", value)
      if (value != "") {
        print value
      }
    }
  ' "$file" 2>/dev/null || true
}

load_size_data() {
  SIZE_REMOTE_KEYS=()
  SIZE_FOLDER_KEYS=()
  SIZE_BYTES_VALUES=()

  [[ -f "$SIZE_DATA_FILE" ]] || return 0

  while IFS='|' read -r remote folder bytes; do
    [[ -n "$remote" ]] || continue
    [[ "$remote" =~ ^[[:space:]]*# ]] && continue
    [[ -n "$folder" ]] || continue
    [[ "$bytes" =~ ^[0-9]+$ ]] || continue
    SIZE_REMOTE_KEYS+=("$remote")
    SIZE_FOLDER_KEYS+=("$folder")
    SIZE_BYTES_VALUES+=("$bytes")
  done < "$SIZE_DATA_FILE"
}

save_size_data() {
  local tmp_file="${SIZE_DATA_FILE}.tmp"
  mkdir -p "$(dirname "$SIZE_DATA_FILE")" 2>/dev/null || true

  {
    printf '# Cache for get-cloud-folder-size.sh\n'
    printf '# Format: remote|folder|bytes\n'
    printf '# Safe to delete; it will be recreated.\n'
    local i
    for ((i = 0; i < ${#SIZE_REMOTE_KEYS[@]}; i++)); do
      printf '%s|%s|%s\n' "${SIZE_REMOTE_KEYS[$i]}" "${SIZE_FOLDER_KEYS[$i]}" "${SIZE_BYTES_VALUES[$i]}"
    done
  } > "$tmp_file"

  mv "$tmp_file" "$SIZE_DATA_FILE"
}

find_size_index() {
  local remote="$1"
  local folder="$2"
  local i
  for ((i = 0; i < ${#SIZE_REMOTE_KEYS[@]}; i++)); do
    if [[ "${SIZE_REMOTE_KEYS[$i]}" == "$remote" && "${SIZE_FOLDER_KEYS[$i]}" == "$folder" ]]; then
      echo "$i"
      return
    fi
  done
  echo "-1"
}

get_cached_size_bytes() {
  local remote="$1"
  local folder="$2"
  local idx
  idx=$(find_size_index "$remote" "$folder")
  if [[ "$idx" -ge 0 ]]; then
    printf '%s\n' "${SIZE_BYTES_VALUES[$idx]}"
  fi
  return 0
}

get_cached_size_display() {
  local remote="$1"
  local folder="$2"
  local bytes
  bytes=$(get_cached_size_bytes "$remote" "$folder")
  if [[ -n "$bytes" ]]; then
    format_bytes_compact "$bytes"
  fi
  return 0
}

set_cached_size() {
  local remote="$1"
  local folder="$2"
  local bytes="$3"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1

  local idx
  idx=$(find_size_index "$remote" "$folder")
  if [[ "$idx" -ge 0 ]]; then
    SIZE_BYTES_VALUES[$idx]="$bytes"
  else
    SIZE_REMOTE_KEYS+=("$remote")
    SIZE_FOLDER_KEYS+=("$folder")
    SIZE_BYTES_VALUES+=("$bytes")
  fi
  save_size_data
}

clear_all_size_data() {
  SIZE_REMOTE_KEYS=()
  SIZE_FOLDER_KEYS=()
  SIZE_BYTES_VALUES=()
  save_size_data
}

clear_remote_size_data() {
  local remote="$1"

  local new_remotes=()
  local new_folders=()
  local new_bytes=()
  local removed=0
  local i

  for ((i = 0; i < ${#SIZE_REMOTE_KEYS[@]}; i++)); do
    if [[ "${SIZE_REMOTE_KEYS[$i]}" == "$remote" ]]; then
      removed=$((removed + 1))
    else
      new_remotes+=("${SIZE_REMOTE_KEYS[$i]}")
      new_folders+=("${SIZE_FOLDER_KEYS[$i]}")
      new_bytes+=("${SIZE_BYTES_VALUES[$i]}")
    fi
  done

  SIZE_REMOTE_KEYS=("${new_remotes[@]}")
  SIZE_FOLDER_KEYS=("${new_folders[@]}")
  SIZE_BYTES_VALUES=("${new_bytes[@]}")
  save_size_data

  printf '%s\n' "$removed"
}

fetch_top_level_dirs() {
  local remote="$1"
  rclone lsf --dirs-only --max-depth 1 "${remote}:" 2>/dev/null | sed '/^$/d; s:/$::'
}

###############################################################################
# Core actions
###############################################################################

run_size_for_folder() {
  local remote="$1"
  local folder="$2"
  local pause_after="${3:-1}"
  local target="${remote}:${folder}"
  local fast_list_mode="${FAST_LIST_MODE:-auto}"

  LAST_TOTAL_BYTES=""
  LAST_TOTAL_TIME=""
  LAST_TOTAL_OBJECTS=""

  # You can override defaults via RCLONE_SIZE_ARGS, e.g.
  # RCLONE_SIZE_ARGS="--fast-list" ./get-cloud-folder-size.sh
  local extra_args=( )
  if [[ -n "${RCLONE_SIZE_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra_args=( ${RCLONE_SIZE_ARGS} )
  fi
  if [[ ${#EXTRA_RCLONE_ARGS[@]} -gt 0 ]]; then
    extra_args+=( "${EXTRA_RCLONE_ARGS[@]}" )
  fi

  if [[ "$fast_list_mode" == "off" ]]; then
    mapfile -t extra_args < <(filter_args_without "--fast-list" "${extra_args[@]}")
  fi

  local listed_count="0"
  local listed_count_display="0"
  local elapsed_time="0.0s"
  local last_rendered_status=""
  local status_width=96

  local run_start_epoch
  run_start_epoch=$(date +%s)

  # Build and print the exact rclone command before running it.
  local rclone_cmd=(rclone size "$target" --progress --stats 1s)
  local remote_type
  remote_type="$(get_remote_type "$remote")"
  local fast_list_enabled="0"
  if [[ "$fast_list_mode" == "on" ]]; then
    fast_list_enabled="1"
  elif [[ "$fast_list_mode" == "auto" && "$remote_type" == "drive" ]]; then
    fast_list_enabled="1"
  fi

  if [[ "$fast_list_enabled" == "1" ]] && ! array_has_arg "--fast-list" "${extra_args[@]}"; then
    rclone_cmd+=(--fast-list)
  fi

  rclone_cmd+=("${extra_args[@]}")
  if [[ "$remote_type" == "onedrive" ]]; then
    if [[ "$fast_list_enabled" == "1" ]] || array_has_arg "--fast-list" "${extra_args[@]}"; then
      rclone_cmd+=(--onedrive-delta)
    fi
  fi
  local command_display
  command_display="$(printf '%q ' "${rclone_cmd[@]}")"

  history_start_entry "$remote" "$folder" "$command_display"

  echo
  printf "%bRunning rclone to get the total size of all files within the selected cloud drive folder%b\n" "${COLOR_BOLD}${COLOR_BLUE}" "$COLOR_RESET"
  history_write_line "Running rclone to get the total size of all files within the selected cloud drive folder"
  printf "%bSizing:%b %s\n" "$COLOR_LABEL" "$COLOR_RESET" "$target"
  history_write_line "Sizing: $target"
  printf "%bCommand:%b %s\n\n" "$COLOR_LABEL" "$COLOR_RESET" "$command_display"
  history_write_line "Command: $command_display"
  history_write_line ""

  # Prefer line-buffered output for smoother live updates.
  local rclone_runner=( "${rclone_cmd[@]}" )
  if command -v stdbuf >/dev/null 2>&1; then
    rclone_runner=(stdbuf -oL -eL "${rclone_cmd[@]}")
  fi

  local fifo
  fifo="$(mktemp -u "${TMPDIR:-/tmp}/rclone-size.XXXXXX")"
  mkfifo "$fifo"

  # Convert carriage returns to newlines, optionally log raw lines, and render a clean status line.
  "${rclone_runner[@]}" 2>&1 | tr '\r' '\n' > "$fifo" &
  local rclone_pid=$!

  local total_line=""
  local objects_line=""
  local elapsed_line=""

  while IFS= read -r line; do
      if [[ "$line" =~ Listed[[:space:]]+([0-9][0-9,]*) ]]; then
        listed_count="${BASH_REMATCH[1]}"
        listed_count="${listed_count//,/}"
        listed_count_display=$(format_integer_with_commas "$listed_count")
        if [[ -z "$listed_count_display" ]]; then
          listed_count_display="$listed_count"
        fi
      fi

      if [[ "$line" == *"Elapsed time:"* ]]; then
        elapsed_time="$(printf '%s\n' "$line" | sed -E 's/.*Elapsed time:[[:space:]]*//; s/[[:space:]]+$//')"
        elapsed_time="${elapsed_time%%Transferred:*}"
        elapsed_time="$(trim_spaces "$elapsed_time")"
        elapsed_line="$elapsed_time"
      fi

      if [[ "$line" == Total\ size:* ]]; then
        total_line="$line"
      fi
      if [[ "$line" == Total\ objects:* ]]; then
        objects_line="$line"
      fi

      local status status_plain
      status_plain="Listed objects: ${listed_count_display} | Elapsed time: ${elapsed_time}"
      status="$(printf "%bListed objects: %s%b | %bElapsed time:%b %s" \
        "$COLOR_ACCENT" "$listed_count_display" "$COLOR_RESET" \
        "$COLOR_ACCENT" "$COLOR_RESET" "$elapsed_time")"
      if [[ "$status" != "$last_rendered_status" ]]; then
        printf '\r%-*s' "$status_width" "$status"
        last_rendered_status="$status"
      fi
    done < "$fifo"

  wait "$rclone_pid"
  local rclone_status=$?
  rm -f "$fifo"

  if [[ "$rclone_status" -ne 0 ]]; then
    echo
    echo
    log_error "rclone size failed for ${target}."
    echo
    if [[ "$pause_after" == "1" ]]; then
      pause_any_key
    fi
    history_end_entry
    return
  fi

  # Move to next line after the live status line.
  printf '\n'

  local run_end_epoch total_seconds
  run_end_epoch=$(date +%s)
  total_seconds=$((run_end_epoch - run_start_epoch))

  echo

  local total_time_line

  if [[ -n "$elapsed_line" ]]; then
    total_time_line="$elapsed_line"
  else
    total_time_line="${total_seconds}s"
  fi

  LAST_TOTAL_TIME="$total_time_line"
  LAST_TOTAL_OBJECTS="$objects_line"

  if [[ -n "$total_line" ]]; then
    local total_bytes formatted_size total_bytes_formatted total_human
    total_bytes=$(extract_bytes_from_total_line "$total_line")
    total_human=$(extract_human_from_total_line "$total_line")
    if [[ -n "$total_bytes" ]]; then
      LAST_TOTAL_BYTES="$total_bytes"
      formatted_size=$(format_bytes_compact "$total_bytes")
      total_bytes_formatted=$(format_integer_with_commas "$total_bytes")
      printf "%bTotal size: %s (%s bytes)%b\n" "$COLOR_BOLD" "$formatted_size" "$total_bytes_formatted" "$COLOR_RESET"
      history_write_line "Total size: ${formatted_size} (${total_bytes_formatted} bytes)"
      if [[ -n "$total_human" ]]; then
        printf "Total size reported by rclone: %s\n" "$total_human"
        history_write_line "Total size reported by rclone: ${total_human}"
      fi
    else
      printf "%b%s%b\n" "$COLOR_BOLD" "$total_line" "$COLOR_RESET"
      history_write_line "$total_line"
    fi
    if [[ -n "$objects_line" ]]; then
      local objects_display
      objects_display="$(format_total_objects_line "$objects_line")"
      printf '%s\n' "$objects_display"
      history_write_line "$objects_display"
    fi
    printf "Total time: %s\n" "$total_time_line"
    history_write_line "Total time: ${total_time_line}"
  else
    log_warn "Total size not found in output."
    history_write_line "Total size not found in output."
    printf "Total time: %s\n" "$total_time_line"
    history_write_line "Total time: ${total_time_line}"
  fi

  echo
  if [[ "$pause_after" == "1" ]]; then
    pause_any_key
  fi

  history_end_entry
}

###############################################################################
# Menus
###############################################################################

size_all_unsized_folders() {
  local remote="$1"
  shift
  local folders=( "$@" )

  local unsized=()
  local folder bytes
  for folder in "${folders[@]}"; do
    bytes=$(get_cached_size_bytes "$remote" "$folder")
    if [[ -z "$bytes" ]]; then
      unsized+=( "$folder" )
    fi
  done

  if [[ ${#unsized[@]} -eq 0 ]]; then
    echo
    printf "All displayed folders already have size data.\n\n"
    pause_any_key
    return
  fi

  local total=${#unsized[@]}
  local i=0
  for folder in "${unsized[@]}"; do
    i=$((i + 1))
    printf "\n[%d/%d] %s\n" "$i" "$total" "$folder"
    run_size_for_folder "$remote" "$folder" 0
    if [[ -n "$LAST_TOTAL_BYTES" ]]; then
      set_cached_size "$remote" "$folder" "$LAST_TOTAL_BYTES"
    fi
  done

  echo
  printf "Finished sizing %d folder(s).\n\n" "$total"
  pause_any_key
}

folder_menu() {
  local remote="$1"
  local sort_by_size="${SORT_BY_SIZE_DEFAULT:-1}"
  local menu_color_enabled="0"
  if [[ "$MENU_COLOR" == "1" && "${DEBUG_UI_NO_FZF:-}" != "1" ]] && command -v fzf >/dev/null 2>&1; then
    menu_color_enabled="1"
  fi
  while true; do
    local dirs=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && dirs+=( "$line" )
    done < <(fetch_top_level_dirs "$remote")

    clear_screen

    if [[ ${#dirs[@]} -eq 0 ]]; then
      printf "No top-level folders found on %s:\n\n" "$remote"
      pause_any_key
      return
    fi

    local max_name_len=0
    local d
    for d in "${dirs[@]}"; do
      local len=${#d}
      if (( len > max_name_len )); then
        max_name_len=$len
      fi
    done

    local display_dirs=()
    if [[ "$sort_by_size" == "1" ]]; then
      local rows=()
      local d bytes
      for d in "${dirs[@]}"; do
        bytes=$(get_cached_size_bytes "$remote" "$d")
        if [[ -z "$bytes" ]]; then
          bytes=-1
        fi
        rows+=( "${bytes}"$'\t'"${d}" )
      done
      IFS=$'\n' display_dirs=($(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1nr | cut -f2-)) || true
      IFS=$' \t\n'
    else
      display_dirs=( "${dirs[@]}" )
    fi

    local display_name_len="$max_name_len"
    local max_align_len="${SIZE_ALIGN_MAX_LEN:-20}"
    if [[ "$display_name_len" -gt "$max_align_len" ]]; then
      display_name_len="$max_align_len"
    fi

    local options=()
    options+=( "$ACTION_RETURN" )
    local sort_label="$ACTION_SORT_SIZE"
    if [[ "$sort_by_size" == "1" ]]; then
      sort_label="Sort by size (asc)"
    fi
    options+=( "$sort_label" )

    for d in "${display_dirs[@]}"; do
      local size_display line
      size_display=$(get_cached_size_display "$remote" "$d")
      if [[ -n "$size_display" ]]; then
        local name_display="$d"
        if [[ ${#name_display} -gt "$display_name_len" ]]; then
          name_display="${name_display:0:$display_name_len}"
        fi
        line=$(printf "%-*s  [%s]" "$display_name_len" "$name_display" "$size_display")
      else
        line="$d"
      fi
      options+=( "$line" )
    done

    options+=( "$ACTION_SIZE_ALL" )
    options+=( "$ACTION_CLEAR" )

    local display_options=()
    local option_count=${#options[@]}
    local i
    for ((i = 0; i < option_count; i++)); do
      local label="${options[$i]}"
      if [[ "$menu_color_enabled" == "1" && ( "$label" == "$ACTION_RETURN" || "$label" == "$ACTION_SORT_SIZE" || "$label" == "$ACTION_SIZE_ALL" || "$label" == "$ACTION_CLEAR" || "$label" == "Sort by size (asc)" ) ]]; then
        label="${COLOR_MENU_LABEL}${label}${COLOR_RESET}"
      fi
      display_options+=( "$(printf '%2d) %s' $((i + 1)) "$label")" )
    done

    local prompt_header="[REMOTE: ${remote}]"
    local prompt_body="Choose a top-level folder"

    local choice
    choice=$(pick_option "${prompt_header}"$'\n'"${prompt_body}" "${display_options[@]}") || return

    local chosen_index=-1
    local choice_no_ansi
    choice_no_ansi="$(strip_ansi "$choice")"
    for ((i = 0; i < ${#display_options[@]}; i++)); do
      if [[ "$(strip_ansi "${display_options[$i]}")" == "$choice_no_ansi" ]]; then
        chosen_index=$i
        break
      fi
    done

    if (( chosen_index < 0 )); then
      continue
    fi

    local return_index=0
    local sort_index=1
    local first_folder_index=2
    local folder_count=${#dirs[@]}
    local size_all_index=$((first_folder_index + folder_count))
    local clear_index=$((size_all_index + 1))

    if (( chosen_index == return_index )); then
      return
    fi

    if (( chosen_index == sort_index )); then
      if [[ "$sort_by_size" == "1" ]]; then
        sort_by_size="0"
      else
        sort_by_size="1"
      fi
      continue
    fi

    if (( chosen_index == size_all_index )); then
      size_all_unsized_folders "$remote" "${dirs[@]}"
      continue
    fi

    if (( chosen_index == clear_index )); then
      local removed_count
      removed_count=$(clear_remote_size_data "$remote")
      echo
      printf "Cleared %s cached size entr%s for remote %s.\n\n" \
        "$removed_count" \
        "$( [[ "$removed_count" == "1" ]] && echo "y" || echo "ies" )" \
        "$remote"
      pause_any_key
      continue
    fi

    if (( chosen_index < first_folder_index || chosen_index >= first_folder_index + folder_count )); then
      continue
    fi

    local selected_folder_index=$((chosen_index - first_folder_index))
    local selected_folder="${display_dirs[$selected_folder_index]}"

    run_size_for_folder "$remote" "$selected_folder" 1
    if [[ -n "$LAST_TOTAL_BYTES" ]]; then
      set_cached_size "$remote" "$selected_folder" "$LAST_TOTAL_BYTES"
    fi
  done
}

main() {
  local fast_list_mode_cli=""
  local arg
  local passthrough=0
  EXTRA_RCLONE_ARGS=()
  local menu_color_enabled="0"
  if [[ "$MENU_COLOR" == "1" && "${DEBUG_UI_NO_FZF:-}" != "1" ]] && command -v fzf >/dev/null 2>&1; then
    menu_color_enabled="1"
  fi
  for arg in "$@"; do
    if [[ "$passthrough" == "1" ]]; then
      EXTRA_RCLONE_ARGS+=( "$arg" )
      continue
    fi
    case "$arg" in
      --fast-list)
        fast_list_mode_cli="on"
        ;;
      --no-fast-list)
        fast_list_mode_cli="off"
        ;;
      --help|-h)
        cat <<'EOF'
Usage: ./get-cloud-folder-size.sh [--fast-list|--no-fast-list] [-- <rclone size args>]

Options:
  --fast-list       Force fast-list for all remotes.
  --no-fast-list    Disable fast-list and strip it from extra args.
  -h, --help        Show this help.

Notes:
  - RCLONE_SIZE_ARGS env var is appended to rclone size.
  - Use `--` to pass rclone size args directly.
EOF
        exit 0
        ;;
      --)
        passthrough=1
        ;;
      *)
        # Unknown args are passed through to rclone size.
        EXTRA_RCLONE_ARGS+=( "$arg" )
        ;;
    esac
  done
  if [[ -n "$fast_list_mode_cli" ]]; then
    FAST_LIST_MODE="$fast_list_mode_cli"
  fi

  require_rclone
  load_size_data

  while true; do
    local remotes_raw=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && remotes_raw+=("$line")
    done < <(rclone listremotes 2>/dev/null || true)

    clear_screen

    if [[ ${#remotes_raw[@]} -eq 0 ]]; then
      printf "No rclone remotes found.\n\n"
      pause_any_key
      exit 0
    fi

    local remotes=()
    local r
    for r in "${remotes_raw[@]}"; do
      remotes+=("${r%:}")
    done

    IFS=$'\n' remotes=($(printf '%s\n' "${remotes[@]}" | sort)) || true

    local options=()
    options+=( "${remotes[@]}" )
    options+=( "$ACTION_CLEAR" )

    local display_options=()
    local remote_count=${#remotes[@]}
    local i
    for ((i = 0; i < ${#options[@]}; i++)); do
      local label="${options[$i]}"
      if [[ "$menu_color_enabled" == "1" && "$label" == "$ACTION_CLEAR" ]]; then
        label="${COLOR_MENU_LABEL}${label}${COLOR_RESET}"
      fi
      display_options+=( "$(printf '%2d) %s' $((i + 1)) "$label")" )
    done
    if [[ "$menu_color_enabled" == "1" ]]; then
      display_options+=( "0) ${COLOR_MENU_LABEL}${ACTION_QUIT}${COLOR_RESET}" )
    else
      display_options+=( "0) ${ACTION_QUIT}" )
    fi

    local prompt_header="rclone folder sizes"
    local prompt_body="Select a remote"

    local choice
    choice=$(pick_option "${prompt_header}"$'\n'"${prompt_body}" "${display_options[@]}") || exit 0

    local chosen_index=-1
    local choice_no_ansi
    choice_no_ansi="$(strip_ansi "$choice")"
    for ((i = 0; i < ${#display_options[@]}; i++)); do
      if [[ "$(strip_ansi "${display_options[$i]}")" == "$choice_no_ansi" ]]; then
        chosen_index=$i
        break
      fi
    done

    if (( chosen_index < 0 )); then
      continue
    fi

    local first_remote_index=0
    local clear_index=$remote_count
    local quit_index=$((remote_count + 1))

    if (( chosen_index >= first_remote_index && chosen_index < remote_count )); then
      folder_menu "${remotes[$chosen_index]}"
      continue
    fi

    if (( chosen_index == clear_index )); then
      clear_all_size_data
      echo
      printf "Cleared cached size data for all remotes.\n\n"
      pause_any_key
      continue
    fi

    if (( chosen_index == quit_index )); then
      exit 0
    fi
  done
}

main "$@"
