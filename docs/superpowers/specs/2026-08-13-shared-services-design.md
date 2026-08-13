# Shared Services Stack — Design

## Purpose

Provide a standalone set of core infrastructure services (MySQL, Redis) that
run independently of any single project, so other project stacks (bortex,
farsons, future projects) can connect to shared instances instead of each
running their own. This avoids duplicated containers, duplicated resource
usage, and per-project data drift for services that are naturally shared.

## Scope

This repo (`core`) only stands up the shared services themselves. It does
**not** modify any other project's `docker-compose.yml`. Wiring an existing
project to use these shared services is a separate, later change made in
that project's own repo.

## Architecture

A single `docker-compose.yml` in this directory defines:

- Two services: `mysql` and `redis`.
- One Docker network, `shared-services`, owned (created) by this compose
  file.
- No application service — this stack is infrastructure-only.

Other projects attach to the `shared-services` network as an `external`
network in their own compose files, and reach these services by container
name (`mysql`, `redis`) as hostname. The services' ports are also published
to the host, so host-side tools (a DB client, `redis-cli`) can connect
directly via `localhost`.

## Components

### mysql

- Image: `mysql:8.0`
- Container name: `core-mysql`
- Root password from `.env` (`MYSQL_ROOT_PASSWORD`)
- Data persisted in a named volume (`core-mysql-data`)
- Healthcheck via `mysqladmin ping`
- Port `3306` published to host (configurable via `MYSQL_PORT`)
- `restart: unless-stopped`

No per-project databases are pre-created. Database/user provisioning is
on-demand: when a project needs a database, connect as root and run
`CREATE DATABASE` / `CREATE USER` / `GRANT` manually, e.g.:

```
docker exec -it core-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e "CREATE DATABASE bortex_middlelayer; \
      CREATE USER 'bortex'@'%' IDENTIFIED BY 'secret'; \
      GRANT ALL ON bortex_middlelayer.* TO 'bortex'@'%';"
```

### redis

- Image: `redis:7-alpine`
- Container name: `core-redis`
- No authentication (local dev only)
- Healthcheck via `redis-cli ping`
- Port `6379` published to host (configurable via `REDIS_PORT`)
- `restart: unless-stopped`

Since Redis is shared without per-project auth, projects that want
isolation from each other's keys should select different logical DB numbers
(0–15) via their client's `SELECT`/DB-index config, rather than colliding on
DB 0.

### Network

- Name: `shared-services`
- Driver: `bridge`
- Created by this compose file (not `external` here — this is the owning
  stack). Consuming projects declare it as `external: true` and attach their
  app service to it.

### Auto-start on boot

`restart: unless-stopped` brings both containers back automatically
whenever the Docker daemon restarts, which covers machine reboot as long as
the Docker daemon itself is enabled to start on boot (the typical default
for a standard Docker install). No additional systemd unit is created by
this design; if the Docker daemon is not enabled at boot on this machine,
that's a one-time system-level check outside this repo's scope.

### Configuration

- `.env` (git-ignored): `MYSQL_ROOT_PASSWORD`, `MYSQL_PORT`, `REDIS_PORT`
- `.env.example` (committed): documents the same keys with placeholder/
  default values

### Documentation

`README.md` at the repo root explains:

- What this stack is and when to use it
- How to start/stop it (`docker compose up -d`, `docker compose down`)
- How another project connects, both ways:
  1. Network-attach: add `shared-services` as an external network in the
     other project's compose file, attach the app service, point
     `DB_HOST=mysql` / `REDIS_HOST=redis`.
  2. Host-port: point `DB_HOST=host.docker.internal` (or the host's
     bridge IP) / `localhost`, using the published ports, with no compose
     changes needed in the other project.
- How to create a new project's database/user on demand.

## Proposed File Structure

```
core/
├── docker-compose.yml      # mysql + redis services, shared-services network, volume
├── .env.example            # committed template: MYSQL_ROOT_PASSWORD, MYSQL_PORT, REDIS_PORT
├── .env                     # git-ignored, actual local secrets/ports
├── .gitignore               # ignores .env
├── README.md                # what this is, start/stop, how other projects connect
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-08-13-shared-services-design.md   # this design doc
```

No `mysql/init/` or other provisioning-script directories are included,
since database/user creation is on-demand per the scope above.

## Out of scope

- Migrating bortex, farsons, or any other existing project to use this
  stack — left for a future, separate change in those repos.
- TLS, remote access hardening, or multi-user auth — this is a local-dev-
  only stack per current requirements. Revisit if this ever needs to run on
  a shared/remote server.
- Pre-seeded per-project databases — provisioning is manual/on-demand by
  design.

## Testing / Verification

- `docker compose up -d` brings up both services healthy
  (`docker compose ps` shows `healthy`).
- `docker exec -it core-mysql mysql -uroot -p... -e "SELECT 1"` succeeds.
- `docker exec -it core-redis redis-cli ping` returns `PONG`.
- From a throwaway container attached to the `shared-services` network,
  `mysql -h mysql -uroot -p...` and `redis-cli -h redis ping` both succeed,
  confirming container-name resolution works for consumers.
