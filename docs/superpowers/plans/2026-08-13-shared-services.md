# Shared Services Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a standalone Docker Compose stack in `core/` providing shared MySQL and Redis services that other project containers can connect to over a shared Docker network or published host ports.

**Architecture:** A single `docker-compose.yml` defines `mysql` and `redis` services plus a `shared-services` bridge network that this repo owns. A `core.sh` wrapper script provides short commands for common operations. No application service or per-project database provisioning is included — this is infrastructure-only, and database/user creation is manual/on-demand.

**Tech Stack:** Docker Compose, `mysql:8.0`, `redis:7-alpine`, Bash.

## Global Constraints

- Local dev only — no TLS, no Redis auth, no remote-access hardening (spec: Out of scope).
- Images: `mysql:8.0`, `redis:7-alpine` (spec: Components).
- Network name: `shared-services`, driver `bridge`, created by this compose file — not `external` (spec: Network).
- Container names: `core-mysql`, `core-redis` (spec: Components).
- Ports configurable via `.env`: `MYSQL_PORT` (default `3306`), `REDIS_PORT` (default `6379`), both published to host (spec: Architecture).
- `MYSQL_ROOT_PASSWORD` from `.env`, default `root` for local dev (spec: mysql).
- `restart: unless-stopped` on both services for boot persistence (spec: Auto-start on boot).
- No per-project databases pre-created; provisioning is manual via root connection (spec: mysql, Out of scope).
- `core.sh` commands: `start`, `stop`, `restart`, `down`, `status`, `logs [service]`, `mysql`, `redis` (spec: core.sh utility script).
- File structure exactly as listed in spec's "Proposed File Structure" section.

---

### Task 1: Docker Compose stack (mysql + redis + network + volume)

**Files:**
- Create: `docker-compose.yml`
- Create: `.env.example`
- Create: `.gitignore`

**Interfaces:**
- Produces: Docker network `shared-services` (external bridge network other projects will reference), containers `core-mysql` (port `${MYSQL_PORT:-3306}`) and `core-redis` (port `${REDIS_PORT:-6379}`), named volume `core-mysql-data`. Env vars consumed: `MYSQL_ROOT_PASSWORD`, `MYSQL_PORT`, `REDIS_PORT`.

- [ ] **Step 1: Write `.gitignore`**

```
.env
```

- [ ] **Step 2: Write `.env.example`**

```
MYSQL_ROOT_PASSWORD=root
MYSQL_PORT=3306
REDIS_PORT=6379
```

- [ ] **Step 3: Copy `.env.example` to `.env` for local use**

Run: `cp .env.example .env`

- [ ] **Step 4: Write `docker-compose.yml`**

```yaml
services:
  mysql:
    image: mysql:8.0
    container_name: core-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-root}
    ports:
      - "${MYSQL_PORT:-3306}:3306"
    volumes:
      - core-mysql-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-uroot", "-p${MYSQL_ROOT_PASSWORD:-root}"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - shared-services

  redis:
    image: redis:7-alpine
    container_name: core-redis
    restart: unless-stopped
    ports:
      - "${REDIS_PORT:-6379}:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks:
      - shared-services

networks:
  shared-services:
    name: shared-services
    driver: bridge

volumes:
  core-mysql-data:
    driver: local
```

- [ ] **Step 5: Validate the compose file syntax**

Run: `docker compose config --quiet`
Expected: no output, exit code 0.

- [ ] **Step 6: Bring the stack up**

Run: `docker compose up -d`
Expected: both `mysql` and `redis` containers created and started.

- [ ] **Step 7: Wait for both services to report healthy**

Run: `docker compose ps`
Expected: both `core-mysql` and `core-redis` rows show `healthy` in the STATUS column (may take ~10-30s for mysql; re-run if still `starting`).

- [ ] **Step 8: Verify mysql accepts root connections**

Run: `docker exec core-mysql mysql -uroot -proot -e "SELECT 1;"`
Expected: prints a `1` row, no auth error.

- [ ] **Step 9: Verify redis responds**

Run: `docker exec core-redis redis-cli ping`
Expected: `PONG`

- [ ] **Step 10: Verify the shared network exists and is a bridge network**

Run: `docker network inspect shared-services --format '{{.Driver}}'`
Expected: `bridge`

- [ ] **Step 11: Verify container-name resolution from another container on the network**

Run: `docker run --rm --network shared-services mysql:8.0 mysql -h mysql -uroot -proot -e "SELECT 1;"`
Expected: prints a `1` row — confirms other containers can reach mysql by the hostname `mysql`.

Run: `docker run --rm --network shared-services redis:7-alpine redis-cli -h redis ping`
Expected: `PONG` — confirms other containers can reach redis by the hostname `redis`.

- [ ] **Step 12: Commit**

```bash
git add docker-compose.yml .env.example .gitignore
git commit -m "feat: add shared mysql/redis docker compose stack"
```

---

### Task 2: core.sh utility script

**Files:**
- Create: `core.sh` (executable)

**Interfaces:**
- Consumes: `docker-compose.yml` from Task 1 (same directory), `.env` (`MYSQL_ROOT_PASSWORD`) for the `mysql` subcommand.
- Produces: CLI commands `./core.sh {start|stop|restart|down|status|logs [service]|mysql|redis}`.

- [ ] **Step 1: Write `core.sh`**

```bash
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
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x core.sh`

- [ ] **Step 3: Verify usage output on unknown command**

Run: `./core.sh bogus; echo "exit: $?"`
Expected: prints the `Usage: ...` line and `exit: 1`.

- [ ] **Step 4: Verify `status` reflects the running stack from Task 1**

Run: `./core.sh status`
Expected: shows `core-mysql` and `core-redis` both `healthy` (stack is already up from Task 1).

- [ ] **Step 5: Verify the credentials `core.sh mysql` would use are valid**

`./core.sh mysql` runs `docker exec -it ...`, which allocates a TTY and
only works when run directly at a real terminal — it can't be piped in a
scripted step. Instead, verify the same container/credentials it targets
work, using `-i` (no TTY) so the check can run non-interactively:

Run: `docker exec -i core-mysql mysql -uroot -proot -e "SELECT 1;"`
Expected: prints a `1` row.

Then, at a real terminal, run `./core.sh mysql` directly and confirm it
drops you into a `mysql>` prompt; type `exit` to leave.

- [ ] **Step 6: Verify the container `core.sh redis` would use is reachable**

Run: `docker exec -i core-redis redis-cli ping`
Expected: `PONG`

Then, at a real terminal, run `./core.sh redis` directly and confirm it
drops you into a `redis-cli` prompt; type `exit` to leave.

- [ ] **Step 7: Verify `logs` accepts an optional service argument without error**

Run: `timeout 3 ./core.sh logs mysql || true`
Expected: streams `core-mysql` log lines (command is killed by `timeout` after 3s, that's expected).

- [ ] **Step 8: Commit**

```bash
git add core.sh
git commit -m "feat: add core.sh wrapper for common docker compose operations"
```

---

### Task 3: README documentation

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: command set from Task 2 (`core.sh`), service/network names from Task 1.
- Produces: none (documentation only).

- [ ] **Step 1: Write `README.md`**

```markdown
# core — Shared Services

Standalone Docker Compose stack providing shared MySQL and Redis instances
for local development, so other project stacks (bortex, farsons, future
projects) can connect to shared services instead of each running their own.

This repo only stands up the shared services. It does not modify any other
project's compose files — wiring a project to use these services is a
change you make in that project's own repo.

## Services

| Service | Container name | Image           | Host port (default) |
|---------|-----------------|-----------------|----------------------|
| mysql   | `core-mysql`    | `mysql:8.0`     | `3306` (`MYSQL_PORT`) |
| redis   | `core-redis`    | `redis:7-alpine`| `6379` (`REDIS_PORT`) |

Both are attached to a Docker bridge network named `shared-services`,
created by this stack. `restart: unless-stopped` brings them back
automatically whenever the Docker daemon restarts (covers machine reboot,
assuming the Docker daemon itself is enabled to start on boot).

## Setup

```bash
cp .env.example .env    # adjust MYSQL_ROOT_PASSWORD / ports if needed
./core.sh start
./core.sh status         # wait until both services show "healthy"
```

## core.sh commands

| Command                | Action                                                |
|-------------------------|--------------------------------------------------------|
| `./core.sh start`       | Start the stack (`docker compose up -d`)                |
| `./core.sh stop`        | Stop containers, keep them (`docker compose stop`)       |
| `./core.sh restart`     | Restart containers                                       |
| `./core.sh down`        | Stop and remove containers (volumes are kept)            |
| `./core.sh status`      | Show container/health status                             |
| `./core.sh logs [svc]`  | Tail logs, optionally for one service (`mysql`/`redis`) |
| `./core.sh mysql`       | Open a `mysql` shell in `core-mysql` as root             |
| `./core.sh redis`       | Open a `redis-cli` shell in `core-redis`                 |

## Connecting another project

**Option A — attach to the shared network (container-to-container):**

In the other project's `docker-compose.yml`, declare the network as
external and attach your app service to it:

```yaml
services:
  app:
    # ...existing config...
    networks:
      - default
      - shared-services
    environment:
      DB_HOST: mysql
      DB_PORT: 3306
      REDIS_HOST: redis
      REDIS_PORT: 6379

networks:
  shared-services:
    external: true
```

**Option B — connect via published host ports (no compose changes):**

Point the other project's config at the host instead of a container
hostname:

```
DB_HOST=host.docker.internal   # or localhost, if running outside Docker
DB_PORT=3306
REDIS_HOST=host.docker.internal
REDIS_PORT=6379
```

## Creating a database for a project

Database/user provisioning is on-demand — nothing is pre-created. Example
for a new project called `myproject`:

```bash
docker exec -it core-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "
  CREATE DATABASE myproject;
  CREATE USER 'myproject'@'%' IDENTIFIED BY 'secret';
  GRANT ALL ON myproject.* TO 'myproject'@'%';
"
```

Redis has no per-project databases or auth. If two projects need isolated
keyspaces, have each select a different logical DB index (0-15), e.g.
`redis-cli -n 1` for one project and `-n 2` for another.
```

- [ ] **Step 2: Verify the file renders sensibly**

Run: `head -20 README.md`
Expected: shows the title and services table, no obvious formatting breakage.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README for shared services stack"
```

---

## Final Verification

- [ ] **Step 1: Confirm full working tree is clean and stack is healthy**

Run: `git status --short && ./core.sh status`
Expected: `git status` shows no uncommitted changes (other than the git-ignored `.env`); `core.sh status` shows both services `healthy`.
