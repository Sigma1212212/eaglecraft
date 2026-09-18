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
#  Usage:   bash cloudflare.sh              # both quick tunnels
#           bash cloudflare.sh smp          # game only (recommended)
#           bash cloudflare.sh web          # website only
#           bash cloudflare.sh stop
#
#           bash cloudflare.sh named mc.yourdomain.com
#                                           # STABLE address on your own domain
#
#  Quick-tunnel URLs are EPHEMERAL -- a new random hostname every restart,
#  which is useless for a server people are supposed to keep playing on.
#  `named` binds the SMP to a hostname in a zone you already own and creates
#  the DNS record for you. One-time browser authorisation first:
#
#     cloudflared tunnel login
#
#  then `bash cloudflare.sh named mc.yourdomain.com` does create + route + run.
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
  stop_pid logs/cloudflared.pid       "SMP quick tunnel"
  stop_pid logs/cloudflared-web.pid   "web tunnel"
  stop_pid logs/cloudflared-named.pid "named tunnel"
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
    echo "$label tunnel already running." >&2
    return 0
  fi
  # Refuse to publish a port nothing is serving -- otherwise you hand out a
  # URL that 502s and spend an hour blaming Cloudflare.
  if ! curl -s -o /dev/null -m 3 "http://127.0.0.1:$port/" \
       && ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo "!! nothing is listening on 127.0.0.1:$port -- run 'bash start.sh' first." >&2
    return 1
  fi
  echo "Opening $label tunnel -> localhost:$port ..." >&2
  nohup "$CF" tunnel --no-autoupdate --url "http://localhost:$port" > "$log" 2>&1 &
  echo $! > "$pidf"
  grab_url "$log" || { echo "!! no URL after 40s; see $log" >&2; return 1; }
}

# ===========================================================================
#  Named tunnel: stable hostname on a domain you own.
# ===========================================================================
if [ "$MODE" = "named" ]; then
  GAME_HOST="${2:-}"
  WEB_HOST="${3:-}"
  TUNNEL_NAME="${TUNNEL_NAME:-eaglecraft}"
  if [ -z "$GAME_HOST" ]; then
    echo "!! usage: bash cloudflare.sh named mc.yourdomain.com [play.yourdomain.com]"
    echo "   first hostname  = the SMP websocket"
    echo "   second hostname = the website (optional; exposes /dashboard too)"
    exit 1
  fi

  # cloudflared stores the zone authorisation cert here after `tunnel login`.
  CFDIR=""
  for d in "$HOME/.cloudflared" "$USERPROFILE/.cloudflared"; do
    [ -f "$d/cert.pem" ] && { CFDIR="$d"; break; }
  done
  if [ -z "$CFDIR" ]; then
    echo "!! Not authorised with Cloudflare yet. Run this once (opens a browser,"
    echo "   pick the zone you want):"
    echo
    echo "       $CF tunnel login"
    echo
    echo "   then re-run:  bash cloudflare.sh named $GAME_HOST"
    exit 1
  fi
  echo "  authorised: $CFDIR/cert.pem"

  if ! "$CF" tunnel info "$TUNNEL_NAME" >/dev/null 2>&1; then
    echo "Creating tunnel '$TUNNEL_NAME' ..."
    "$CF" tunnel create "$TUNNEL_NAME"
  else
    echo "Tunnel '$TUNNEL_NAME' already exists."
  fi

  CRED="$(ls "$CFDIR"/*.json 2>/dev/null | head -1 || true)"
  if [ -z "$CRED" ]; then
    echo "!! no tunnel credentials json in $CFDIR"
    exit 1
  fi
  # cloudflared is a Windows binary under Git Bash, so it needs a Windows path.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) CRED_OUT="$(echo "$CRED" | sed 's|^/\([a-z]\)/|\U\1:/|')" ;;
    *)                    CRED_OUT="$CRED" ;;
  esac

  # --- generate the ingress config --------------------------------------
  # Run WITHOUT --url: that flag pins the tunnel to a single origin and
  # overrides everything below, so the second hostname would 404.
  {
    echo "# Generated by cloudflare.sh. Also read by the Windows service."
    echo "tunnel: $TUNNEL_NAME"
    echo "credentials-file: $CRED_OUT"
    echo ""
    echo "originRequest:"
    echo "  connectTimeout: 10s"
    echo "  keepAliveTimeout: 90s"
    echo "  noHappyEyeballs: true"
    echo ""
    echo "ingress:"
    echo "  # SMP websocket - cloudflared proxies the Upgrade handshake natively."
    echo "  - hostname: $GAME_HOST"
    echo "    service: http://localhost:$SMP_PORT"
    if [ -n "$WEB_HOST" ]; then
      echo ""
      echo "  # Website. NOTE: this also exposes /dashboard and /api/smp* to the"
      echo "  # internet, so the panel password is the only thing between a"
      echo "  # stranger and a server console. Keep it strong."
      echo "  - hostname: $WEB_HOST"
      echo "    service: http://localhost:$PORT"
    fi
    echo ""
    echo "  - service: http_status:404"
  } > "$CFDIR/config.yml"
  echo "  wrote $CFDIR/config.yml"

  "$CF" tunnel ingress validate || { echo "!! ingress config invalid"; exit 1; }

  echo "Routing DNS ..."
  "$CF" tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$GAME_HOST" || true
  [ -n "$WEB_HOST" ] && { "$CF" tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$WEB_HOST" || true; }

  for f in logs/cloudflared.pid logs/cloudflared-named.pid; do
    if [ -f "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null; then
      echo "Stopping existing tunnel (pid $(cat "$f")) ..."
      kill "$(cat "$f")" 2>/dev/null || true
      rm -f "$f"
      sleep 2
    fi
  done

  echo "Starting named tunnel ..."
  nohup "$CF" tunnel run "$TUNNEL_NAME" > logs/cf-named.log 2>&1 &
  echo $! > logs/cloudflared-named.pid
  sleep 10

  if ! kill -0 "$(cat logs/cloudflared-named.pid)" 2>/dev/null; then
    echo "!! tunnel exited -- last lines of logs/cf-named.log:"
    tail -20 logs/cf-named.log
    exit 1
  fi
  CONNS="$(grep -c "Registered tunnel connection" logs/cf-named.log 2>/dev/null || echo 0)"
  echo "  $CONNS edge connections registered"

  echo
  echo "==========================================================="
  echo "  SMP (stable -- give this to players, it will not change):"
  echo
  echo "      wss://$GAME_HOST"
  echo
  echo "  Eaglercraft -> Multiplayer -> Direct Connect. No port number."
  if [ -n "$WEB_HOST" ]; then
    echo
    echo "  Website:  https://$WEB_HOST"
    echo "  !! /dashboard is reachable from the internet on that hostname."
  fi
  echo "  DNS may take a minute to propagate on first run."
  echo "==========================================================="
  echo "  Survive reboots:  $CF service install   (needs Administrator)"
  echo "  Stop with:        bash cloudflare.sh stop"
  exit 0
fi

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
