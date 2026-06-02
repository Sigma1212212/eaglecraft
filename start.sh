#!/usr/bin/env bash
# ===========================================================================
#  EagleCraft — boot everything
#    1. web server (accounts, worlds, dashboard, /play)  on :8080
#    2. the SMP (Paper backend + BungeeCord proxy)        on :25577
#    3. the Microsoft Dev Tunnel (if logged in)           public URLs
#
#  Usage:  bash start.sh
# ===========================================================================
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
PORT="${PORT:-8080}"
DEVTUNNEL="${DEVTUNNEL:-/config/bin/devtunnel}"
mkdir -p logs

if [ ! -f data/smp/paper.jar ]; then
  echo "Server not installed yet. Run:  bash setup.sh"
  exit 1
fi

# --- web server + auto-started SMP ----------------------------------------
if pgrep -f "python3 server.py" >/dev/null 2>&1; then
  echo "Web server already running."
else
  echo "Starting web server + SMP on :$PORT (8 GB RAM) ..."
  AUTOSTART_SMP=1 PORT="$PORT" nohup python3 server.py > logs/web.log 2>&1 &
  echo "  pid $!  (log: logs/web.log)"
fi

# --- dev tunnel ------------------------------------------------------------
if [ -x "$DEVTUNNEL" ] && "$DEVTUNNEL" user show >/dev/null 2>&1; then
  if pgrep -f "devtunnel host eaglecraft" >/dev/null 2>&1; then
    echo "Dev tunnel already running."
  else
    echo "Starting Microsoft Dev Tunnel (anonymous) ..."
    if ! "$DEVTUNNEL" show eaglecraft >/dev/null 2>&1; then
      "$DEVTUNNEL" create eaglecraft -a
      "$DEVTUNNEL" port create eaglecraft -p "$PORT" --protocol http
      "$DEVTUNNEL" port create eaglecraft -p 25577 --protocol http
    fi
    nohup "$DEVTUNNEL" host eaglecraft > logs/tunnel.log 2>&1 &
    echo "  pid $!  (public URLs in logs/tunnel.log)"
  fi
else
  echo
  echo "Dev Tunnel not logged in — site is local only for now."
  echo "To go public, run once:   $DEVTUNNEL user login -e"
  echo "then re-run:              bash start.sh"
fi

echo
echo "Local:   http://localhost:$PORT"
echo "Admin:   see data/admin.conf  (default admin / Learn2025)"
echo "Tunnel:  grep devtunnels.ms logs/tunnel.log   (after a few seconds)"
