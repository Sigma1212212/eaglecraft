#!/usr/bin/env bash
# ===========================================================================
#  EagleCraft — publish through Cloudflare Tunnel
#
#  Opens two "quick tunnels" (no Cloudflare account, no domain needed):
#
#     wss://<random>.trycloudflare.com   ->  localhost:25577   the SMP
#     https://<random>.trycloudflare.com ->  localhost:8081    the website
#
#  Cloudflare terminates TLS on 443, so players paste the hostname with NO
#  port number into Eaglercraft's Direct Connect box. Websockets are proxied
#  natively, which is exactly what Eaglercraft speaks.
#
#  Usage:   bash cloudflare.sh              # both tunnels
#           bash cloudflare.sh smp          # game only (recommended)
#           bash cloudflare.sh web          # website only
#           bash cloudflare.sh stop
#
#  Quick-tunnel URLs are EPHEMERAL: they change every restart. For a stable
#  address you need a Cloudflare account + a domain and a named tunnel:
#     cloudflared tunnel login
#     cloudflared tunnel create eaglecraft
#     cloudflared tunnel route dns eaglecraft mc.yourdomain.com
#     cloudflared tunnel run --url http://localhost:25577 eaglecraft
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p logs runtime

PORT="${PORT:-8081}"
SMP_PORT="${SMP_PORT:-25577}"
MODE="${1:-both}"

# --- locate / fetch cloudflared -------------------------------------------
CF="$(command -v cloudflared || true)"
if [ -z "$CF" ]; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) CF="./runtime/cloudflared.exe"; ASSET="cloudflared-windows-amd64.exe" ;;
    Darwin*)              CF="./runtime/cloudflared";     ASSET="cloudflared-darwin-amd64.tgz" ;;
    *)                    CF="./runtime/cloudflared";     ASSET="cloudflared-linux-amd64" ;;
  esac
  if [ ! -x "$CF" ] && [ ! -s "$CF" ]; then
    echo "Downloading cloudflared ..."
    curl -fL --retry 3 -o "$CF" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/$ASSET"
    chmod +x "$CF" 2>/dev/null || true
  fi
fi

stop_pid() {
  local f="$1" label="$2" pid
  [ -f "$f" ] || return 0
  pid="$(cat "$f" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "Stopping $label (pid $pid)"
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$f"
}

if [ "$MODE" = "stop" ]; then
  stop_pid logs/cloudflared.pid     "SMP tunnel"
  stop_pid logs/cloudflared-web.pid "web tunnel"
  echo "Done."
  exit 0
fi

# --- wait for a trycloudflare hostname to show up in the log --------------
grab_url() {  # grab_url <logfile>
  local log="$1" url=""
  for _ in $(seq 1 40); do
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" 2>/dev/null | head -1 || true)"
    [ -n "$url" ] && { echo "$url"; return 0; }
    sleep 1
  done
  return 1
}

launch() {  # launch <local-port> <logfile> <pidfile> <label>
  local port="$1" log="$2" pidf="$3" label="$4"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
    echo "$label tunnel already running."
    return 0
  fi
  # Refuse to publish a port nothing is serving -- otherwise you hand out a
  # URL that 502s and spend an hour blaming Cloudflare.
  if ! curl -s -o /dev/null -m 3 "http://127.0.0.1:$port/" \
       && ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo "!! nothing is listening on 127.0.0.1:$port -- run 'bash start.sh' first."
    return 1
  fi
  echo "Opening $label tunnel -> localhost:$port ..."
  nohup "$CF" tunnel --no-autoupdate --url "http://localhost:$port" > "$log" 2>&1 &
  echo $! > "$pidf"
  grab_url "$log" || { echo "!! no URL after 40s; see $log"; return 1; }
}

SMP_URL=""; WEB_URL=""
if [ "$MODE" = "both" ] || [ "$MODE" = "smp" ]; then
  SMP_URL="$(launch "$SMP_PORT" logs/cf-smp.log logs/cloudflared.pid "SMP")" || true
fi
if [ "$MODE" = "both" ] || [ "$MODE" = "web" ]; then
  WEB_URL="$(launch "$PORT" logs/cf-web.log logs/cloudflared-web.pid "website")" || true
fi

echo
echo "==========================================================="
if [ -n "$SMP_URL" ]; then
  echo "  SMP  (give this to players):"
  echo "      ${SMP_URL/https:/wss:}"
  echo "      Eaglercraft -> Multiplayer -> Direct Connect"
  echo "      No port number. Cloudflare serves it on 443."
fi
if [ -n "$WEB_URL" ]; then
  echo
  echo "  Website:  $WEB_URL"
  echo
  echo "  !! This URL exposes the admin panel, and the admin panel can run"
  echo "     arbitrary server console commands. Make sure data/admin.conf"
  echo "     does NOT still hold the README's default password."
fi
echo "==========================================================="
echo "  Stop with:  bash cloudflare.sh stop"
echo "  URLs are ephemeral and change on every restart."
