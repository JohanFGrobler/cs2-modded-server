#!/usr/bin/env bash
# check-updates.sh — CS2 mods auditor/downloader
# - Reads mods from README (Mod|Version|Why table)
# - Checks latest versions (GitHub API or metamodsource)
# - Reports status; downloads + extracts updated assets into ./tmp/
# - Efficient: retries, ETag cache, optional concurrency, optional JSON report

set -Eeuo pipefail

########################################
# Defaults (overridable via flags/env)
########################################
README_URL="${README_URL:-https://raw.githubusercontent.com/kus/cs2-modded-server/master/README.md}"
DEST_ROOT="${DEST_ROOT:-./tmp}"                # where extracted assets go
USER_AGENT="cs2-mod-checker/1.2 (+bash)"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"               # set to raise API limits
CONCURRENCY="${CONCURRENCY:-4}"                # parallel downloads
FILTER_OS="${FILTER_OS:-all}"                  # linux|windows|all
DRY_RUN="${DRY_RUN:-0}"
NO_EXTRACT="${NO_EXTRACT:-0}"
ONLY_DOWNLOAD="${ONLY_DOWNLOAD:-0}"
COLOR="${COLOR:-1}"
REPORT_PATH="${REPORT_PATH:-}"                 # JSON output path or empty
RETRY_MAX=5

# Cache (ETag) to slash GitHub API calls
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cs2mods"
mkdir -p "$CACHE_DIR"

TMP_ROOT="$(mktemp -d -t cs2mods.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

########################################
# Colors & Icons
########################################
supports_color() { [[ -t 1 ]] && command -v tput >/dev/null && tput colors >/dev/null; }
if ! supports_color; then COLOR=0; fi
if (( COLOR )); then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_GRAY=$'\033[1;30m'; C_RED=$'\033[0;31m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_GRAY=""; C_RED=""; C_RESET=""
fi
ICON_OK="✅"; ICON_PKG="📦"; ICON_SCAN="🔍"; ICON_ERR="🚫"

########################################
# Logging
########################################
log() { printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*"; exit 1; }

########################################
# Curl helpers (JSON, text) with retries
########################################
CURL_OPTS=( -sSL --fail-with-body -H "User-Agent: ${USER_AGENT}" )

_backoff_sleep() { local n=$1; sleep $(( (2**n) )); }

curl_json() {
  local url=$1 try rc body hdr
  hdr="$TMP_ROOT/hdr.$$"
  for try in $(seq 0 $RETRY_MAX); do
    body=$(curl "${CURL_OPTS[@]}" -D "$hdr" -H "Accept: application/vnd.github+json" \
           ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} -o - "$url" 2>/dev/null) && rc=0 || rc=$?
    # Rate-limit handling
    if (( rc==0 )) && grep -qi '^HTTP/.* 403' "$hdr" && grep -qi '^x-ratelimit-remaining: 0' "$hdr"; then
      local wait
      wait=$(awk -F': ' 'tolower($1)=="retry-after"{print int($2)}' "$hdr")
      ((wait>0)) || wait=60
      warn "GitHub rate-limited; sleeping ${wait}s…"
      sleep "$wait"
      continue
    fi
    if (( rc==0 )); then printf '%s' "$body"; return 0; fi
    (( try<RETRY_MAX )) && _backoff_sleep "$try" || return "$rc"
  done
}

curl_text() { curl "${CURL_OPTS[@]}" "$1"; }

########################################
# ETag cache
########################################
_cache_get()  { local k=$1; [[ -f "$CACHE_DIR/$k.json" ]] && cat "$CACHE_DIR/$k.json"; }
_cache_etag() { local k=$1; [[ -f "$CACHE_DIR/$k.etag" ]] && cat "$CACHE_DIR/$k.etag"; }

gh_cached() {
  local key=$1 url=$2 etag opt hdr body
  etag=$(_cache_etag "$key")
  [[ -n "$etag" ]] && opt=(-H "If-None-Match: $etag") || opt=()
  hdr="$TMP_ROOT/h.$$"
  body=$(curl "${CURL_OPTS[@]}" -D "$hdr" -H "Accept: application/vnd.github+json" "${opt[@]}" \
         ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} -o - "$url") || return $?
  if grep -qi '^HTTP/.* 304' "$hdr"; then _cache_get "$key"; return 0; fi
  printf '%s' "$body" >"$CACHE_DIR/$key.json"
  awk -F': ' 'tolower($1)=="etag"{print $2}' "$hdr" | tr -d '\r' >"$CACHE_DIR/$key.etag" || true
  printf '%s' "$body"
}

########################################
# README parser → "name|url|version"
########################################
extract_mods() {
  curl_text "$README_URL" | awk '
    BEGIN { FS="|"; inT=0; }
    /(^|\|)[[:space:]]*Mod[[:space:]]*\|[[:space:]]*Version/ { inT=1; next }
    inT==1 && /^[[:space:]]*\|[[:space:]]*[-]+[[:space:]]*\|/ { next }
    inT==1 && NF>=3 {
      nameCol=$2; verCol=$3;
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", nameCol);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", verCol);
      match(nameCol, /\[([^]]+)\]\(([^)]+)\)/, m); if (!m[1] || !m[2]) next;
      modName=m[1]; modURL=m[2];
      match(verCol, /`([^`]+)`/, v); modVersion=(v[1] ? v[1] : verCol);
      print modName "|" modURL "|" modVersion
    }
    inT==1 && /^[[:space:]]*$/ { exit }
  '
}

########################################
# GitHub helpers
########################################
repo_slug_from_url() {
  local u=$1; [[ "$u" == *"github.com"* ]] || { echo ""; return; }
  u="${u#*github.com/}"; u="${u%/}"; echo "$u" | awk -F'/' '{print $1 "/" $2}'
}

gh_latest_version() {
  local slug="$1" rel tags tag
  rel="$(gh_cached "rel_${slug//\//_}" "https://api.github.com/repos/${slug}/releases/latest" 2>/dev/null || true)"
  tag="$(printf '%s\n' "$rel" | awk -F'"' '/"tag_name":/ {print $4; exit}')"
  if [[ -n "$tag" ]]; then printf '%s\n' "${tag#v}"; return 0; fi
  tags="$(gh_cached "tags_${slug//\//_}" "https://api.github.com/repos/${slug}/tags?per_page=1" 2>/dev/null || true)"
  tag="$(printf '%s\n' "$tags" | awk -F'"' '/"name":/ {print $4; exit}')"
  [[ -n "$tag" ]] && printf '%s\n' "${tag#v}" || return 1
}

gh_last_updated() {
  local slug="$1" commits
  commits="$(gh_cached "comm_${slug//\//_}" "https://api.github.com/repos/${slug}/commits?per_page=1" 2>/dev/null)" || return 1
  printf '%s' "$commits" | awk -F'"' '/"date":/ {print $4; exit}'
}

gh_latest_asset_urls() {
  local slug="$1"
  gh_cached "assets_${slug//\//_}" "https://api.github.com/repos/${slug}/releases/latest" \
    | awk -F'"' '/"browser_download_url":/ {print $4}'
}

########################################
# Metamod (non-GitHub) version probe
########################################
metamod_latest() {
  local url="$1" page
  page="$(curl_text "$url" || true)"
  echo "$page" | grep -o "mmsource-[0-9.]*-git[0-9]*-linux\.tar\.gz" \
    | sed -E 's/mmsource-([0-9.]+)-git([0-9]+)-linux\.tar\.gz/\1-\2/' \
    | head -n1
}

########################################
# SemVer-ish compare via sort -V
# prints: -1 if a<b, 0 if =, 1 if a>b
########################################
semver_cmp() {
  local a="${1#v}" b="${2#v}"
  [[ "$a" == "$b" ]] && { echo 0; return; }
  if printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1 | grep -qx "$a"; then
    echo -1
  else
    echo 1
  fi
}

########################################
# Checksums (best-effort)
########################################
have_sha256=1; command -v sha256sum >/dev/null || have_sha256=0

verify_checksum_for_asset() {
  (( have_sha256 )) || return 1
  local file="$1" url="$2" base sha ok=1
  base="${url##*/}"
  for s in "${url}.sha256" "${url}.sha256sum" "${url}.sha256.txt"; do
    if curl -sSL --fail-with-body -o "$TMP_ROOT/checksum" "$s"; then
      ( cd "$(dirname "$file")" && sha256sum -c <(sed "s|^\([0-9a-fA-F]\+\)\s\+\*\?.*|\1  ${base}|" "$TMP_ROOT/checksum") ) && ok=0 && break
    fi
  done
  return $ok
}

########################################
# Download/extract one GitHub repo (subcommand)
########################################
do_download_one() {
  local slug="$1" filter="$2" dry="$3" nox="$4" only="$5" dest_root="$6"
  local urls name file dl_dir dest
  urls="$(gh_latest_asset_urls "$slug" || true)"
  [[ -z "$urls" ]] && { warn "No assets in latest release for $slug"; return 0; }
  dl_dir="$TMP_ROOT/downloads/${slug}"
  dest="${dest_root%/}/${slug}"
  mkdir -p "$dl_dir" "$dest"

  # Filter assets by OS hint
  mapfile -t chosen < <(
    while IFS= read -r u; do
      case "$filter" in
        linux)   [[ "$u" == *linux* ]] && echo "$u" ;;
        windows) [[ "$u" == *windows* ]] && echo "$u" ;;
        all)     echo "$u" ;;
      esac
    done <<<"$urls"
  )
  ((${#chosen[@]})) || { warn "Assets exist but none match --filter=$filter for $slug"; return 0; }

  for url in "${chosen[@]}"; do
    name="${url##*/}"
    file="$dl_dir/$name"
    if [[ -f "$file" ]]; then
      log "Already downloaded: $name"
    else
      if (( dry )); then
        echo "DRY-RUN: would download $url"
      else
        log "Downloading $name"
        curl -L "${CURL_OPTS[@]}" -o "$file" "$url"
        verify_checksum_for_asset "$file" "$url" && log "Checksum OK for $name" || true
      fi
    fi

    (( only )) && continue
    (( nox )) && continue

    if (( dry )); then
      echo "DRY-RUN: would extract $file -> $dest"
    else
      log "Extracting $name"
      case "$file" in
        *.tar.gz|*.tgz) tar --overwrite -xzf "$file" -C "$dest" >/dev/null ;;
        *.zip)          command -v unzip >/dev/null && unzip -o "$file" -d "$dest" >/dev/null || warn "unzip not installed" ;;
        *)              warn "Unsupported archive: $name" ;;
      esac
    fi
  done
}

########################################
# Report
########################################
REPORT_ITEMS=()
report_add() { # type name version latest url status
  REPORT_ITEMS+=("{\"type\":\"$1\",\"name\":\"$2\",\"version\":\"$3\",\"latest\":\"$4\",\"url\":\"$5\",\"status\":\"$6\"}")
}
report_flush() {
  [[ -z "$REPORT_PATH" ]] && return 0
  printf '[\n  %s\n]\n' "$(IFS=,; echo "${REPORT_ITEMS[*]}")" > "$REPORT_PATH"
  log "Wrote report to $REPORT_PATH"
}

########################################
# CLI
########################################
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --readme URL         README URL (default: $README_URL)
  --dest DIR           Extraction root (default: $DEST_ROOT)
  --filter OS          linux|windows|all (default: $FILTER_OS)
  --concurrency N      Parallel downloads (default: $CONCURRENCY)
  --dry-run            Show actions, no writes
  --no-extract         Download but do not extract
  --only-download      Only download; skip extraction + status messages
  --no-color           Disable colored output
  --report FILE        Write JSON summary to FILE
  -h, --help           Show help

Env:
  GITHUB_TOKEN         Optional; raises GitHub API rate limits
  README_URL, DEST_ROOT, FILTER_OS, CONCURRENCY, DRY_RUN, NO_EXTRACT, ONLY_DOWNLOAD, COLOR, REPORT_PATH

EOF
}

if [[ "${1:-}" == "__download__" ]]; then
  # subcommand used for parallel workers
  do_download_one "$2" "$3" "$4" "$5" "$6" "$7"
  exit 0
fi

# parse flags
while (($#)); do
  case "$1" in
    --readme) README_URL="$2"; shift ;;
    --dest) DEST_ROOT="$2"; shift ;;
    --filter) FILTER_OS="$2"; shift ;;
    --concurrency) CONCURRENCY="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --no-extract) NO_EXTRACT=1 ;;
    --only-download) ONLY_DOWNLOAD=1 ;;
    --no-color) COLOR=0 ;;
    --report) REPORT_PATH="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown arg: $1" ;;
  esac
  shift
done

########################################
# Main
########################################
main() {
  command -v curl >/dev/null || die "curl required"
  command -v awk  >/dev/null || die "awk required"
  command -v sort >/dev/null || die "coreutils sort required"

  mapfile -t mods < <(extract_mods || true)
  ((${#mods[@]})) || die "Could not parse mods from README: $README_URL"

  TASKS_FILE="$TMP_ROOT/tasks.txt"; : >"$TASKS_FILE"

  for line in "${mods[@]}"; do
    IFS='|' read -r name url version <<<"$line"
    [[ -n "$name" && -n "$url" && -n "$version" ]] || continue

    if [[ "$url" == *"metamodsource.net"* ]]; then
      latest="$(metamod_latest "$url" || true)"
      if [[ -n "$latest" ]]; then
        cmp=$(semver_cmp "$version" "$latest")
        if [[ "$cmp" == "0" ]]; then
          printf '%b%s %s %s%b\n' "$C_GREEN" "$ICON_OK" "$name" "$version" "$C_RESET"
          report_add "metamod" "$name" "$version" "$latest" "$url" "up-to-date"
        else
          printf '%b%s %s update available %s > %s %s%b\n' "$C_YELLOW" "$ICON_PKG" "$name" "$version" "$latest" "$url" "$C_RESET"
          report_add "metamod" "$name" "$version" "$latest" "$url" "update"
          # downloader is GitHub-centric; we still print status here
        fi
      else
        printf '%b%s %s %s - Could not detect latest version %s%b\n' "$C_RED" "$ICON_ERR" "$name" "$version" "$url" "$C_RESET"
        report_add "metamod" "$name" "$version" "" "$url" "unknown"
      fi
      continue
    fi

    slug="$(repo_slug_from_url "$url")"
    if [[ -z "$slug" ]]; then
      printf '%b%s %s %s - Unsupported URL %s%b\n' "$C_RED" "$ICON_ERR" "$name" "$version" "$url" "$C_RESET"
      report_add "other" "$name" "$version" "" "$url" "unsupported"
      continue
    fi

    latest="$(gh_latest_version "$slug" || true)"
    if [[ -n "$latest" ]]; then
      cmp=$(semver_cmp "$version" "$latest")
      if [[ "$cmp" == "0" ]]; then
        printf '%b%s %s %s%b\n' "$C_GREEN" "$ICON_OK" "$name" "$version" "$C_RESET"
        report_add "github" "$name" "$version" "$latest" "https://github.com/$slug" "up-to-date"
      else
        printf '%b%s %s update available %s > %s https://github.com/%s%b\n' \
          "$C_YELLOW" "$ICON_PKG" "$name" "$version" "$latest" "$slug" "$C_RESET"
        report_add "github" "$name" "$version" "$latest" "https://github.com/$slug" "update"
        # Queue parallel download (workers call this same script with __download__)
        printf '%s|%s\n' "$slug" "$FILTER_OS" >>"$TASKS_FILE"
      fi
    else
      updated="$(gh_last_updated "$slug" || true)"
      if [[ -n "$updated" ]]; then
        printf '%b%s %s %s - Last updated %s https://github.com/%s%b\n' \
          "$C_GRAY" "$ICON_SCAN" "$name" "$version" "$updated" "$slug" "$C_RESET"
        report_add "github" "$name" "$version" "" "https://github.com/$slug" "no-release"
      else
        printf '%b%s %s %s - Could not find latest version or last update https://github.com/%s%b\n' \
          "$C_RED" "$ICON_ERR" "$name" "$version" "$slug" "$C_RESET"
        report_add "github" "$name" "$version" "" "https://github.com/$slug" "unknown"
      fi
    fi
  done

  # Run downloads in parallel (if any)
  if [[ -s "$TASKS_FILE" ]]; then
    export -f do_download_one
    export -f gh_latest_asset_urls verify_checksum_for_asset log warn
    export -f repo_slug_from_url
    export USER_AGENT GITHUB_TOKEN TMP_ROOT COLOR
    export -f curl_json curl_text
    # pass flags to workers
    xargs -P "$CONCURRENCY" -n1 -I{} bash -c \
      '$0 __download__ "$(cut -d"|" -f1 <<< "{}")" "$(cut -d"|" -f2 <<< "{}")" "'"$DRY_RUN"'" "'"$NO_EXTRACT"'" "'"$ONLY_DOWNLOAD"'" "'"$DEST_ROOT"'"' \
      "$0" < "$TASKS_FILE"
  fi

  report_flush
  log "Done."
}

main
