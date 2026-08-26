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
| mysql   | `core-mysql`    | `mysql:8.0`     | `3310` (`MYSQL_PORT`) |
| redis   | `core-redis`    | `redis:7-alpine`| `6380` (`REDIS_PORT`) |
| proxy   | `core-proxy`    | built from `./proxy` | `80` (`PROXY_HTTP_PORT`), `443` (`PROXY_HTTPS_PORT`) |

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
| `./core.sh proxy add <domain>` | Create the site dir, add `/etc/hosts` entries, reload |
| `./core.sh proxy rm <domain>`  | Remove the site dir, certs and `/etc/hosts` entries      |
| `./core.sh reload`      | Rebuild/restart the proxy after adding a domain folder   |
| `./core.sh ca`          | Print the local CA path and trust-store install commands |
| `./core.sh hosts`       | Print the `/etc/hosts` lines for the staged domains      |

## HTTPS intercept proxy

Serves files from this machine for URLs that would otherwise hit an external
server, over HTTPS, with a certificate your browser and `curl` accept. Useful
when you need to swap one asset on a page you cannot edit.

### Staging a file

A directory under `proxy/sites/` **is** the domain declaration — its name is
the host, and the paths inside it are the URL paths:

```
proxy/sites/example.com/assets/index.css   ->  https://example.com/assets/index.css
proxy/sites/example.com/unknown.tg         ->  https://example.com/unknown.tg
```

Any path, any extension. Extensions nginx does not recognise are served as
`application/octet-stream`; to pin a type for one of your own, add a `types {}`
block to the template in `proxy/docker-entrypoint.d/40-certs-and-vhosts.sh`.

### First run

`proxy/sites/` is empty in a fresh clone — staged content is local state, not
tracked. Stage a domain first, which also mints the CA:

```bash
./core.sh proxy add example.com     # creates the dir, adds /etc/hosts, reloads
./core.sh ca                        # prints the CA path and how to install it
```

Install the CA once (the `ca` command prints these for you):

```bash
sudo cp proxy/certs/coreLocalCA.pem /usr/local/share/ca-certificates/core-local-ca.crt
sudo update-ca-certificates
```

Chrome and Firefox read their own NSS store rather than the system one:

```bash
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "core local dev CA" -i proxy/certs/coreLocalCA.pem
```

`proxy add` already wrote the `/etc/hosts` entries. Drop a file in and check it:

```bash
mkdir -p proxy/sites/example.com/assets
echo 'body { outline: 2px solid red; }' > proxy/sites/example.com/assets/index.css
curl -v https://example.com/assets/index.css
```

### Adding another domain

```bash
./core.sh proxy add cdn.somewhere.io
```

That creates `proxy/sites/cdn.somewhere.io/`, adds `127.0.0.1` and `::1`
entries to `/etc/hosts` (prompting for sudo, and skipping any that already
exist), then reloads the proxy so the certificate and server block are issued.
Drop your files in and they are live.

Doing it by hand is the same three steps:

```bash
mkdir -p proxy/sites/cdn.somewhere.io/static
cp mything.js proxy/sites/cdn.somewhere.io/static/
./core.sh reload
sudo tee -a /etc/hosts <<< "127.0.0.1 cdn.somewhere.io"
```

Subdomains are separate directories with their own `/etc/hosts` entry —
`cdn.example.com` is not covered by `example.com`.

### Behaviour and limits

- Anything not staged returns **404** — the proxy never falls back to the real
  server, so an intercepted domain is fully offline.
- An unstaged **subdomain** of a staged domain (`cdn.example.com` when only
  `example.com/` exists) gets a clean 404 rather than a certificate warning:
  the catch-all's certificate carries `*.<domain>` for every staged domain and
  is reissued whenever you add or remove one. A domain with no relation to any
  staged directory still produces a certificate warning first — the proxy
  cannot hold a certificate for a name it has never been told about.
- Responses are sent with `Cache-Control: no-store` and
  `Access-Control-Allow-Origin: *`.
- Port 80 redirects to HTTPS for staged domains.
- `/etc/hosts` on this host does **not** apply inside other containers. A
  container that needs an intercepted domain requires its own `extra_hosts`
  entry pointing at the proxy, and the CA installed in that image.
- Certificates live in `proxy/certs/`, which is git-ignored. Delete a `.crt`
  and `.key` pair and reload to reissue it; delete `coreLocalCA*` to start over
  (you must then reinstall the CA).

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
