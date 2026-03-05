#!/bin/bash
set -euo pipefail

echo "==> Pulling container images..."
docker compose pull redis mysql nginx postgres memcached

echo "==> Building custom images..."
docker compose build api worker healthcheck

if [ -z "${NITESHIFT_CACHE_BUILD:-}" ]; then
    echo "==> Starting all services..."
    docker compose up -d --wait

    echo ""
    echo "==> Checking data persistence (MySQL)..."
    docker compose exec mysql mysql -uapp -papppass testdb -e "
        INSERT INTO items (name) VALUES ('setup-run-$(date +%s)');
        SELECT COUNT(*) AS total_setup_runs FROM items WHERE name LIKE 'setup-run-%';
    "

    echo ""
    echo "==> Checking data persistence (Postgres)..."
    docker compose exec postgres psql -U app testdb -c "
        CREATE TABLE IF NOT EXISTS setup_runs (id SERIAL PRIMARY KEY, ran_at TIMESTAMPTZ DEFAULT NOW());
        INSERT INTO setup_runs DEFAULT VALUES;
        SELECT count(*) AS total_setup_runs FROM setup_runs;
    "

    echo ""
    echo "==> Tailing logs..."
    docker compose logs -f
else
    echo "==> Cache build mode — skipping service startup"
fi
