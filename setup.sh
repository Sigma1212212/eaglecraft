#!/usr/bin/env bash
# ===========================================================================
#  EagleCraft — one-shot installer
#  Downloads the Java runtime, the SMP server stack, and all plugins, then
#  drops the known-good configs into place. Re-runnable (skips existing files).
#
#  Usage:   bash setup.sh
#  After:   bash start.sh
# ===========================================================================
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
RUNTIME="$ROOT/runtime"
SMP="$ROOT/data/smp"
BUNGEE="$ROOT/data/bungee"

# Pinned versions (the combo verified to work: EaglerXServer needs a pre-1.20.5
# Paper because of the Mojang-mappings break).
PAPER_VER="1.20.4"
ESS_VER="2.22.0"
VIA_VER="5.9.1"
VIABACK_VER="5.9.1"
VIAREWIND_VER="4.1.1"
EAGLER_TAG="v1.1.0"

say() { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
dl()  { # dl <url> <dest>
  if [ -s "$2" ]; then echo "  exists: $(basename "$2")"; return; fi
  echo "  downloading $(basename "$2") ..."
  curl -fsSL -A "Mozilla/5.0" -o "$2" "$1"
}

mkdir -p "$RUNTIME" "$SMP/plugins" "$SMP/config" "$BUNGEE/plugins" \
         "$ROOT/data/worlds"

# --- 1. Java 21 runtime ----------------------------------------------------
say "Java 21 runtime"
if ls "$RUNTIME"/jdk-21* >/dev/null 2>&1; then
  echo "  Java already present."
else
  dl "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jre/hotspot/normal/eclipse" "$RUNTIME/jdk21.tar.gz"
  tar xzf "$RUNTIME/jdk21.tar.gz" -C "$RUNTIME"
  rm -f "$RUNTIME/jdk21.tar.gz"
fi
JAVA="$(ls -d "$RUNTIME"/jdk-21*/bin/java | head -1)"
echo "  java: $JAVA"
"$JAVA" -version

# --- 2. Paper backend ------------------------------------------------------
say "Paper $PAPER_VER backend"
PBUILD=$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/$PAPER_VER/builds" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['builds'][-1]['build'])")
dl "https://api.papermc.io/v2/projects/paper/versions/$PAPER_VER/builds/$PBUILD/downloads/paper-$PAPER_VER-$PBUILD.jar" "$SMP/paper.jar"

# --- 3. BungeeCord proxy ---------------------------------------------------
say "BungeeCord proxy"
dl "https://ci.md-5.net/job/BungeeCord/lastSuccessfulBuild/artifact/bootstrap/target/BungeeCord.jar" "$BUNGEE/BungeeCord.jar"

# --- 4. Plugins ------------------------------------------------------------
say "Plugins"
# EaglerXServer goes on the proxy; the RPC bridge + Via + Essentials on backend.
dl "https://github.com/lax1dude/eaglerxserver/releases/download/$EAGLER_TAG/EaglerXServer.jar"     "$BUNGEE/plugins/EaglerXServer.jar"
dl "https://github.com/lax1dude/eaglerxserver/releases/download/$EAGLER_TAG/EaglerXBackendRPC.jar" "$SMP/plugins/EaglerXBackendRPC.jar"
dl "https://github.com/EssentialsX/Essentials/releases/download/$ESS_VER/EssentialsX-$ESS_VER.jar"  "$SMP/plugins/EssentialsX-$ESS_VER.jar"
dl "https://github.com/ViaVersion/ViaVersion/releases/download/$VIA_VER/ViaVersion-$VIA_VER.jar"           "$SMP/plugins/ViaVersion-$VIA_VER.jar"
dl "https://github.com/ViaVersion/ViaBackwards/releases/download/$VIABACK_VER/ViaBackwards-$VIABACK_VER.jar" "$SMP/plugins/ViaBackwards-$VIABACK_VER.jar"
dl "https://github.com/ViaVersion/ViaRewind/releases/download/$VIAREWIND_VER/ViaRewind-$VIAREWIND_VER.jar"   "$SMP/plugins/ViaRewind-$VIAREWIND_VER.jar"

# Donut-style extras (RTP, /menu GUI) via Modrinth — latest 1.20.4 build.
UA="EagleCraft/1.0 (setup)"
modrinth() {  # modrinth <slug> <dest>
  [ -s "$2" ] && { echo "  exists: $(basename "$2")"; return; }
  local u
  u=$(curl -fsSL -A "$UA" "https://api.modrinth.com/v2/project/$1/version" | python3 -c "
import sys,json
for v in json.load(sys.stdin):
    if {'paper','spigot','bukkit','purpur'} & set(v.get('loaders',[])) and '1.20.4' in v.get('game_versions',[]):
        f=[x for x in v['files'] if x.get('primary')] or v['files']; print(f[0]['url']); break
" 2>/dev/null)
  [ -n "$u" ] && curl -fsSL -A "$UA" -o "$2" "$u" && echo "  got $(basename "$2")" || echo "  !! could not fetch $1"
}
modrinth placeholderapi  "$SMP/plugins/PlaceholderAPI.jar"   # required by DeluxeMenus
modrinth deluxemenus     "$SMP/plugins/DeluxeMenus.jar"      # the /menu GUI
modrinth random_teleport "$SMP/plugins/random_teleport.jar"  # /rtp

# --- 5. Configs (known-good) ----------------------------------------------
say "Configs"
cp -n smp-config/server.properties    "$SMP/server.properties"
cp -n smp-config/spigot.yml           "$SMP/spigot.yml"
cp -n smp-config/bukkit.yml           "$SMP/bukkit.yml"
cp -n smp-config/paper-global.yml     "$SMP/config/paper-global.yml"
cp -n smp-config/eula.txt             "$SMP/eula.txt"
cp -n smp-config/permissions.yml      "$SMP/permissions.yml"
mkdir -p "$SMP/plugins/Essentials"
cp -n smp-config/essentials-config.yml "$SMP/plugins/Essentials/config.yml"
mkdir -p "$SMP/plugins/DeluxeMenus/gui_menus"
cp -n smp-config/deluxemenus-config.yml "$SMP/plugins/DeluxeMenus/config.yml"
cp -n smp-config/deluxemenus-main.yml   "$SMP/plugins/DeluxeMenus/gui_menus/main.yml"
cp -n bungee-config/config.yml        "$BUNGEE/config.yml"
echo "  configs in place (eula, bungee/offline/economy, /menu, perms)."

# --- 6. Eaglercraft client -------------------------------------------------
say "Eaglercraft client"
if [ -s "$ROOT/web/eaglercraft/index.html" ]; then
  echo "  client already present ($(wc -c <"$ROOT/web/eaglercraft/index.html") bytes)."
else
  echo "  !! web/eaglercraft/index.html missing."
  echo "     Drop an EaglercraftX 1.8 offline .html there as index.html."
fi

# --- 7. Games site (Gams-Offline/Gams, ~1.6 GB) ---------------------------
say "Games site"
if [ -f "$ROOT/web/games/Gams.html" ]; then
  echo "  games already present."
elif command -v git >/dev/null 2>&1; then
  echo "  cloning Gams-Offline/Gams (large, be patient)…"
  rm -rf "$ROOT/web/games"
  git clone --depth 1 https://github.com/Gams-Offline/Gams.git "$ROOT/web/games"
  rm -rf "$ROOT/web/games/.git"
else
  echo "  !! git not found — install git, then re-run to fetch the games."
fi

say "Done. Boot it with:  bash start.sh"
