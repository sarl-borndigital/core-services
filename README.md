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

Point the other project's config at the Docker network gateway IP (which routes to the host). Find the gateway IP with:

```bash
docker network inspect shared-services --format '{{(index .IPAM.Config 0).Gateway}}'
```

Then use that IP in your config (e.g., if the output is `172.18.0.1`):

```
DB_HOST=172.18.0.1
DB_PORT=3306
REDIS_HOST=172.18.0.1
REDIS_PORT=6379
```

If the other project is not running in Docker (bare host process), use `localhost` instead since the ports are published to the host.

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
