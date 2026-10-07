#!/usr/bin/env bash
# Start every database from install/docker_compose.yml.
#   ./start.sh          start
#   ./start.sh stop     stop containers (data is kept)
#   ./start.sh reset    stop and delete ALL data (images are kept)
#   ./start.sh purge    reset + delete the built image and build cache,
#                       so the next start installs everything from scratch
#
# Credentials live in the .env in the repo root (not in git).
# If the .env is missing it is created here from .env.example - with randomly
# generated passwords.
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=".env"

# Random password, only [A-Za-z0-9]: that way there is no trouble with
# shell expansion, YAML or the Postgres connection string.
random_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

create_env_file() {
    if [[ ! -f .env.example ]]; then
        echo ".env.example is missing - cannot create a .env." >&2
        exit 1
    fi
    echo "No .env found - creating one with random passwords ..."
    sed \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(random_password)|" \
        -e "s|^NEO4J_PASSWORD=.*|NEO4J_PASSWORD=$(random_password)|" \
        .env.example > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "  -> $ENV_FILE created (it is in .gitignore, please do not commit it)."
}

[[ -f "$ENV_FILE" ]] || create_env_file

# Compose file lives in install/, but ./data paths and the .env should resolve
# from the repo root.
compose() {
    docker compose -f install/docker_compose.yml --project-directory . --env-file "$ENV_FILE" "$@"
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

        # For display only - passwords are deliberately not printed.
        set -a; . "./$ENV_FILE"; set +a

        echo
        echo "Finished:"
        echo "  Postgres  localhost:${POSTGRES_PORT:-5432}    user ${POSTGRES_USER} / db ${POSTGRES_DB}"
        echo "  Neo4j     http://localhost:7474  bolt://localhost:${NEO4J_BOLT_PORT:-7687}  user ${NEO4J_USER:-neo4j}"
        echo "  Adminer   http://localhost:${ADMINER_PORT:-8080}  (Server: postgres)"
        echo "  Metabase  http://localhost:${METABASE_PORT:-3000}"
        echo
        echo "  Passwords are in ./$ENV_FILE  (show them with: grep PASSWORD $ENV_FILE)"
        ;;
    stop)  compose down ;;

    reset)
        echo "Stopping containers and deleting ALL database data ..."
        compose down --volumes --remove-orphans
        echo "Done. ./start.sh starts fresh, empty databases."
        ;;

    purge)
        # Like reset, but additionally deletes the self-built Postgres image
        # and the build cache. The next start then rebuilds and re-downloads
        # everything (takes a few minutes).
        echo "This deletes ALL database data, the built image and the build cache."
        read -r -p "Type 'yes' to continue: " answer
        [[ "$answer" == "yes" ]] || { echo "Aborted."; exit 1; }
        compose down --volumes --remove-orphans --rmi local
        docker builder prune --force >/dev/null
        # Anonymous volumes that no container uses any more.
        docker volume prune --force >/dev/null
        echo "Done. ./start.sh now installs everything from scratch."
        echo "Tip: delete .env too if you want new random passwords."
        ;;

    *)     echo "Usage: ./start.sh [start|stop|reset|purge]" >&2; exit 1 ;;
esac
