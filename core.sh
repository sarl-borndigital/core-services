#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
  echo "Usage: $0 {start|stop|restart|down|status|logs [service]|mysql|redis}"
  exit 1
}

load_env() {
  if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi
}

[ $# -ge 1 ] || usage

cmd="$1"
shift || true

case "$cmd" in
  start)
    docker compose up -d
    ;;
  stop)
    docker compose stop
    ;;
  restart)
    docker compose restart
    ;;
  down)
    docker compose down
    ;;
  status)
    docker compose ps
    ;;
  logs)
    docker compose logs -f "$@"
    ;;
  mysql)
    load_env
    docker exec -it core-mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD:-root}"
    ;;
  redis)
    docker exec -it core-redis redis-cli
    ;;
  *)
    usage
    ;;
esac
