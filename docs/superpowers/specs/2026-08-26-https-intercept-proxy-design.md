# HTTPS Intercept Proxy — Design

**Date:** 2026-08-26
**Status:** Approved

## Problem

During development we sometimes need a file that a page fetches from an
external host to come from this machine instead — a stylesheet, a script, a
binary blob with an arbitrary extension. Editing the page to point elsewhere is
not always possible, and the URL is HTTPS, so simply pointing the domain at
`127.0.0.1` in `/etc/hosts` fails the TLS handshake.

We want `https://example.com/assets/index.css` and
`https://example.com/unknown.tg` to resolve to files on disk, with a
certificate the browser and `curl` accept.

## Scope

In scope:

- Terminating TLS for arbitrary domains inside Docker, with no host tooling
  beyond Docker itself.
- Serving any path and any file extension from a local directory.
- Certificate trust that works for a normal browser and `curl` on this host.

Out of scope:

- Forwarding unmatched paths to the genuine upstream server. Anything not
  staged locally returns 404. This keeps the stack fully offline and makes it
  obvious what is being intercepted.
- Consumers other than this host's browser and CLI. Other containers and other
  devices on the LAN are not addressed; both would need their own name
  resolution and their own copy of the CA.

## Design

A single `proxy` service is added to the existing shared-services stack:
nginx on Alpine, publishing ports 80 and 443, attached to the
`shared-services` network with `restart: unless-stopped`, matching mysql and
redis.

### Domains are declared by directory

```
proxy/sites/example.com/assets/index.css   ->  https://example.com/assets/index.css
proxy/sites/example.com/unknown.tg         ->  https://example.com/unknown.tg
```

The directory name *is* the domain. There is no separate list of domains to
keep in sync with the files on disk, and adding a domain never touches the
compose file.

### Certificates are minted in the container

The nginx image executes `/docker-entrypoint.d/*.sh` before starting. Our
script, on every boot:

1. Creates a local CA in `proxy/certs/` if one is not already there — RSA
   4096, ten years, constrained to `CA:TRUE, pathlen:0` and cert signing.
2. Issues a leaf certificate per domain directory — RSA 2048, 825 days, SAN
   `DNS:<domain>, DNS:*.<domain>`, `serverAuth` only. Existing certificates
   are reused unless they expire within 30 days.
3. Writes one nginx server block per domain, plus a catch-all.

`proxy/certs/` is a host bind mount, so the CA survives restarts and container
rebuilds and can be installed into the host trust store once.

### Request handling

Per domain: port 80 redirects to HTTPS; port 443 serves
`root /srv/sites/<domain>` with `try_files $uri $uri/index.html =404`.

Unknown extensions have no entry in nginx's MIME table, so `default_type
application/octet-stream` covers them. Known types still resolve normally. A
`types {}` block can pin a specific type per domain when a client is strict.

Responses carry `Cache-Control: no-store` — a cached intercepted asset makes
editing a staged file look like it did nothing — and
`Access-Control-Allow-Origin: *`, since the intercepted origin usually differs
from the page's.

The `default_server` on both ports answers unknown host names with 404. Its
certificate is signed by the same CA and carries `DNS:*.<domain>` for every
staged domain, so an unstaged subdomain completes the handshake and receives a
plain 404 instead of a certificate warning that reads as a broken proxy. That
SAN list depends on the directory scan, so the catch-all certificate is issued
in a second pass and reissued on every boot; per-domain certificates are
reused. A host unrelated to any staged domain still fails the handshake, which
is unavoidable — the proxy has no name to certify. The catch-all also exposes
`/_core_health` for the compose healthcheck.

Subdomains are supported as their own directories, not by wildcard routing.
`/etc/hosts` has no wildcard syntax, so each subdomain needs an entry there
regardless; once that is true, a directory per subdomain costs nothing extra
and keeps the staged set explicit.

### Trust

Installing the CA is a manual, one-time step, deliberately left to the user
rather than automated: it modifies the host trust store. `./core.sh ca` prints
the CA path and the exact commands for the system store and the NSS store used
by Chrome and Firefox.

## Interface

| Command | Effect |
|---|---|
| `./core.sh start` | Builds and starts the stack, generating certs and vhosts |
| `./core.sh reload` | Rebuilds and restarts the proxy after adding a domain |
| `./core.sh ca` | Prints the CA path and trust-store install commands |
| `./core.sh hosts` | Prints the `/etc/hosts` lines for the staged domains |

Adding a domain: create `proxy/sites/<domain>/`, drop files in, `./core.sh
reload`, add the `/etc/hosts` line.

## Verification

- `curl https://example.com/assets/index.css` returns the staged file with a
  chain that validates against the installed CA.
- `curl https://example.com/unknown.tg` returns the file as
  `application/octet-stream`.
- An unstaged path under a staged domain returns 404.
- An unstaged domain pointed at 127.0.0.1 returns 404.
- `http://example.com/...` redirects to HTTPS.
