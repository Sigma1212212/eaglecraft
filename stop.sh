#!/usr/bin/env bash
# Stop the web panel, the SMP (Paper + BungeeCord) and the dev tunnel.
#
# The panel supervises both Java children and shuts them down gracefully on
# SIGTERM (proxy first, then save-all flush, then Paper), so we ask it nicely
# before reaching for the jars directly.
cd "$(dirname "$0")"

# If the Windows service owns the stack, a second copy started from a
# terminal would fight it for 8081/25565/25577 and leave orphans behind.
service_running() {
  command -v sc.exe >/dev/null 2>&1 || return 1
  sc.exe query eaglecraft 2>/dev/null | grep -q RUNNING
}

if service_running; then
  echo "EagleCraft is running as the 'eaglecraft' Windows service."
  echo "Stop it from an Administrator PowerShell (this runs the save-then-stop path):"
  echo "    Stop-Service eaglecraft"
  exit 0
fi

# PID files first (portable); pkill is only a fallback and does not exist
# everywhere -- Git Bash on Windows has no pgrep at all.
stop_pidfile() {  # stop_pidfile <file> <label> <wait-seconds>
  local f="$1" label="$2" wait="${3:-10}" pid
  [ -f "$f" ] || return 0
  pid="$(cat "$f" 2>/dev/null || true)"
  [ -n "$pid" ] || { rm -f "$f"; return 0; }
  if kill -0 "$pid" 2>/dev/null; then
    echo "Stopping $label (pid $pid) ..."
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 "$wait"); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$f"
}

stop_pidfile logs/tunnel.pid      "dev tunnel"  5
stop_pidfile logs/cloudflared.pid "cloudflared" 5
# The panel shuts the SMP down gracefully on SIGTERM, so give it room.
stop_pidfile logs/web.pid         "web panel"   40

pkill -f "devtunnel host eaglecraft" 2>/dev/null || true

# Anything that survived the graceful path (e.g. started by a previous run).
echo "Cleaning up stragglers ..."
pkill -f "BungeeCord.jar"  2>/dev/null || true
pkill -f "data/smp/paper.jar" 2>/dev/null || true
echo "Done."
