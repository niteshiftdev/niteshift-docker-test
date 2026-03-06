#!/bin/bash
set -euo pipefail

START_TIME=$SECONDS

echo "==> Pulling container images..."
docker compose pull redis mysql nginx postgres memcached

echo "==> Building custom images..."
docker compose build api worker healthcheck

if [ -z "${NITESHIFT_CACHE_BUILD:-}" ]; then
    # On resume, containers may have stale network IDs from the previous
    # suspend cycle (kernel network state is lost but container configs
    # survive with docker data persistence). Tear down stale containers
    # before starting fresh — named volumes are preserved.
    echo "==> Removing stale containers (preserves volumes)..."
    docker compose down --remove-orphans 2>/dev/null || true

    echo "==> Starting all services..."
    docker compose up -d --wait

    ELAPSED=$(( SECONDS - START_TIME ))
    echo "==> All services ready in ${ELAPSED}s"

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
