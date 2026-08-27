#!/bin/sh
# Generates a local CA, per-domain leaf certificates and nginx server blocks,
# one for every directory under /srv/sites. Runs before nginx starts.
set -eu

SITES_DIR=/srv/sites
CERT_DIR=/etc/nginx/certs
CONF_DIR=/etc/nginx/conf.d
CA_CRT="$CERT_DIR/coreLocalCA.pem"
CA_KEY="$CERT_DIR/coreLocalCA-key.pem"
CA_CN="core local dev CA"

log() { echo "$0: $*"; }

mkdir -p "$CERT_DIR"

# --- local certificate authority (created once, kept on the host mount) ------
if [ ! -f "$CA_CRT" ] || [ ! -f "$CA_KEY" ]; then
  log "generating local CA"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "$CA_KEY" -out "$CA_CRT" \
    -subj "/O=core shared services/CN=$CA_CN" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1
  chmod 600 "$CA_KEY"
  chmod 644 "$CA_CRT"
fi

# --- issue a leaf certificate for one name ----------------------------------
# issue_cert <name> <san-list> [force]
# Without 'force', an existing certificate is kept unless it expires within
# 30 days.
issue_cert() {
  name="$1"
  san="$2"
  force="${3:-}"
  crt="$CERT_DIR/$name.crt"
  key="$CERT_DIR/$name.key"

  if [ -z "$force" ] && [ -f "$crt" ] && [ -f "$key" ]; then
    if openssl x509 -checkend 2592000 -noout -in "$crt" >/dev/null 2>&1; then
      return 0
    fi
    log "certificate for $name is expiring, reissuing"
  fi

  ext=$(mktemp)
  csr=$(mktemp)
  cat > "$ext" <<EXT
subjectAltName=$san
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EXT

  openssl req -newkey rsa:2048 -nodes -keyout "$key" -out "$csr" \
    -subj "/CN=$name" >/dev/null 2>&1
  openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -days 825 -sha256 -extfile "$ext" -out "$crt" >/dev/null 2>&1

  chmod 600 "$key"
  chmod 644 "$crt"
  rm -f "$ext" "$csr"
}

# --- server block template --------------------------------------------------
TEMPLATE=$(mktemp)
cat > "$TEMPLATE" <<'TPL'
server {
    listen      80;
    listen      [::]:80;
    server_name __DOMAIN__;
    return 301 https://$host$request_uri;
}

server {
    listen      443 ssl;
    listen      [::]:443 ssl;
    http2       on;
    server_name __DOMAIN__;

    ssl_certificate     /etc/nginx/certs/__DOMAIN__.crt;
    ssl_certificate_key /etc/nginx/certs/__DOMAIN__.key;

    root /srv/sites/__DOMAIN__;

    # Files with an extension nginx has no mapping for (.tg, .bin, ...) are
    # served as a generic binary stream. To pin a type for your own extension,
    # add a types {} block here, e.g.  types { application/json tg; }
    default_type application/octet-stream;

    # Intercepted content should never be cached by the client, otherwise
    # editing a staged file appears to do nothing.
    add_header Cache-Control "no-store" always;
    add_header Access-Control-Allow-Origin "*" always;

    access_log /var/log/nginx/access.log;

    location / {
        autoindex off;
        try_files $uri $uri/index.html =404;
    }
}
TPL

rm -f "$CONF_DIR"/default.conf
rm -f "$CONF_DIR"/zz-core-*.conf

# --- pass 1: one vhost per directory under /srv/sites -----------------------
domains=""
count=0
maxlen=0
if [ -d "$SITES_DIR" ]; then
  for dir in "$SITES_DIR"/*/; do
    [ -d "$dir" ] || continue
    domain=$(basename "$dir")

    case "$domain" in
      .*|_*) continue ;;
      *[!a-zA-Z0-9.-]*)
        log "skipping '$domain': not a valid host name"
        continue
        ;;
    esac

    issue_cert "$domain" "DNS:$domain,DNS:*.$domain"
    sed "s/__DOMAIN__/$domain/g" "$TEMPLATE" > "$CONF_DIR/zz-core-$domain.conf"
    domains="$domains $domain"
    count=$((count + 1))
    [ "${#domain}" -gt "$maxlen" ] && maxlen=${#domain}
    log "serving https://$domain from $dir"
  done
fi

rm -f "$TEMPLATE"

# --- http-level tuning ------------------------------------------------------
# nginx refuses to start ("could not build server_names_hash") when a
# server_name does not fit its hash bucket, and the 64-byte default is smaller
# than plenty of real CDN host names. Size it from the longest staged name.
bucket=64
while [ $((bucket - 32)) -lt "$maxlen" ] && [ "$bucket" -lt 1024 ]; do
  bucket=$((bucket * 2))
done

cat > "$CONF_DIR/zz-core-000-tuning.conf" <<TUNE
# Generated: longest staged domain is $maxlen characters.
server_names_hash_bucket_size $bucket;
TUNE

# --- pass 2: catch-all for every host that matched no vhost above -----------
# Its certificate covers the wildcard of each staged domain, so an unstaged
# subdomain (https://cdn.example.com when only example.com/ exists) completes
# the handshake and gets a plain 404, instead of a certificate warning that
# looks like the proxy is broken. Reissued on every boot because the set of
# staged domains changes as directories are added and removed.
default_san="DNS:invalid.core.local"
for domain in $domains; do
  default_san="$default_san,DNS:*.$domain"
done
issue_cert "default" "$default_san" force

cat > "$CONF_DIR/zz-core-000-default.conf" <<'DEFAULT'
server {
    listen      80 default_server;
    listen      [::]:80 default_server;
    server_name _;

    location = /_core_health { return 200 "ok\n"; }
    location / { return 404; }
}

server {
    listen      443 ssl default_server;
    listen      [::]:443 ssl default_server;
    http2       on;
    server_name _;

    ssl_certificate     /etc/nginx/certs/default.crt;
    ssl_certificate_key /etc/nginx/certs/default.key;

    return 404;
}
DEFAULT

if [ "$count" -eq 0 ]; then
  log "no site directories found under $SITES_DIR; every host returns 404"
else
  log "catch-all certificate covers unstaged subdomains of:$domains"
fi

log "CA certificate for your trust store: $CA_CRT"
