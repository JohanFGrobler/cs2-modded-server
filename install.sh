#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# cs2-modded-server installer/runner (JohanFGrobler fork)
#
# Typical usage on a box where this repo is already checked out to /cs2:
#   cd /cs2 && git pull --rebase --autostash
#   chmod +x install.sh
#   sudo -E LOCAL_SOURCE_DIR=/cs2 ./install.sh
#
# First-time bootstrap (no repo on the box yet):
#   cd / && curl -s -H "Cache-Control: no-cache" \
#     -o install.sh \
#     https://raw.githubusercontent.com/JohanFGrobler/cs2-modded-server/master/install.sh \
#     && chmod +x install.sh && sudo -E ./install.sh
# -----------------------------------------------------------------------------

user="steam"
BRANCH="${MOD_BRANCH:-master}"
CUSTOM_FILES="${CUSTOM_FOLDER:-custom_files}"     # active custom set under /home/steam/cs2/ (optional)
LOCAL_SOURCE_DIR="${LOCAL_SOURCE_DIR:-}"          # set to your repo path to force local copy (e.g. /cs2)

# ----- detect 32/64-bit -----
if [ -z "${BITS:-}" ]; then
  arch="$(uname -m || true)"
  case "$arch" in
    *64*)  BITS=64 ;;
    *86*|*i386*|*i686*) BITS=32 ;;
    *) echo "Unknown architecture: $arch"; exit 1 ;;
  esac
fi

# ----- optional bind IP -----
IP_ARGS=""
[ -n "${IP:-}" ] && IP_ARGS="-ip ${IP}"

# ----- distro info (for logs) -----
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO_OS=$NAME
  DISTRO_VERSION=$VERSION_ID
else
  DISTRO_OS="$(uname -s)"
  DISTRO_VERSION="$(uname -r)"
fi

echo "Starting on ${DISTRO_OS}: ${DISTRO_VERSION}..."
FREE_SPACE="$(df / --output=avail -BG | tail -n1 | tr -d 'G' || echo '?')"
echo "With ${FREE_SPACE} Gb free space..."

command -v apt-get >/dev/null || { echo "ERROR: apt-get missing"; exit 1; }
[ "$EUID" -eq 0 ] || { echo "ERROR: Run this script as root (sudo)."; exit 1; }

echo "Updating Operating System..."
apt-get update -y -q && apt-get upgrade -y -q >/dev/null || { echo "ERROR: Updating Operating System..."; exit 1; }
dpkg --configure -a >/dev/null || true

echo "Adding i386 architecture (for Steam runtime)…"
dpkg --add-architecture i386 >/dev/null || true

echo "Installing required packages…"
apt-get update -y -q >/dev/null
apt-get install -y -q \
  dnsutils curl wget screen nano file tar bzip2 gzip unzip hostname bsdmainutils python3 util-linux \
  xz-utils ca-certificates binutils bc jq tmux netcat-traditional lib32stdc++6 libsdl2-2.0-0:i386 \
  distro-info lib32gcc-s1 steamcmd >/dev/null

# ----- start/stop scripts: prefer local from this repo; fallback to GitHub -----
if [ -f "./start.sh" ] && [ -f "./stop.sh" ]; then
  echo "Using local start.sh/stop.sh from repo."
  chmod +x ./start.sh ./stop.sh
else
  echo "Local start/stop not found; fetching from GitHub (${BRANCH})."
  curl -s -H "Cache-Control: no-cache" \
    -o "stop.sh"  "https://raw.githubusercontent.com/JohanFGrobler/cs2-modded-server/${BRANCH}/stop.sh"
  curl -s -H "Cache-Control: no-cache" \
    -o "start.sh" "https://raw.githubusercontent.com/JohanFGrobler/cs2-modded-server/${BRANCH}/start.sh"
  chmod +x start.sh stop.sh
fi

# ----- public IP (for log only) -----
PUBLIC_IP="$(dig -4 +short myip.opendns.com @resolver1.opendns.com || true)"
[ -n "${PUBLIC_IP}" ] || PUBLIC_IP="unknown"

# optional DuckDNS update
if [ -n "${DUCK_TOKEN:-}" ] && [ -n "${DUCK_DOMAIN:-}" ]; then
  echo url="http://www.duckdns.org/update?domains=$DUCK_DOMAIN&token=$DUCK_TOKEN&ip=$PUBLIC_IP" | curl -k -o /duck.log -K -
fi

# ----- steam user -----
echo "Ensuring '${user}' system user exists…"
if ! id "${user}" >/dev/null 2>&1; then
  addgroup "${user}"
  adduser --system --home "/home/${user}" --shell /bin/false --ingroup "${user}" "${user}"
  usermod -a -G tty "${user}"
  mkdir -m 777 -p "/home/${user}/cs2"
  chown -R "${user}:${user}" "/home/${user}/cs2"
fi

# ----- steamcmd & sdk links -----
echo "Checking steamcmd…"
if [ ! -d "/steamcmd" ]; then
  mkdir /steamcmd && cd /steamcmd
  wget -q https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
  tar -xzf steamcmd_linux.tar.gz
  mkdir -p /root/.steam/sdk32/ /root/.steam/sdk64/
  ln -sf /steamcmd/linux32/steamclient.so /root/.steam/sdk32/
  ln -sf /steamcmd/linux64/steamclient.so /root/.steam/sdk64/
fi
chown -R "${user}:${user}" /steamcmd

echo "Updating CS2 dedicated server via steamcmd…"
sudo -u "${user}" /steamcmd/steamcmd.sh \
  +api_logging 1 1 \
  +@sSteamCmdForcePlatformType linux \
  +@sSteamCmdForcePlatformBitness "${BITS}" \
  +force_install_dir "/home/${user}/cs2" \
  +login anonymous \
  +app_update 730 \
  +quit

# runtime expects steamclient in home too
cd "/home/${user}"
mkdir -p "/home/${user}/.steam/sdk32/" "/home/${user}/.steam/sdk64/"
ln -sf /steamcmd/linux32/steamclient.so "/home/${user}/.steam/sdk32/"
ln -sf /steamcmd/linux64/steamclient.so "/home/${user}/.steam/sdk64/"

# wipe merged areas so deletions in repo apply
rm -rf "/home/${user}/cs2/game/csgo/addons" || true
rm -rf "/home/${user}/cs2/game/csgo/cfg/settings" || true

# ====== choose mod source: local repo preferred, otherwise download ZIP ======
echo "Selecting source for mod files…"
SRC_DIR=""
if [ -n "${LOCAL_SOURCE_DIR}" ] && [ -d "${LOCAL_SOURCE_DIR}/game/csgo" ]; then
  SRC_DIR="${LOCAL_SOURCE_DIR}"
elif [ -d "./game/csgo" ] && [ -f "./install.sh" ]; then
  SRC_DIR="$(pwd)"
else
  echo "No local source; downloading ZIP from GitHub (${BRANCH})…"
  TMPDIR="$(mktemp -d)"
  cd "$TMPDIR"
  wget --quiet "https://github.com/JohanFGrobler/cs2-modded-server/archive/${BRANCH}.zip"
  unzip -o -qq "${BRANCH}.zip"
  SRC_DIR="${TMPDIR}/cs2-modded-server-${BRANCH}"
fi
echo "Using source: ${SRC_DIR}"

# copy example files if present (for admins to copy from later)
if [ -d "${SRC_DIR}/custom_files_example" ]; then
  rm -rf "/home/${user}/cs2/custom_files_example/" || true
  cp -R "${SRC_DIR}/custom_files_example/" "/home/${user}/cs2/custom_files_example/"
fi

# overlay the repo's game content
cp -R "${SRC_DIR}/game/csgo/" "/home/${user}/cs2/game/"

# seed/refresh /home/steam/cs2/custom_files **only if the repo actually has it**
if [ -d "${SRC_DIR}/custom_files" ]; then
  if [ ! -d "/home/${user}/cs2/custom_files/" ]; then
    cp -R "${SRC_DIR}/custom_files/" "/home/${user}/cs2/custom_files/"
  else
    cp -RT "${SRC_DIR}/custom_files/" "/home/${user}/cs2/custom_files/"
  fi
else
  echo "Note: '${SRC_DIR}/custom_files' not present — skipping seed/refresh."
fi

# final merge of the currently active custom set into the live game tree
if [ -d "/home/${user}/cs2/${CUSTOM_FILES}/" ]; then
  echo "Merging active custom set: ${CUSTOM_FILES}"
  cp -RT "/home/${user}/cs2/${CUSTOM_FILES}/" "/home/${user}/cs2/game/csgo/"
else
  echo "Active custom set '${CUSTOM_FILES}' not found under /home/${user}/cs2 — skipping."
fi

# clean any temp download
if [ -n "${TMPDIR:-}" ] && [[ "${SRC_DIR}" == "${TMPDIR}/"* ]]; then
  rm -rf "${TMPDIR}"
fi

# ownership
chown -R "${user}:${user}" "/home/${user}/cs2"

# patch gameinfo.gi so Metamod loads
FILE="/home/${user}/cs2/game/csgo/gameinfo.gi"
PATTERN="Game_LowViolence[[:space:]]*csgo_lv // Perfect World content override"
LINE_TO_ADD=$'\t\t\tGame\tcsgo/addons/metamod'
if ! grep -qE '^[[:space:]]*Game[[:space:]]*csgo/addons/metamod' "$FILE"; then
  awk -v pattern="$PATTERN" -v lineToAdd="$LINE_TO_ADD" '{
    print $0;
    if ($0 ~ pattern) print lineToAdd;
  }' "$FILE" > "${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
  echo "gameinfo.gi successfully patched for Metamod."
else
  echo "gameinfo.gi already patched for Metamod."
fi

# ----- launch server -----
echo "Starting server on ${PUBLIC_IP}:${PORT:-27015}"
cd "/home/${user}/cs2"

# Show the command for transparency
echo ./game/bin/linuxsteamrt64/cs2 \
  -dedicated -console -usercon -autoupdate \
  -tickrate "${TICKRATE:-128}" \
  ${IP_ARGS} \
  -port "${PORT:-27015}" \
  +map de_dust2 \
  +sv_visiblemaxplayers "${MAXPLAYERS:-24}" \
  -authkey "${API_KEY:-}" \
  +sv_setsteamaccount "${STEAM_ACCOUNT:-}" \
  +game_type 0 +game_mode 0 +mapgroup mg_active \
  +sv_lan "${LAN:-0}" \
  +sv_password "${SERVER_PASSWORD:-}" \
  +rcon_password "${RCON_PASSWORD:-}" \
  +exec "${EXEC:-}"

# Replace this process with the server as steam user
exec sudo -u "${user}" ./game/bin/linuxsteamrt64/cs2 \
  -dedicated -console -usercon -autoupdate \
  -tickrate "${TICKRATE:-128}" \
  ${IP_ARGS} \
  -port "${PORT:-27015}" \
  +map de_dust2 \
  +sv_visiblemaxplayers "${MAXPLAYERS:-24}" \
  -authkey "${API_KEY:-}" \
  +sv_setsteamaccount "${STEAM_ACCOUNT:-}" \
  +game_type 0 +game_mode 0 +mapgroup mg_active \
  +sv_lan "${LAN:-0}" \
  +sv_password "${SERVER_PASSWORD:-}" \
  +rcon_password "${RCON_PASSWORD:-}" \
  +exec "${EXEC:-}"
