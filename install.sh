#!/usr/bin/env bash
set -euo pipefail

# As root:
# cd / && curl -s -H "Cache-Control: no-cache" \
#   -o "install.sh" "https://raw.githubusercontent.com/JohanFGrobler/cs2-modded-server/master/install.sh" \
#   && chmod +x install.sh && bash install.sh

user="steam"
BRANCH="${MOD_BRANCH:-master}"
CUSTOM_FILES="${CUSTOM_FOLDER:-custom_files}"

# bits
if [ -z "${BITS:-}" ]; then
  arch=$(uname -m)
  if [[ "$arch" == *"64"* ]]; then BITS=64; elif [[ "$arch" == *"86"* ]]; then BITS=32; else echo "Unknown arch: $arch"; exit 1; fi
fi

IP_ARGS=""
[ -n "${IP:-}" ] && IP_ARGS="-ip ${IP}"

# distro
if [ -f /etc/os-release ]; then . /etc/os-release; DISTRO_OS=$NAME; DISTRO_VERSION=$VERSION_ID; else DISTRO_OS=$(uname -s); DISTRO_VERSION=$(uname -r); fi
echo "Starting on $DISTRO_OS: $DISTRO_VERSION..."
FREE_SPACE=$(df / --output=avail -BG | tail -n 1 | tr -d 'G'); echo "With $FREE_SPACE Gb free space..."

command -v apt-get >/dev/null || { echo "ERROR: apt-get missing"; exit 1; }
[ "$EUID" -eq 0 ] || { echo "ERROR: Run as root"; exit 1; }

echo "Updating Operating System..."
apt-get update -y -q && apt-get upgrade -y -q >/dev/null || { echo "ERROR: Updating Operating System..."; exit 1; }
dpkg --configure -a >/dev/null || true

echo "Adding i386 architecture..."
dpkg --add-architecture i386 >/dev/null || { echo "ERROR: Cannot add i386 architecture..."; exit 1; }

echo "Installing required packages..."
apt-get update -y -q >/dev/null
apt-get install -y -q dnsutils curl wget screen nano file tar bzip2 gzip unzip hostname bsdmainutils python3 util-linux xz-utils ca-certificates binutils bc jq tmux netcat-traditional lib32stdc++6 libsdl2-2.0-0:i386 distro-info lib32gcc-s1 steamcmd >/dev/null

# fetch start/stop from YOUR repo
curl -s -H "Cache-Control: no-cache" -o "stop.sh"  "https://raw.githubusercontent.com/JohanFGrobler/cs2-modded-server/${BRANCH}/stop.sh"  && chmod +x stop.sh
curl -s -H "Cache-Control: no-cache" -o "start.sh" "https://raw.githubusercontent.com/JohanFGrobler/cs2-modded-server/${BRANCH}/start.sh" && chmod +x start.sh

PUBLIC_IP=$(dig -4 +short myip.opendns.com @resolver1.opendns.com)
[ -n "$PUBLIC_IP" ] || { echo "ERROR: Cannot retrieve public IP"; exit 1; }

# optional DuckDNS
if [ -n "${DUCK_TOKEN:-}" ] && [ -n "${DUCK_DOMAIN:-}" ]; then
  echo url="http://www.duckdns.org/update?domains=$DUCK_DOMAIN&token=$DUCK_TOKEN&ip=$PUBLIC_IP" | curl -k -o /duck.log -K -
fi

echo "Checking $user user exists..."
if ! id "$user" >/dev/null 2>&1; then
  addgroup "$user"
  adduser --system --home /home/${user} --shell /bin/false --ingroup ${user} ${user}
  usermod -a -G tty ${user}
  mkdir -m 777 -p /home/${user}/cs2
  chown -R ${user}:${user} /home/${user}/cs2
fi

echo "Checking steamcmd exists..."
if [ ! -d "/steamcmd" ]; then
  mkdir /steamcmd && cd /steamcmd
  wget -q https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
  tar -xzf steamcmd_linux.tar.gz
  mkdir -p /root/.steam/sdk32/ /root/.steam/sdk64/
  ln -sf /steamcmd/linux32/steamclient.so /root/.steam/sdk32/
  ln -sf /steamcmd/linux64/steamclient.so /root/.steam/sdk64/
fi
chown -R ${user}:${user} /steamcmd

echo "Downloading any updates for CS2..."
sudo -u $user /steamcmd/steamcmd.sh \
  +api_logging 1 1 \
  +@sSteamCmdForcePlatformType linux \
  +@sSteamCmdForcePlatformBitness $BITS \
  +force_install_dir /home/${user}/cs2 \
  +login anonymous \
  +app_update 730 \
  +quit

cd /home/${user}
mkdir -p /home/${user}/.steam/sdk32/ /home/${user}/.steam/sdk64/
ln -sf /steamcmd/linux32/steamclient.so /home/${user}/.steam/sdk32/
ln -sf /steamcmd/linux64/steamclient.so /home/${user}/.steam/sdk64/

# clean old merged content
rm -rf /home/${user}/cs2/game/csgo/addons || true
rm -rf /home/${user}/cs2/game/csgo/cfg/settings || true

echo "Downloading mod files from YOUR repo..."
wget --quiet "https://github.com/JohanFGrobler/cs2-modded-server/archive/${BRANCH}.zip"
unzip -o -qq "${BRANCH}.zip"
rm -f "${BRANCH}.zip"

# copy example + game files
rm -rf /home/${user}/cs2/custom_files_example/ || true
cp -R "cs2-modded-server-${BRANCH}/custom_files_example/" /home/${user}/cs2/custom_files_example/
cp -R "cs2-modded-server-${BRANCH}/game/csgo/" /home/${user}/cs2/game/

# ensure custom_files exists and merge to repo cache
if [ ! -d "/home/${user}/cs2/custom_files/" ]; then
  cp -R "cs2-modded-server-${BRANCH}/custom_files/" /home/${user}/cs2/custom_files/
else
  cp -RT "cs2-modded-server-${BRANCH}/custom_files/" /home/${user}/cs2/custom_files/
fi

echo "Merging in custom files from ${CUSTOM_FILES}"
cp -RT "/home/${user}/cs2/${CUSTOM_FILES}/" "/home/${user}/cs2/game/csgo/"

chown -R ${user}:${user} /home/${user}/cs2
rm -rf "/home/${user}/cs2-modded-server-${BRANCH}"

# patch gameinfo.gi for Metamod
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

echo "Starting server on $PUBLIC_IP:${PORT:-27015}"
cd /home/${user}/cs2
echo ./game/bin/linuxsteamrt64/cs2 \
  -dedicated -console -usercon -autoupdate \
  -tickrate "${TICKRATE:-128}" \
  $IP_ARGS \
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

exec sudo -u $user ./game/bin/linuxsteamrt64/cs2 \
  -dedicated -console -usercon -autoupdate \
  -tickrate "${TICKRATE:-128}" \
  $IP_ARGS \
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
