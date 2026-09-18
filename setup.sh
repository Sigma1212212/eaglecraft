#!/usr/bin/env bash
# ===========================================================================
#  EagleCraft — one-shot installer  (vanilla SMP edition)
#
#  Downloads, in order:
#    1. a portable Java 21 JRE          (Adoptium, matched to this OS/arch)
#    2. Paper 1.20.4                    (PaperMC "Fill" v3 API, sha256 checked)
#    3. BungeeCord                      (md-5 CI)
#    4. EaglerXServer                   (websocket listener for browser clients)
#    5. ViaVersion + ViaBackwards + ViaRewind
#                                       (so 1.8 Eaglercraft clients speak 1.20.4)
#  then writes the low-end-client-tuned configs into their runtime directories.
#
#  There is NO economy, NO EssentialsX, NO sign shops. Pure vanilla survival.
#
#  Usage:   bash setup.sh
#           SKIP_GAMES=1 bash setup.sh      # skip the ~1.9 GB games clone
#           FORCE=1 bash setup.sh           # re-download even if files exist
#  After:   bash start.sh
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
RUNTIME="$ROOT/runtime"
SMP="$ROOT/data/smp"          # Paper backend   (127.0.0.1:25565)
BUNGEE="$ROOT/data/bungee"    # proxy           (0.0.0.0:25577, player-facing)

MC_VERSION="1.20.4"
UA="EagleCraft-setup/2.0"

# --- python (stdlib only; used for JSON parsing, zip extraction, checksums) --
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  echo "!! python3 is required (it also runs the web panel). Install it first."
  exit 1
fi

say()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m  !! %s\033[0m\n' "$1"; }

# dl <url> <dest> [sha256]
dl() {
  local url="$1" dest="$2" want="${3:-}"
  if [ -s "$dest" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "  exists: $(basename "$dest")"
    return 0
  fi
  echo "  downloading $(basename "$dest") ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -A "$UA" -o "$dest.part" "$url"
  else
    "$PY" - "$url" "$dest.part" <<'PYDL'
import sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "EagleCraft-setup/2.0"})
with urllib.request.urlopen(req, timeout=120) as r, open(sys.argv[2], "wb") as f:
    while True:
        chunk = r.read(1 << 20)
        if not chunk:
            break
        f.write(chunk)
PYDL
  fi
  if [ -n "$want" ]; then
    local got
    got="$("$PY" -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$dest.part")"
    if [ "$got" != "$want" ]; then
      rm -f "$dest.part"
      echo "!! checksum mismatch for $(basename "$dest")"
      echo "   expected $want"
      echo "   got      $got"
      exit 1
    fi
    echo "    sha256 verified"
  fi
  mv -f "$dest.part" "$dest"
}

mkdir -p "$RUNTIME" "$SMP/plugins" "$SMP/config" "$BUNGEE/plugins" "$ROOT/data/worlds" "$ROOT/logs"

# ===========================================================================
# 1. Portable Java 21 JRE  (both the proxy AND Paper 1.20.4 run on this)
# ===========================================================================
say "Java 21 runtime"
case "$(uname -s)" in
  Linux*)                  OS=linux;   EXT=tar.gz ;;
  Darwin*)                 OS=mac;     EXT=tar.gz ;;
  MINGW*|MSYS*|CYGWIN*)    OS=windows; EXT=zip    ;;
  *)                       OS=linux;   EXT=tar.gz ;;
esac
case "$(uname -m)" in
  x86_64|amd64)            ARCH=x64 ;;
  aarch64|arm64)           ARCH=aarch64 ;;
  *)                       ARCH=x64 ;;
esac
echo "  host: $OS/$ARCH"

if ls "$RUNTIME"/jdk-21* >/dev/null 2>&1 && [ "${FORCE:-0}" != "1" ]; then
  echo "  already installed"
else
  JURL="https://api.adoptium.net/v3/binary/latest/21/ga/$OS/$ARCH/jre/hotspot/normal/eclipse"
  dl "$JURL" "$RUNTIME/jre21.$EXT"
  echo "  extracting ..."
  if [ "$EXT" = "zip" ]; then
    "$PY" -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
          "$RUNTIME/jre21.$EXT" "$RUNTIME"
  else
    tar xzf "$RUNTIME/jre21.$EXT" -C "$RUNTIME"
  fi
  rm -f "$RUNTIME/jre21.$EXT"
fi

JAVA="$(ls -d "$RUNTIME"/jdk-21*/bin/java "$RUNTIME"/jdk-21*/bin/java.exe \
        "$RUNTIME"/jdk-21*/Contents/Home/bin/java 2>/dev/null | head -1 || true)"
if [ -z "$JAVA" ]; then
  warn "could not locate the extracted java binary under $RUNTIME"
else
  echo "  java: $JAVA"
  "$JAVA" -version 2>&1 | head -1 | sed 's/^/        /'
fi

# ===========================================================================
# 2. Paper 1.20.4
#
#  Why 1.20.4 exactly: EaglerXServer's Bukkit module breaks on Paper >= 1.20.5
#  (Mojang mappings), so 1.20.4 is the newest backend that works. Paper 1.20.4
#  requires Java 17+ — it CANNOT run on Java 8.
#
#  Note: the old api.papermc.io/v2 endpoints now return HTTP 410 Gone. This
#  uses the current "Fill" v3 API and verifies the published sha256.
# ===========================================================================
say "Paper $MC_VERSION backend"
PAPER_META="$("$PY" - "$MC_VERSION" <<'PYPAPER'
import json, sys, urllib.request
ver = sys.argv[1]
url = f"https://fill.papermc.io/v3/projects/paper/versions/{ver}/builds/latest"
req = urllib.request.Request(url, headers={"User-Agent": "EagleCraft-setup/2.0"})
b = json.load(urllib.request.urlopen(req, timeout=60))
d = b["downloads"]["server:default"]
print(d["url"], d["checksums"]["sha256"], b["id"])
PYPAPER
)"
PAPER_URL="$(echo "$PAPER_META" | cut -d' ' -f1)"
PAPER_SHA="$(echo "$PAPER_META" | cut -d' ' -f2)"
PAPER_BUILD="$(echo "$PAPER_META" | cut -d' ' -f3)"
echo "  build #$PAPER_BUILD"
dl "$PAPER_URL" "$SMP/paper.jar" "$PAPER_SHA"

# ===========================================================================
# 3. BungeeCord proxy
# ===========================================================================
say "BungeeCord proxy"
dl "https://ci.md-5.net/job/BungeeCord/lastSuccessfulBuild/artifact/bootstrap/target/BungeeCord.jar" \
   "$BUNGEE/BungeeCord.jar"

# ===========================================================================
# 4. EaglerXServer — the websocket listener browsers actually connect to
# ===========================================================================
say "EaglerXServer (proxy plugin)"
EAGLER_URL="$("$PY" - <<'PYEAGLER'
import json, urllib.request
url = "https://api.github.com/repos/lax1dude/eaglerxserver/releases/latest"
req = urllib.request.Request(url, headers={"User-Agent": "EagleCraft-setup/2.0"})
try:
    rel = json.load(urllib.request.urlopen(req, timeout=60))
    for a in rel["assets"]:
        if a["name"] == "EaglerXServer.jar":
            print(a["browser_download_url"])
            break
except Exception:
    # GitHub API rate limit / offline -> fall back to a known-good pin.
    print("https://github.com/lax1dude/eaglerxserver/releases/download/v1.1.1/EaglerXServer.jar")
PYEAGLER
)"
dl "$EAGLER_URL" "$BUNGEE/plugins/EaglerXServer.jar"

# ===========================================================================
# 5. Via stack — 1.8 browser client  <->  1.20.4 backend
#
#  Direction matters, and all three are required:
#    ViaVersion   core translation engine
#    ViaBackwards lets OLDER clients join a NEWER server   (1.20.4 -> 1.16)
#    ViaRewind    extends that chain down to 1.8/1.7       (1.16  -> 1.8)
#  They live on the PROXY, so translation cost is paid by your host PC once,
#  not by every Chromebook.
# ===========================================================================
say "Via translation stack"
"$PY" - "$BUNGEE/plugins" "$MC_VERSION" <<'PYVIA'
import json, os, sys, urllib.parse, urllib.request

dest_dir, mc = sys.argv[1], sys.argv[2]
UA = {"User-Agent": "EagleCraft-setup/2.0"}


def fetch(url):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60))


for slug, pretty in (("viaversion", "ViaVersion"),
                     ("viabackwards", "ViaBackwards"),
                     ("viarewind", "ViaRewind")):
    loaders = urllib.parse.quote(json.dumps(["bungeecord"]))
    try:
        versions = fetch(f"https://api.modrinth.com/v2/project/{slug}/version?loaders={loaders}")
    except Exception as e:
        print(f"  !! {pretty}: could not reach Modrinth ({e})")
        continue
    # Stable releases only, and only ones that actually list our MC version.
    ok = [v for v in versions
          if v["version_type"] == "release" and mc in v["game_versions"]]
    if not ok:
        print(f"  !! {pretty}: no stable release listing {mc}")
        continue
    file = ok[0]["files"][0]
    dest = os.path.join(dest_dir, f"{pretty}.jar")
    if os.path.exists(dest) and os.path.getsize(dest) > 0 and os.environ.get("FORCE") != "1":
        print(f"  exists: {pretty}.jar")
        continue
    print(f"  downloading {pretty} {ok[0]['version_number']} ...")
    req = urllib.request.Request(file["url"], headers=UA)
    with urllib.request.urlopen(req, timeout=180) as r, open(dest + ".part", "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    os.replace(dest + ".part", dest)
PYVIA

# ===========================================================================
# 6. Configs — the whole point of this setup
# ===========================================================================
say "Configs (tuned for low-end browser clients)"
inst() {  # inst <src> <dst>   (always overwrite: these are OUR tuned files)
  cp -f "$1" "$2"
  echo "  installed: ${2#$ROOT/}"
}
inst smp-config/server.properties         "$SMP/server.properties"
inst smp-config/spigot.yml                "$SMP/spigot.yml"
inst smp-config/bukkit.yml                "$SMP/bukkit.yml"
inst smp-config/permissions.yml           "$SMP/permissions.yml"
inst smp-config/eula.txt                  "$SMP/eula.txt"
inst smp-config/paper-global.yml          "$SMP/config/paper-global.yml"
inst smp-config/paper-world-defaults.yml  "$SMP/config/paper-world-defaults.yml"
inst bungee-config/config.yml             "$BUNGEE/config.yml"

# Any leftovers from the old economy build.
if [ -d "$SMP/plugins/Essentials" ] || ls "$SMP/plugins"/EssentialsX*.jar >/dev/null 2>&1; then
  say "Removing old economy plugin"
  rm -rf "$SMP/plugins/Essentials" "$SMP/plugins"/EssentialsX*.jar \
         "$SMP/plugins/Essentials.jar" 2>/dev/null || true
  echo "  EssentialsX + its economy/sign-shop data removed."
fi

echo
echo "  view-distance 5 / simulation-distance 4, entity broadcast 50%,"
echo "  entity-activation animals 16 / monsters 24 / misc 8,"
echo "  max-entity-collisions 2, chunk send rate 12 chunks/s per player."

# ===========================================================================
# 7. Eaglercraft client
# ===========================================================================
say "Eaglercraft client"
if [ -s "$ROOT/web/eaglercraft/index.html" ]; then
  echo "  present ($(wc -c <"$ROOT/web/eaglercraft/index.html") bytes)."
else
  warn "web/eaglercraft/index.html missing."
  echo "     Drop an EaglercraftX 1.8 offline .html there as index.html."
fi

# ===========================================================================
# 8. Optional game collections (large)
# ===========================================================================
if [ "${SKIP_GAMES:-0}" = "1" ]; then
  say "Games site — skipped (SKIP_GAMES=1)"
else
  say "Games site"
  if [ -f "$ROOT/web/games/Gams.html" ]; then
    echo "  games already present."
  elif command -v git >/dev/null 2>&1; then
    echo "  cloning Gams-Offline/Gams (large, be patient)…"
    rm -rf "$ROOT/web/games"
    git clone --depth 1 https://github.com/Gams-Offline/Gams.git "$ROOT/web/games"
    rm -rf "$ROOT/web/games/.git"
  else
    warn "git not found — install git, then re-run to fetch the games."
  fi

  say "More Games"
  if [ -f "$ROOT/web/moregames/index.html" ]; then
    echo "  more games already present."
  elif command -v git >/dev/null 2>&1; then
    echo "  cloning BinBashBanana/gfiles…"
    rm -rf "$ROOT/web/moregames"
    git clone --depth 1 https://github.com/BinBashBanana/gfiles.git "$ROOT/web/moregames"
    rm -rf "$ROOT/web/moregames/.git"
  else
    warn "git not found — install git, then re-run to fetch more games."
  fi
fi

say "Done."
cat <<EOF

  Next:   bash start.sh
  RAM:    SMP_RAM_MB=8192 bash start.sh    (whole network: Paper + proxy)

  First boot only: EaglerXServer generates its own config under
  data/bungee/plugins/EaglerXServer/. After that first run, open
  settings.yml there and lower http_websocket_max_frame_length
  (upstream recommends cutting the old default by ~10x) — it bounds how
  much memory one misbehaving browser tab can make the proxy allocate.
EOF
