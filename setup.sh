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

# Pinned versions. The backend is NATIVE Paper 1.8.8 (Java 8) so Eaglercraft 1.8
# clients render the world directly — no ViaVersion translation (that was causing
# the chunk/FPS rendering problems). The proxy/EaglerXServer runs on Java 21.
ESS_VER="2.19.7"       # last EssentialsX with 1.8 support
EAGLER_TAG="v1.1.0"

say() { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
dl()  { # dl <url> <dest>
  if [ -s "$2" ]; then echo "  exists: $(basename "$2")"; return; fi
  echo "  downloading $(basename "$2") ..."
  curl -fsSL -A "Mozilla/5.0" -o "$2" "$1"
}

mkdir -p "$RUNTIME" "$SMP/plugins" "$SMP/config" "$BUNGEE/plugins" \
         "$ROOT/data/worlds"

# --- 1. Java runtimes (21 for the proxy, 8 for the 1.8.8 backend) -----------
say "Java runtimes"
if ! ls "$RUNTIME"/jdk-21* >/dev/null 2>&1; then
  dl "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jre/hotspot/normal/eclipse" "$RUNTIME/jdk21.tar.gz"
  tar xzf "$RUNTIME/jdk21.tar.gz" -C "$RUNTIME"; rm -f "$RUNTIME/jdk21.tar.gz"
fi
if ! ls "$RUNTIME"/jdk8u* >/dev/null 2>&1; then
  dl "https://api.adoptium.net/v3/binary/latest/8/ga/linux/x64/jre/hotspot/normal/eclipse" "$RUNTIME/jdk8.tar.gz"
  tar xzf "$RUNTIME/jdk8.tar.gz" -C "$RUNTIME"; rm -f "$RUNTIME/jdk8.tar.gz"
fi
echo "  java21: $(ls -d "$RUNTIME"/jdk-21*/bin/java | head -1)"
echo "  java8:  $(ls -d "$RUNTIME"/jdk8u*/bin/java | head -1)"

# --- 2. Paper 1.8.8 backend (native 1.8, no Via) ---------------------------
say "Paper 1.8.8 backend"
PURL=$(curl -fsSL -A "EagleCraft/1.0" "https://mcjars.app/api/v2/builds/SPIGOT/1.8.8" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['builds'][0]['jarUrl'])")
dl "$PURL" "$SMP/paper.jar"

# --- 3. BungeeCord proxy ---------------------------------------------------
say "BungeeCord proxy"
dl "https://ci.md-5.net/job/BungeeCord/lastSuccessfulBuild/artifact/bootstrap/target/BungeeCord.jar" "$BUNGEE/BungeeCord.jar"

# --- 4. Plugins ------------------------------------------------------------
say "Plugins"
# EaglerXServer on the proxy (Java 21); EssentialsX 2.19.7 on the 1.8.8 backend.
dl "https://github.com/lax1dude/eaglerxserver/releases/download/$EAGLER_TAG/EaglerXServer.jar"     "$BUNGEE/plugins/EaglerXServer.jar"
dl "https://github.com/EssentialsX/Essentials/releases/download/$ESS_VER/EssentialsX-$ESS_VER.jar"  "$SMP/plugins/EssentialsX-$ESS_VER.jar"

# --- 5. Configs (known-good) ----------------------------------------------
say "Configs"
cp -n smp-config/server.properties    "$SMP/server.properties"
cp -n smp-config/spigot.yml           "$SMP/spigot.yml"
cp -n smp-config/bukkit.yml           "$SMP/bukkit.yml"
cp -n smp-config/eula.txt             "$SMP/eula.txt"
cp -n smp-config/permissions.yml      "$SMP/permissions.yml"
mkdir -p "$SMP/plugins/Essentials"
cp -n smp-config/essentials-config.yml "$SMP/plugins/Essentials/config.yml"
cp -n bungee-config/config.yml        "$BUNGEE/config.yml"
echo "  configs in place (eula, bungee/offline mode, economy, perms)."

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
