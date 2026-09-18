#!/usr/bin/env bash
# ===========================================================================
#  EagleCraft — boot the whole stack
#
#    1. reads .env (if present) and applies defaults
#    2. creates the SQLite tables if they are missing
#    3. checks the three port bindings before touching anything
#    4. starts the web panel, which owns and supervises:
#         - Paper 1.20.4   on 127.0.0.1:25565   (never exposed)
#         - BungeeCord     on 0.0.0.0:25577     (browsers connect here)
#    5. starts the Microsoft Dev Tunnel, if you are logged in
#
#  Usage:  bash start.sh
#          SMP_RAM_MB=8192 PORT=8081 bash start.sh
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
mkdir -p logs data

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  echo "!! python3 not found."; exit 1
fi

PIDFILE="logs/web.pid"

# pgrep does not exist in Git Bash on Windows, so the old pgrep guard silently
# never fired there and a second panel could be started on top of a live one.
# A PID file works identically on Linux, macOS and Git Bash.
panel_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# --- 1. environment --------------------------------------------------------
if [ -f .env ]; then
  echo "Loading .env"
  set -a; . ./.env; set +a
fi

export PORT="${PORT:-8080}"                  # website
export SMP_PORT="${SMP_PORT:-25577}"         # proxy / websocket (player-facing)
export SMP_RAM_MB="${SMP_RAM_MB:-4096}"      # WHOLE network budget
export SMP_PROXY_RAM_MB="${SMP_PROXY_RAM_MB:-512}"
export SMP_CONSOLE_LINES="${SMP_CONSOLE_LINES:-800}"
export AUTOSTART_SMP="${AUTOSTART_SMP:-1}"
export QUOTA_MB="${QUOTA_MB:-150}"
DEVTUNNEL="${DEVTUNNEL:-/config/bin/devtunnel}"

BACKEND_RAM=$(( SMP_RAM_MB - SMP_PROXY_RAM_MB ))
[ "$BACKEND_RAM" -lt 1024 ] && BACKEND_RAM=1024

echo "  ram budget:  ${SMP_RAM_MB} MB total  ->  paper ${BACKEND_RAM} MB + proxy ${SMP_PROXY_RAM_MB} MB"

if [ ! -f data/smp/paper.jar ] || [ ! -f data/bungee/BungeeCord.jar ]; then
  echo "!! Server not installed yet. Run:  bash setup.sh"
  exit 1
fi

# --- 2. database -----------------------------------------------------------
echo "Initialising database ..."
"$PY" server.py --init-db

# --- 3. port bindings ------------------------------------------------------
echo "Checking bindings ..."
if ! "$PY" server.py --check-ports; then
  echo
  echo "!! One of those ports is already taken."
  echo "   Website port is configurable:   PORT=8081 bash start.sh"
  echo "   If a previous run is still up:  bash stop.sh"
  exit 1
fi

# --- 4. web panel + supervised SMP ----------------------------------------
if panel_running; then
  echo "Web panel already running (pid $(cat "$PIDFILE"))."
else
  echo "Starting web panel + SMP on :$PORT ..."
  nohup "$PY" server.py > logs/web.log 2>&1 &
  echo $! > "$PIDFILE"
  echo "  pid $!  (log: logs/web.log)"
  # Give Paper a moment so the first dashboard load shows a live console.
  sleep 3
  if ! panel_running; then
    echo "!! panel exited immediately -- last lines of logs/web.log:"
    tail -20 logs/web.log
    rm -f "$PIDFILE"
    exit 1
  fi
fi

# --- 5. dev tunnel ---------------------------------------------------------
if [ -x "$DEVTUNNEL" ] && "$DEVTUNNEL" user show >/dev/null 2>&1; then
  if [ -f logs/tunnel.pid ] && kill -0 "$(cat logs/tunnel.pid)" 2>/dev/null; then
    echo "Dev tunnel already running."
  else
    echo "Starting Microsoft Dev Tunnel (anonymous) ..."
    if ! "$DEVTUNNEL" show eaglecraft >/dev/null 2>&1; then
      "$DEVTUNNEL" create eaglecraft -a
      "$DEVTUNNEL" port create eaglecraft -p "$PORT" --protocol http
      "$DEVTUNNEL" port create eaglecraft -p "$SMP_PORT" --protocol http
    fi
    nohup "$DEVTUNNEL" host eaglecraft > logs/tunnel.log 2>&1 &
    echo $! > logs/tunnel.pid
    echo "  pid $!  (public URLs in logs/tunnel.log)"
  fi
else
  echo
  echo "Dev Tunnel not logged in — site is local only for now."
  echo "To go public, run once:   $DEVTUNNEL user login -e"
  echo "then re-run:              bash start.sh"
fi

cat <<EOF

  Website:  http://localhost:$PORT
  Admin:    see data/admin.conf
  Join:     Eaglercraft -> Multiplayer -> Direct Connect
              LAN:    ws://<this-pc-lan-ip>:$SMP_PORT
              Public: wss://<id>-$SMP_PORT.<region>.devtunnels.ms
  Console:  dashboard -> Server Console (pipes straight into Paper's stdin)
  Logs:     logs/web.log  ·  data/smp/console.log  ·  data/bungee/console.log
EOF
