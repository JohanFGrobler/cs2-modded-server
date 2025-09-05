#!/usr/bin/env bash
# patch.sh — insert a line into gameinfo.gi after a pattern, safely & idempotently.
# Default: insert `Game csgo/addons/metamod` after the "Game_LowViolence csgo_lv ..." line.
#
# Usage:
#   ./patch.sh
#   ./patch.sh --file game/csgo/gameinfo.gi \
#              --after 'Game_LowViolence[[:space:]]*csgo_lv[[:space:]]*// Perfect World content override' \
#              --insert $'\t\t\tGame\tcsgo/addons/metamod' \
#              --check '^[[:space:]]*Game[[:space:]]*csgo/addons/metamod([[:space:]]|$)' \
#              --backup --dry-run
#
# Flags:
#   --file PATH     : target file (default: game/csgo/gameinfo.gi)
#   --after REGEX   : line regex after which to insert
#   --insert TEXT   : exact line to insert (can use $'\t' for tabs)
#   --check REGEX   : regex to detect if line already exists (idempotent)
#   --backup        : write PATH.bak.<timestamp> before patching
#   --dry-run       : show the diff but don't write
#   --quiet         : no logs (except errors)
#
# Exit codes: 0=ok/unchanged, 1=error, 2=would-change (dry-run)

set -Eeuo pipefail

# Defaults
FILE="game/csgo/gameinfo.gi"
AFTER_REGEX='Game_LowViolence[[:space:]]*csgo_lv[[:space:]]*// Perfect World content override'
INSERT_LINE=$'\t\t\tGame\tcsgo/addons/metamod'
CHECK_REGEX='^[[:space:]]*Game[[:space:]]*csgo/addons/metamod([[:space:]]|$)'
DO_BACKUP=0
DRY_RUN=0
QUIET=0

log() { (( QUIET )) || printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

# Parse flags
while (($#)); do
  case "$1" in
    --file)       FILE="$2"; shift ;;
    --after)      AFTER_REGEX="$2"; shift ;;
    --insert)     INSERT_LINE="$2"; shift ;;
    --check)      CHECK_REGEX="$2"; shift ;;
    --backup)     DO_BACKUP=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --quiet)      QUIET=1 ;;
    -h|--help)
      sed -n '1,80p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

# Preflight
[[ -f "$FILE" ]] || { err "File not found: $FILE"; exit 1; }
[[ -r "$FILE" && -w "$FILE" ]] || { err "File not readable/writable: $FILE"; exit 1; }

# Idempotency check
if grep -qE "$CHECK_REGEX" "$FILE"; then
  log "Already present. No changes."
  exit 0
fi

# Make temp & (optional) backup
TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

if (( DO_BACKUP )); then
  TS="$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$FILE" "${FILE}.bak.${TS}"
  log "Backup: ${FILE}.bak.${TS}"
fi

# Patch: insert after the first line matching AFTER_REGEX.
# - preserves CRLF/LF line endings
# - ignores pure comment lines starting with // (but still matches AFTER_REGEX even if it has trailing comments)
# - inserts only once
awk -v after_re="$AFTER_REGEX" -v ins="$INSERT_LINE" '
  BEGIN { inserted=0 }
  {
    # Keep original line
    print $0
    if (!inserted) {
      line=$0
      # Strip trailing CR for regex tests; preserve output by printing earlier.
      sub(/\r$/,"",line)

      # Match AFTER_REGEX anywhere on the line (even if followed by comments)
      if (line ~ after_re) {
        print ins
        inserted=1
      }
    }
  }
  END {
    if (!inserted) {
      # If the anchor is not found, exit with code 3 to signal "no anchor"
      # (caller stays silent but we’ll handle below)
      exit 3
    }
  }
' "$FILE" > "$TMP" || rc=$? || true

rc=${rc:-0}
if (( rc == 3 )); then
  err "Anchor pattern not found. No changes made.
  - after regex: /'"$AFTER_REGEX"'/
  - file       : '"$FILE"'"
  exit 1
elif (( rc != 0 )); then
  err "Failed to patch (awk rc=$rc)."
  exit 1
fi

# If dry run, show a unified diff if available
if (( DRY_RUN )); then
  if command -v diff >/dev/null; then
    if diff -u --label "a/$FILE" --label "b/$FILE" "$FILE" "$TMP"; then
      log "No differences."
      exit 0
    else
      log "(dry-run) Changes detected above."
      exit 2
    fi
  else
    log "(dry-run) Patched to temp: $TMP"
    exit 2
  fi
fi

# Write final
mv -- "$TMP" "$FILE"
log "Line inserted successfully after anchor."

# Double-check idempotency (should now be found)
if grep -qE "$CHECK_REGEX" "$FILE"; then
  log "Verified present."
  exit 0
else
  err "Post-write verification failed (CHECK_REGEX did not match)."
  exit 1
fi
