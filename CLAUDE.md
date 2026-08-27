# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A standalone Docker Compose stack providing shared MySQL, Redis, and an HTTPS
intercept proxy for local development, so other project stacks (bortex,
farsons, future projects) connect to shared services instead of each running
their own. This repo only stands up the shared services — it never modifies
another project's compose files; wiring a project to use these services is a
change made in that project's own repo.

There is no application code, package manager, build step, or test suite
here — the repo is Docker Compose config, a bash CLI (`core.sh`), and an
nginx image built from `proxy/`.

## Commands

All interaction goes through `./core.sh`, a thin wrapper around `docker
compose` (see `core.sh` for the full implementation):

```bash
cp .env.example .env      # first-time setup; adjust MYSQL_ROOT_PASSWORD / ports
./core.sh start            # docker compose up -d --build
./core.sh status            # container/health status — wait for "healthy"
./core.sh stop / restart / down
./core.sh logs [mysql|redis|proxy]
./core.sh mysql             # mysql shell in core-mysql as root
./core.sh redis             # redis-cli shell in core-redis
./core.sh proxy add <domain>   # stage a domain: create dir, /etc/hosts, reload
./core.sh proxy rm <domain>    # reverse of add; prompts unless -f
./core.sh reload            # rebuild/restart the proxy after adding a site dir
./core.sh ca                # print local CA path + trust-store install commands
./core.sh hosts              # print /etc/hosts lines for all staged domains
```

`reload` always uses `--force-recreate` on the `proxy` service — adding a
site directory changes neither the compose config nor the image, so a plain
`up -d` would leave the stale container running and the entrypoint would
never re-execute.

## Architecture

Three services on a single Docker bridge network named `shared-services`
(created by this stack, `restart: unless-stopped` on all of them):

- **mysql** (`core-mysql`, `mysql:8.0`) — host port `MYSQL_PORT` (default 3310)
- **redis** (`core-redis`, `redis:7-alpine`) — host port `REDIS_PORT` (default 6380)
- **proxy** (`core-proxy`, built from `./proxy`) — ports `PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT` (default 80/443)

Other projects connect either by attaching their own compose service to the
external `shared-services` network (container-to-container, using service
names `mysql`/`redis` as hosts), or via the published host ports / Docker
gateway IP for non-Docker or differently-networked stacks. See the README's
"Connecting another project" section for both recipes.

Database/user provisioning is on-demand — nothing is pre-created per
project. Redis has no per-project auth/namespacing; projects that need
isolation pick different logical DB indexes (0-15) via `redis-cli -n N`.

### HTTPS intercept proxy (`proxy/`)

Serves local files over HTTPS, with a browser/curl-trusted cert, for domains
that would otherwise hit a real external server — used to swap one asset on
a page you can't edit. Full detail in `docs/runbook-https-proxy.md`; design
rationale in `docs/superpowers/specs/2026-08-26-https-intercept-proxy-design.md`.

**Core model:** a directory under `proxy/sites/` *is* the domain
declaration. Its name is the host; the paths inside it are URL paths
(`proxy/sites/example.com/assets/index.css` -> `https://example.com/assets/index.css`).
`proxy/sites/` is empty in a fresh clone — staged content is local, untracked
state (git-ignored). Nothing not staged ever falls back to the real
upstream: unstaged paths are a 404, so an intercepted domain is fully
offline for anything you haven't dropped in.

**Boot-time generation** (`proxy/docker-entrypoint.d/40-certs-and-vhosts.sh`,
runs before nginx starts, on every container start):
1. Mints a local CA on first run (kept on the host mount at
   `proxy/certs/coreLocalCA*`, git-ignored, so it survives rebuilds).
2. For every directory under `/srv/sites` (bind-mounted from `proxy/sites/`),
   issues a leaf cert (`DNS:<domain>,DNS:*.<domain>`) and writes an nginx
   server block (`conf.d/zz-core-<domain>.conf`) redirecting :80 -> :443 and
   serving `/srv/sites/<domain>` on :443. Certs are reused unless within 30
   days of expiry (825-day validity); pass `force` to `issue_cert` to always
   reissue (used for the catch-all).
3. Sizes `server_names_hash_bucket_size` from the longest staged domain name
   (nginx refuses to start otherwise) and writes it to
   `conf.d/zz-core-000-tuning.conf`.
4. Issues a **catch-all** default server (`conf.d/zz-core-000-default.conf`)
   whose cert SAN covers `*.<domain>` for every staged domain — so an
   *unstaged subdomain* of a staged domain still completes the TLS
   handshake and gets a clean 404, instead of a certificate warning. A
   domain with no relation to any staged directory still warns first,
   because the proxy has never been told to certify that name. This
   catch-all is always reissued on boot since the staged-domain set changes.

Editing a staged file needs no reload — `proxy/sites` is bind-mounted live
and responses carry `Cache-Control: no-store`. Only *adding/removing a site
directory* requires `./core.sh reload` (new certs + server blocks must be
generated). To pin a MIME type for an extension nginx doesn't recognize
(default is `application/octet-stream`), add a `types {}` block to the
template inside `40-certs-and-vhosts.sh`.

`/etc/hosts` on the host does not apply inside other containers — a
container that needs an intercepted domain needs its own `extra_hosts`
entry pointing at the proxy, and the CA installed in that image.

`core.sh proxy add/rm` are the only supported way to touch `/etc/hosts`
programmatically: entries are tagged `# core-proxy` and `rm` only ever
deletes lines it can prove it owns (tagged, and carrying that domain as
their *only* host). Anything else mentioning the domain (hand-edited lines,
lines shared with other hostnames) is reported and left alone;
`/etc/hosts` is backed up to `/etc/hosts.core-proxy.bak` before any removal.

## Docs layout

- `README.md` — user-facing setup and usage (source of truth for commands).
- `docs/runbook-https-proxy.md` — operational runbook for the proxy:
  first-time setup, routine tasks, diagnostics, troubleshooting, known limits.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` — design specs and
  implementation plans written during feature development (e.g. the
  shared-services stack and the HTTPS intercept proxy). Useful for the *why*
  behind a design decision, not for current operational instructions.
