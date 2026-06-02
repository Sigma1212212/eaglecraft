#!/usr/bin/env bash
# Stop the web server, the SMP (Paper + BungeeCord) and the dev tunnel.
echo "Stopping dev tunnel ..."; pkill -f "devtunnel host eaglecraft" 2>/dev/null || true
echo "Stopping web server ..."; pkill -f "python3 server.py" 2>/dev/null || true
echo "Stopping SMP (proxy + backend) ..."
pkill -f "BungeeCord.jar" 2>/dev/null || true
pkill -f "data/smp/paper.jar" 2>/dev/null || true
echo "Done."
