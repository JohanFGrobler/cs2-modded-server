#!/usr/bin/env bash
# get-map-names.sh — Download CS2 Workshop items by ID and list map names inside their VPKs.
# Requires:
#   - steamcmd (path to dir with steamcmd.sh)
#   - vpk (Valve VPK CLI) OR python "vpk" CLI providing a compatible 'vpk -l' command
#
# Example:
#   ./get-map-names.sh --steamcmd ./steamcmd --ids-file subscribed_file_ids.txt --concurrency 4
#
# Notes:
#   - We list *.bsp in VPKs under "maps/". (Your original script grepped for ".vpk" inside VPKs — usually it's .bsp.)
#   - We search any *.vpk within the item folder (handles <id>.vpk, <id>_dir.vpk, <id>_000.vpk, pakXX_dir.vpk, etc.)
#   - By default we delete downloaded content; use --keep to retain it for inspection.

set -Eeuo pipefail

########################################
# Defaults (override via flags)
########################################
STEAMCMD_DIR="./steamcmd"                    # directory containing steamcmd.sh
IDS_FILE="subscribed_file_ids.txt"           # list of Workshop IDs (one per line; # for comments)
CONTENT_DIR=""                                # override content root; default is STEAMCMD_DIR/steamapps/content/app_730
CONCURRENCY=2                                 # parallel workers
TIMEOUT=900                                   # seconds per download job
KEEP=0                                        # keep downloaded content (0=no, 1=yes)
COLOR=1

########################################
# Colors
########################################
supports_color() { [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; }
if ! supports_color; then COLOR=0; fi
if (( COLOR )); then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_GRAY=$'\033[1;30m'; C_RED=$'\033[0;31m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_GRAY=""; C_RED=""; C_RESET=""
fi
ok()   { printf '%b%s%b\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%b%s%b\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()  { printf '%b%s%b\n' "$C_RED" "$*" "$C_RESET"; }

########################################
# Args
########################################
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --steamcmd DIR       Path to directory containing steamcmd.sh (default: ${STEAMCMD_DIR})
  --ids-file FILE      Path to file with Workshop IDs (default: ${IDS_FILE})
  --content-dir DIR    Override Steam content dir (default: <steamcmd>/steamapps/content/app_730)
  --concurrency N      Parallel downloads (default: ${CONCURRENCY})
  --timeout SEC        Per-item timeout seconds (default: ${TIMEOUT})
  --keep               Keep downloaded item_* folders (default: delete)
  --no-color           Disable colored output
  -h, --help           Show help

File format:
  One Workshop ID per line. Lines starting with # are ignored. Blank lines ignored.

Examples:
  $0 --steamcmd ./steamcmd --ids-file subscribed_file_ids.txt --concurrency 4
  $0 --keep --no-color
EOF
}

while (($#)); do
  case "$1" in
    --steamcmd)     STEAMCMD_DIR="$2"; shift ;;
    --ids-file)     IDS_FILE="$2"; shift ;;
    --content-dir)  CONTENT_DIR="$2"; shift ;;
    --concurrency)  CONCURRENCY="$2"; shift ;;
    --timeout)      TIMEOUT="$2"; shift ;;
    --keep)         KEEP=1 ;;
    --no-color)     COLOR=0 ;;
    -h|--help)      usage; exit 0 ;;
    *)              warn "Unknown arg: $1" ;;
  esac
  shift
done

########################################
# Pre-flight checks
########################################
STEAMCMD_SH="${STEAMCMD_DIR%/}/steamcmd.sh"
[[ -f "$STEAMCMD_SH" ]] || { err "steamcmd.sh not found at: $STEAMCMD_SH"; exit 1; }

if ! command -v vpk >/dev/null 2>&1; then
  err "Missing 'vpk' CLI. Install Valve VPK tools or 'pip install vpk' (if it provides 'vpk -l')."
  exit 1
fi

[[ -f "$IDS_FILE" ]] || { err "IDs file not found: $IDS_FILE"; exit 1; }

if [[ -z "$CONTENT_DIR" ]]; then
  CONTENT_DIR="${STEAMCMD_DIR%/}/steamapps/content/app_730"
fi

mkdir -p "$CONTENT_DIR"

########################################
# Core functions
########################################
download_item() {
  local id="$1"
  # SteamCMD will place content under ${CONTENT_DIR}/item_<id>
  # We let steamcmd use its default (steamcmd/steamapps/…) by cwd to STEAMCMD_DIR.
  # We avoid brittle line matching; we rely on exit code + folder existence.
  ( cd "$STEAMCMD_DIR" && timeout "$TIMEOUT" ./steamcmd.sh +login anonymous +download_item 730 "$id" +quit ) >/dev/null 2>&1
}

list_maps_in_item() {
  local id="$1"
  local item_dir="${CONTENT_DIR%/}/item_${id}"
  [[ -d "$item_dir" ]] || { err "Item folder not found after download: $item_dir"; return 1; }

  # Find any VPK files in the item dir (depth 2 to be safe)
  mapfile -t vpk_files < <(find "$item_dir" -maxdepth 2 -type f -name '*.vpk' | sort)
  if ((${#vpk_files[@]}==0)); then
    warn "No VPK files in $item_dir"
    return 2
  fi

  # Collect unique BSPs under maps/
  declare -A seen=()
  local vpkf line rc
  for vpkf in "${vpk_files[@]}"; do
    # 'vpk -l' should list internal paths; filter maps/*.bsp
    if ! output=$(vpk -l "$vpkf" 2>/dev/null); then
      warn "Failed to list VPK: $vpkf"
      continue
    fi
    while IFS= read -r line; do
      [[ "$line" =~ ^maps/.+\.bsp$ ]] || continue
      seen["$line"]=1
    done < <(printf '%s\n' "$output")
  done

  if ((${#seen[@]}==0)); then
    warn "No maps/*.bsp found in VPKs for item $id"
    return 3
  fi

  # Print sorted unique map basenames (without extension) and full paths
  printf '  %s\n' "Item $id maps:"
  for path in "${!seen[@]}"; do
    base="${path##*/}"
    map="${base%.bsp}"
    printf '    - %s (%s)\n' "$map" "$path"
  done | sort
  return 0
}

cleanup_item() {
  local id="$1"
  local item_dir="${CONTENT_DIR%/}/item_${id}"
  [[ -d "$item_dir" ]] || return 0
  rm -rf -- "$item_dir"
}

process_id() {
  local id="$1"
  [[ -n "$id" ]] || return 0
  printf '%s\n' "───────── ID: ${id} ─────────"
  if download_item "$id"; then
    ok "Downloaded item $id"
  else
    err "Download failed or timed out for $id"
    return 1
  fi

  if list_maps_in_item "$id"; then
    :
  else
    warn "No maps listed for $id"
  fi

  if (( ! KEEP )); then
    cleanup_item "$id"
  else
    warn "Keeping content: ${CONTENT_DIR%/}/item_${id}"
  fi
}

########################################
# Read IDs, strip comments, run in parallel
########################################
mapfile -t IDS < <(grep -v '^\s*#' "$IDS_FILE" | sed -e 's/^\s\+//' -e 's/\s\+$//' | awk 'NF>0')

if ((${#IDS[@]}==0)); then
  warn "No IDs found in $IDS_FILE"
  exit 0
fi

export -f download_item list_maps_in_item cleanup_item process_id
export STEAMCMD_DIR STEAMCMD_SH CONTENT_DIR KEEP TIMEOUT
export -f ok warn err

# GNU xargs parallelization
printf '%s\n' "${IDS[@]}" | xargs -P "$CONCURRENCY" -n 1 -I{} bash -c 'process_id "$@"' _ {}

# done
