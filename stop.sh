#!/usr/bin/env bash
# Stop the web panel, the SMP (Paper + BungeeCord) and the dev tunnel.
#
# The panel supervises both Java children and shuts them down gracefully on
# SIGTERM (proxy first, then save-all flush, then Paper), so we ask it nicely
# before reaching for the jars directly.
cd "$(dirname "$0")"

echo "Stopping dev tunnel ..."
pkill -f "devtunnel host eaglecraft" 2>/dev/null || true

echo "Stopping web panel (graceful SMP shutdown) ..."
if pkill -f "server.py" 2>/dev/null; then
  for _ in $(seq 1 30); do
    pgrep -f "server.py" >/dev/null 2>&1 || break
    sleep 1
  done
fi

# Anything that survived the graceful path (e.g. started by a previous run).
echo "Cleaning up stragglers ..."
pkill -f "BungeeCord.jar"  2>/dev/null || true
pkill -f "data/smp/paper.jar" 2>/dev/null || true
echo "Done."
