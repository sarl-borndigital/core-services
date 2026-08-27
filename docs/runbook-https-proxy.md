# Runbook — HTTPS intercept proxy

Serves files from this machine for URLs that would otherwise reach an external
server, over HTTPS, with a certificate the browser and `curl` accept.

- **Service:** `proxy` / container `core-proxy`
- **Stack:** `/home/born/projects/core/docker-compose.yml`
- **Ports:** 80 (`PROXY_HTTP_PORT`), 443 (`PROXY_HTTPS_PORT`)
- **Content:** `proxy/sites/<domain>/...`
- **Certificates:** `proxy/certs/` (git-ignored)
- **Design:** `docs/superpowers/specs/2026-08-26-https-intercept-proxy-design.md`

## Model

A directory under `proxy/sites/` *is* a domain declaration. Its name is the
host; the paths inside it are the URL paths. On every container start the
entrypoint scans that directory, issues a certificate per domain from a local
CA, and writes one nginx server block per domain plus a catch-all that answers
404.

```
proxy/sites/example.com/assets/index.css  ->  https://example.com/assets/index.css
proxy/sites/example.com/unknown.tg        ->  https://example.com/unknown.tg
```

Nothing falls through to the real server. Anything unstaged is a 404.

## First-time setup

```bash
cd /home/born/projects/core
./core.sh start                 # builds the image, mints the CA
./core.sh status                # wait for core-proxy: healthy
```

`proxy/sites/` is empty in a fresh clone — staged content is local state and is
not tracked. Stage your first domain with `./core.sh proxy add <domain>`.

Trust the CA — once, ever:

```bash
sudo cp proxy/certs/coreLocalCA.pem /usr/local/share/ca-certificates/core-local-ca.crt
sudo update-ca-certificates
```

Chrome and Firefox use their own NSS store, not the system one:

```bash
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "core local dev CA" -i proxy/certs/coreLocalCA.pem
```

Restart the browser afterwards. `./core.sh ca` reprints all of the above.

Point the domain at this machine:

```bash
./core.sh hosts                                   # prints the lines to add
sudo tee -a /etc/hosts <<< "127.0.0.1 example.com"
```

Confirm:

```bash
curl -v  https://example.com/assets/index.css     # staged file, trusted chain
curl -sI https://example.com/unknown.tg           # 200, application/octet-stream
curl -sI https://example.com/nope.js              # 404
curl -sI http://example.com/assets/index.css      # 301 to https
```

No `-k` anywhere. Needing it means the CA is not installed.

## Routine tasks

| Task | Command |
|---|---|
| Start / stop | `./core.sh start` / `./core.sh stop` |
| Status and health | `./core.sh status` |
| Tail proxy logs | `./core.sh logs proxy` |
| Add a domain end to end | `./core.sh proxy add <domain>` |
| Remove a domain end to end | `./core.sh proxy rm <domain>` |
| Reload after adding a domain | `./core.sh reload` |
| Reprint CA install steps | `./core.sh ca` |
| Print `/etc/hosts` lines | `./core.sh hosts` |

**Add a domain** — one command does all three parts:

```bash
./core.sh proxy add cdn.somewhere.io
```

It creates the site directory, appends `127.0.0.1` and `::1` entries to
`/etc/hosts` tagged `# core-proxy` (prompting for sudo, skipping any that
already exist), then reloads so the certificate and server block are issued.
Rerunning it on an existing domain is safe — it reports what is already there
and reloads.

Both address families are added deliberately: a name that also resolves
publicly often prefers IPv6, and nginx listens on `[::]:443`.

By hand:

```bash
mkdir -p proxy/sites/cdn.somewhere.io/static
cp yourfile.js proxy/sites/cdn.somewhere.io/static/
./core.sh reload
sudo tee -a /etc/hosts <<< "127.0.0.1 cdn.somewhere.io"
```

**Edit a staged file** — no reload. The directory is bind-mounted live and
responses carry `Cache-Control: no-store`.

**Remove a domain** — the reverse of `add`:

```bash
./core.sh proxy rm cdn.somewhere.io        # prompts before deleting
./core.sh proxy rm cdn.somewhere.io -f     # skip the prompt
```

It lists what will go — the site directory and its file count, the certificate
pair, the `/etc/hosts` lines — and waits for confirmation. Without a terminal
it refuses unless given `-f`, so it cannot silently delete from a script.

Only `/etc/hosts` lines tagged `# core-proxy` carrying that domain as their
sole host name are removed. A line you wrote by hand, a line another tool
wrote, or a line sharing the domain with other names is reported and left
alone. `/etc/hosts` is backed up to `/etc/hosts.core-proxy.bak` first.

By hand: `rm -rf proxy/sites/<domain>` then `./core.sh reload`.

**After a reboot** — nothing. `restart: unless-stopped` brings the stack back
with the Docker daemon. The CA persists in `proxy/certs/`, so trust survives.

## Diagnostics

```bash
docker compose logs proxy | tail -40         # entrypoint decisions, per-domain
docker exec core-proxy nginx -T              # full effective config
docker exec core-proxy nginx -t              # config syntax check
docker exec core-proxy ls /etc/nginx/conf.d  # generated server blocks

# What certificate is actually served for a host?
openssl s_client -connect 127.0.0.1:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

# Does a leaf still chain to the CA?
openssl verify -CAfile proxy/certs/coreLocalCA.pem proxy/certs/example.com.crt
```

The entrypoint logs one line per domain it serves and one per directory it
skips. If a domain is missing from the logs, it was never picked up.

## Troubleshooting

**Browser or curl reports an untrusted certificate.**
The CA is not in the store that client uses. `curl` reads the system store,
Chrome and Firefox read `~/.pki/nssdb`. Install into both (`./core.sh ca`) and
restart the browser. If it persists, confirm the served cert is the one you
think: the `s_client` command above should show issuer `CN=core local dev CA`.

**Certificate warning on a subdomain.**
Expected only for a host unrelated to any staged domain. Unstaged *subdomains*
of a staged domain are covered by the catch-all certificate. If
`cdn.example.com` warns while `example.com/` is staged, the catch-all is stale
— `./core.sh reload` reissues it.

**404 for a file that exists on disk.**
Check the path maps exactly: `proxy/sites/<domain>/<url-path>`. Then confirm
the container sees it — `docker exec core-proxy ls -l /srv/sites/<domain>/...`.
A file created after the container started is visible immediately; a *domain
directory* created after start is not, until `./core.sh reload`.

**The real site loads instead of your file.**
`/etc/hosts` is not taking effect. Check `getent hosts example.com` returns
`127.0.0.1`. Browsers cache DNS separately — restart it, or clear
`chrome://net-internals/#dns`. Note the host `/etc/hosts` does **not** apply
inside other containers; those need their own `extra_hosts`.

**Port 80 or 443 already bound.**
`docker compose up` fails with a bind error. Find the holder with
`sudo ss -ltnp | grep -E ':(80|443)\s'`. Either stop it or set
`PROXY_HTTP_PORT` / `PROXY_HTTPS_PORT` in `.env` — but a non-443 port means
the URL needs an explicit port, which usually defeats the purpose.

**Container unhealthy or restarting.**
`docker compose logs proxy` almost always names the bad directive. The
healthcheck fetches `http://127.0.0.1/_core_health` from the catch-all server;
if that fails, nginx did not start.

**Container restart-loops after adding a domain with a long name.**
`docker compose logs proxy` shows `could not build server_names_hash, you
should increase server_names_hash_bucket_size`. nginx will not start when a
`server_name` does not fit its hash bucket. The entrypoint sizes
`server_names_hash_bucket_size` from the longest staged domain and writes it to
`conf.d/zz-core-000-tuning.conf`; check that file reflects your longest name.

**Start over on certificates.**
```bash
rm -f proxy/certs/*.crt proxy/certs/*.key proxy/certs/*.srl proxy/certs/*.pem
./core.sh reload
```
This mints a **new CA**, so the old one must be removed from your trust stores
and the new one installed:
```bash
sudo rm -f /usr/local/share/ca-certificates/core-local-ca.crt && sudo update-ca-certificates --fresh
certutil -d sql:$HOME/.pki/nssdb -D -n "core local dev CA"
```

## Known limits

- Unstaged paths return 404; there is no fallback to the genuine upstream.
- A domain unrelated to any staged directory fails the handshake before the
  404. The proxy cannot certify a name it has not been told about.
- Subdomains are separate directories with their own `/etc/hosts` entry;
  there is no wildcard routing, because `/etc/hosts` has no wildcard syntax.
- Only this host is served. Other containers need `extra_hosts` plus the CA in
  their own image; other devices need their own DNS override and CA.
- Certificates are valid 825 days and reissued automatically within 30 days of
  expiry, on container start.
