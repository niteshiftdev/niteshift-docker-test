#!/bin/bash
set -euo pipefail

echo "==> Pulling container images..."
docker compose pull redis mysql nginx

echo "==> Building custom images..."
docker compose build api worker healthcheck

if [ -z "${NITESHIFT_CACHE_BUILD:-}" ]; then
    echo "==> Starting all services..."
    docker compose up
else
    echo "==> Cache build mode — skipping service startup"
fi
