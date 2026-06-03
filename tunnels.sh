#!/usr/bin/env bash
# Start / stop the EagleCraft dev tunnels.
#   bash tunnels.sh start    # bring the public tunnel up (website 8080 + SMP 25577)
#   bash tunnels.sh stop     # take the tunnel down
#   bash tunnels.sh status   # is it up? show the URLs
#
# Uses the persistent "eaglecraft" tunnel so the URLs stay the same each time.
# One-time login (only if it asks):  /config/bin/devtunnel user login -e
set -u
DT="${DEVTUNNEL:-/config/bin/devtunnel}"
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/logs/tunnel.log"
mkdir -p "$DIR/logs"

case "${1:-status}" in
  start)
    if pgrep -f "devtunnel host" >/dev/null 2>&1; then
      echo "Tunnel already running."; exec "$0" status
    fi
    if ! "$DT" user show >/dev/null 2>&1; then
      echo "Not logged in. Run:  $DT user login -e   then try again."; exit 1
    fi
    echo "Starting tunnel..."
    # Host the persistent "eagle2" tunnel (ports 8080 + 25577) so the URLs stay
    # the same each time. Created under the trust.sigma account (has host scope).
    setsid "$DT" host eagle2 > "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    # wait up to ~15s for the URLs to show up
    for i in $(seq 1 30); do
      grep -q "Ready to accept" "$LOG" 2>/dev/null && break
      sleep 0.5 2>/dev/null || true
    done
    exec "$0" status
    ;;
  stop)
    if pkill -f "devtunnel host" 2>/dev/null; then echo "Tunnel stopped."
    else echo "No tunnel was running."; fi
    ;;
  status)
    if pgrep -f "devtunnel host" >/dev/null 2>&1; then
      echo "Tunnel: UP"
      echo "  website:  $(grep -oE 'https://[a-z0-9-]+-8080\.use\.devtunnels\.ms' "$LOG" 2>/dev/null | head -1)"
      smp="$(grep -oE 'https://[a-z0-9-]+-25577\.use\.devtunnels\.ms' "$LOG" 2>/dev/null | head -1)"
      echo "  SMP join: ${smp/https:/wss:}"
    else
      echo "Tunnel: DOWN  (run: bash tunnels.sh start)"
    fi
    ;;
  *)
    echo "usage: bash tunnels.sh {start|stop|status}";;
esac
