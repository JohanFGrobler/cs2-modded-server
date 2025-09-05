#!/usr/bin/env bash
# parse-gamemodes.sh — Parse CS2 gamemodes_server.txt -> maps.md + images
# Extracts mapgroups and maps (incl. workshop IDs), writes pretty markdown with thumbnails,
# downloads workshop preview images (parallel), and outputs a deduped ID list.
#
# Usage examples:
#   ./parse-gamemodes.sh
#   ./parse-gamemodes.sh --file ../game/csgo/gamemodes_server.txt --out maps.md --images-dir maps --concurrency 6
#   ./parse-gamemodes.sh --no-download --no-compress
#
# Requirements: bash, awk, sed, grep, curl
# Optional: ffmpeg (preferred) OR ImageMagick 'convert' for compression

set -Eeuo pipefail

########################################
# Defaults (overridable via flags)
########################################
FILE_PATH="../game/csgo/gamemodes_server.txt"
OUTPUT_FILE="maps.md"
IMAGES_DIR="maps"
COMPRESSED_DIR="compressed_maps"
CONCURRENCY=4
FORCE=0
NO_DOWNLOAD=0
NO_COMPRESS=0
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
# Flags
########################################
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --file PATH          Path to gamemodes_server.txt (default: $FILE_PATH)
  --out PATH           Output markdown file (default: $OUTPUT_FILE)
  --images-dir DIR     Directory to store downloaded images (default: $IMAGES_DIR)
  --concurrency N      Parallelism for image downloads (default: $CONCURRENCY)
  --force              Re-download images even if they exist
  --no-download        Do not download images (still writes markdown)
  --no-compress        Skip image compression step
  --no-color           Disable colored output
  -h, --help           Show help
EOF
}

while (($#)); do
  case "$1" in
    --file) FILE_PATH="$2"; shift ;;
    --out) OUTPUT_FILE="$2"; shift ;;
    --images-dir) IMAGES_DIR="$2"; shift ;;
    --concurrency) CONCURRENCY="$2"; shift ;;
    --force) FORCE=1 ;;
    --no-download) NO_DOWNLOAD=1 ;;
    --no-compress) NO_COMPRESS=1 ;;
    --no-color) COLOR=0 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown arg: $1" ;;
  esac
  shift
done

########################################
# Preflight
########################################
[[ -f "$FILE_PATH" ]] || { err "File not found: $FILE_PATH"; exit 1; }
command -v awk >/dev/null || { err "awk required"; exit 1; }
command -v curl >/dev/null || { err "curl required"; exit 1; }
mkdir -p "$IMAGES_DIR"

########################################
# Helpers
########################################
sanitize_name() {
  # Map names are pretty tame, but be safe for filenames
  printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'
}

# Try to extract a nice preview image URL from a Steam Workshop page
# Order: og:image meta -> ShowEnlargedImagePreview -> <link rel="image_src">
extract_preview_url() {
  local id="$1" content url

  content=$(curl -s "https://steamcommunity.com/sharedfiles/filedetails/?id=${id}" || true)

  # og:image
  url=$(printf '%s\n' "$content" | grep -oP '(?i)<meta\s+property="og:image"\s+content="[^"]+"' | sed -E 's/.*content="([^"]+)".*/\1/' | head -n1 || true)
  if [[ -n "${url:-}" ]]; then
    printf '%s\n' "${url%%\?*}"
    return 0
  fi

  # ShowEnlargedImagePreview(
  url=$(printf '%s\n' "$content" | awk '{
    idx=index($0,"ShowEnlargedImagePreview(");
    if(idx){ s=substr($0,idx+length("ShowEnlargedImagePreview(")+1);
      gsub(/ /,"",s);
      sub(/\).*/,"",s);
      sub(/\?.*/,"",s);
      print s; exit 0;
    }}')
  if [[ -n "${url:-}" ]]; then
    printf '%s\n' "$url"
    return 0
  fi

  # <link rel="image_src" href="...">
  url=$(printf '%s\n' "$content" | grep -oP '(?i)<link\s+rel="image_src"\s+href="[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | head -n1 || true)
  if [[ -n "${url:-}" ]]; then
    printf '%s\n' "${url%%\?*}"
    return 0
  fi

  return 1
}

# Download a single ID's image if missing or forced
download_one_image() {
  local id="$1" name="$2" force="$3"
  local out="${IMAGES_DIR%/}/$(sanitize_name "$name").png"

  if (( ! force )) && [[ -f "$out" ]]; then
    echo "SKIP ${id} ${name} (exists)"
    return 0
  fi

  local url
  if url=$(extract_preview_url "$id"); then
    if curl -sSL --fail-with-body -o "$out" "$url"; then
      echo "OK   ${id} ${name} -> $(basename "$out")"
      return 0
    else
      echo "FAIL ${id} ${name} (download error)"
      return 1
    fi
  else
    echo "FAIL ${id} ${name} (no preview url)"
    return 1
  fi
}

########################################
# Parse gamemodes_server.txt (brace-aware)
# Output lines:
#   GROUP|<group_name>
#   MAP|<group_name>|<map_name>|<workshop_id_or_empty>
########################################
parse_maps() {
  awk '
    BEGIN{
      in_mapgroups=0; group=""; depth=0;
    }
    {
      line=$0;

      # Count braces per line to manage depth changes even if { and } are on same line
      opens = gsub(/\{/,"{",line);
      closes = gsub(/\}/,"}",line);

      # Detect entry into mapgroups
      if (line ~ /"mapgroups"/) {
        in_mapgroups = 1;
      }

      # When inside mapgroups, detect group names like "mg_active"
      if (in_mapgroups && match(line,/"[^"]+"/)) {
        # Only treat as a group header when we are at the correct nesting
        # Heuristic: group header appears at depth >= 1 and followed by { later
        if (opens>0 && depth>=1) {
          g=substr(line,RSTART+1,RLENGTH-2);
          # Skip generic keys "mapgroups" and "maps"
          if (g!="mapgroups" && g!="maps") {
            group=g;
            print "GROUP|" group;
          }
        }
      }

      # Inside a group, when we are at maps block, lines like:  "de_inferno"  ""
      if (group!="" && line ~ /"maps"/ && opens>0) {
        # enter maps block, subsequent lines at one deeper depth until matching }
        maps_depth = depth + opens - closes;
        next;
      }

      # Map entries detection: lines with "..." possibly workshop/ID/map
      if (group!="" && match(line,/"[^"]+"/)) {
        key=substr(line,RSTART+1,RLENGTH-2);
        if (key=="maps" || key=="mapgroups") {
          # not a map line
        } else {
          id="";
          mapname=key;
          # workshop path?
          if (match(key,/^workshop\/([0-9]+)\/(.+)$/,m)) {
            id=m[1]; mapname=m[2];
          }
          print "MAP|" group "|" mapname "|" id;
        }
      }

      depth += opens;
      depth -= closes;
      if (depth<0) depth=0;

      # When closing a group
      if (depth==0) {
        group="";
      }
    }
  ' "$FILE_PATH" | awk 'NF>0'
}

########################################
# Run parse and assemble structures
########################################
IFS=$'\n' read -r -d '' -a LINES < <(parse_maps && printf '\0') || true

declare -A GROUP_MAPS        # group -> concatenated HTML
declare -A NEEDED_IDS_SET    # id -> 1
declare -A ID_TO_NAME        # id -> last map name (for filenames)

# Build markdown blocks and collect IDs
for entry in "${LINES[@]}"; do
  IFS='|' read -r kind rest <<<"$entry"
  if [[ "$kind" == "GROUP" ]]; then
    group="$rest"
    GROUP_MAPS["$group"]=""
  elif [[ "$kind" == "MAP" ]]; then
    IFS='|' read -r _ group map_name workshop_id <<<"$entry"
    safe_map="$(sanitize_name "$map_name")"

    if [[ -n "$workshop_id" ]]; then
      NEEDED_IDS_SET["$workshop_id"]=1
      ID_TO_NAME["$workshop_id"]="$map_name"
      thumb_src="${IMAGES_DIR%/}/${safe_map}.png"
      # Use your GitHub asset fallback if local thumb absent at render time
      img_tag="<img src=\"https://github.com/kus/cs2-modded-server/blob/assets/images/${safe_map}.jpg?raw=true&amp;sanitize=true\" onerror=\"this.src='${IMAGES_DIR}/${safe_map}.png'\">"
      cell="<table align=\"left\"><tr><td>${img_tag}</td></tr><tr><td><a href=\"https://steamcommunity.com/sharedfiles/filedetails/?id=${workshop_id}\">${map_name}</a><br><sup><sub>host_workshop_map ${workshop_id}</sub></sup></td></tr></table>"
    else
      img_tag="<img src=\"https://github.com/kus/cs2-modded-server/blob/assets/images/${safe_map}.jpg?raw=true&amp;sanitize=true\">"
      cell="<table align=\"left\"><tr><td>${img_tag}</td></tr><tr><td>${map_name}<br><sup><sub>changelevel ${map_name}</sub></sup></td></tr></table>"
    fi

    GROUP_MAPS["$group"]+="$cell"
  fi
done

########################################
# Write markdown
########################################
: > "$OUTPUT_FILE"
for g in "${!GROUP_MAPS[@]}"; do
  {
    echo "#### $g"
    echo "<table><tr><td>${GROUP_MAPS[$g]}</td></tr></table>"
    echo
  } >> "$OUTPUT_FILE"
done
ok "Wrote $OUTPUT_FILE"

########################################
# Write NEW_subscribed_file_ids.txt (deduped)
########################################
: > NEW_subscribed_file_ids.txt
for id in "${!NEEDED_IDS_SET[@]}"; do
  echo "$id" >> NEW_subscribed_file_ids.txt
done
# stable order
sort -u -o NEW_subscribed_file_ids.txt NEW_subscribed_file_ids.txt
ok "Wrote NEW_subscribed_file_ids.txt ($(wc -l < NEW_subscribed_file_ids.txt) ids)"

########################################
# Download images (parallel) unless disabled
########################################
if (( ! NO_DOWNLOAD )) && ((${#NEEDED_IDS_SET[@]}>0)); then
  export -f extract_preview_url download_one_image sanitize_name
  export IMAGES_DIR

  TMPJ="$(mktemp)"
  : > "$TMPJ"
  for id in "${!NEEDED_IDS_SET[@]}"; do
    name="${ID_TO_NAME[$id]}"
    printf '%s|%s|%s\n' "$id" "$name" "$FORCE" >> "$TMPJ"
  done

  # shellcheck disable=SC2002
  cat "$TMPJ" | xargs -P "$CONCURRENCY" -n 1 -I{} bash -c '
    IFS="|" read -r id name force <<< "{}"
    download_one_image "$id" "$name" "$force"
  '

  rm -f "$TMPJ"
fi

########################################
# Compress images unless disabled
########################################
if (( ! NO_COMPRESS )); then
  rm -rf "$COMPRESSED_DIR"
  mkdir -p "$COMPRESSED_DIR"

  have_ffmpeg=0; have_convert=0
  command -v ffmpeg >/dev/null && have_ffmpeg=1
  command -v convert >/dev/null && have_convert=1

  if (( have_ffmpeg )); then
    # Small thumbnails (192x108 max), good quality
    for f in "${IMAGES_DIR%/}/"*; do
      [[ -f "$f" ]] || continue
      if file "$f" | grep -qiE 'image|bitmap'; then
        base="$(basename "$f")"; name="${base%.*}"
        ffmpeg -loglevel error -y -i "$f" \
          -vf "scale='min(192,iw)':'min(108,ih)':force_original_aspect_ratio=decrease" \
          -qscale:v 2 "$COMPRESSED_DIR/${name}.jpg" || true
      fi
    done
    ok "Compressed images with ffmpeg -> $COMPRESSED_DIR"
  elif (( have_convert )); then
    for f in "${IMAGES_DIR%/}/"*; do
      [[ -f "$f" ]] || continue
      if file "$f" | grep -qiE 'image|bitmap'; then
        base="$(basename "$f")"; name="${base%.*}"
        convert "$f" -resize "192x108>" -quality 85 "$COMPRESSED_DIR/${name}.jpg" || true
      fi
    done
    ok "Compressed images with ImageMagick -> $COMPRESSED_DIR"
  else
    warn "No ffmpeg or convert found; skipping compression"
  fi
fi

ok "Done."
