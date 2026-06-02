#!/usr/bin/env bash
# Host the EagleCraft website + SMP publicly via Microsoft Dev Tunnels.
# Uses a persistent, anonymous tunnel named "eaglecraft" so the URLs stay stable.
#
# Public URLs (anonymous — anyone can connect):
#   Website : https://<id>-8080.use.devtunnels.ms
#   SMP join: wss://<id>-25577.use.devtunnels.ms   (Eaglercraft -> Direct Connect)
#
# One-time login (interactive): /config/bin/devtunnel user login -e
# Then: bash tunnel.sh

set -e
DT=/config/bin/devtunnel

if ! "$DT" user show >/dev/null 2>&1; then
  echo "Not logged in. Run:  $DT user login -e   (Microsoft)  then re-run."
  exit 1
fi

# Create the tunnel + ports once (ignore errors if they already exist).
if ! "$DT" show eaglecraft >/dev/null 2>&1; then
  "$DT" create eaglecraft -a
  "$DT" port create eaglecraft -p 8080  --protocol http
  "$DT" port create eaglecraft -p 25577 --protocol http
fi

echo "Hosting tunnel 'eaglecraft' (website 8080 + SMP 25577, anonymous)…"
exec "$DT" host eaglecraft
