#!/usr/bin/env bash
# Start every database from install/docker_compose.yml.
#   ./start.sh          start
#   ./start.sh stop     stop containers (data is kept)
#   ./start.sh reset    stop and delete ALL data
set -euo pipefail
cd "$(dirname "$0")"

# Compose file lives in install/, but ./data paths should resolve from the repo root.
compose() {
    docker compose -f install/docker_compose.yml --project-directory . "$@"
}

if ! docker info >/dev/null 2>&1; then
    echo "Docker is not running. Please start Docker Desktop (open -a Docker) and try again." >&2
    exit 1
fi

case "${1:-start}" in
    start)
        mkdir -p data
        echo "Starting databases (the first time it may take a few minutes) ..."
        compose up -d --build --wait
        echo
        echo "Finished:"
        echo "  Postgres  localhost:5432         user/pw/db: suburblens"
        echo "  Neo4j     http://localhost:7474  bolt://localhost:7687  user neo4j / pw suburblens"
        echo "  Adminer   http://localhost:8080  (Server: postgres)"
        echo "  Metabase  http://localhost:3000"
        ;;
    stop)  compose down ;;
    reset) compose down --volumes ;;
    *)     echo "Usage: ./start.sh [start|stop|reset]" >&2; exit 1 ;;
esac