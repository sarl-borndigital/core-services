#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
  echo "Usage: $0 {start|stop|restart|down|status|logs [service]|mysql|redis|reload|ca|hosts|proxy add|rm <domain>}"
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
    docker compose up -d --build
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
  reload)
    # --force-recreate is required: adding a site directory changes neither
    # the compose config nor the image, so a plain 'up -d' would leave the
    # container running and the entrypoint would never re-run.
    docker compose up -d --build --force-recreate proxy
    ;;
  ca)
    ca="$SCRIPT_DIR/proxy/certs/coreLocalCA.pem"
    if [ ! -f "$ca" ]; then
      echo "CA not generated yet. Run './core.sh start' first." >&2
      exit 1
    fi
    echo "CA certificate: $ca"
    echo
    echo "System trust store (Debian/Ubuntu):"
    echo "  sudo cp '$ca' /usr/local/share/ca-certificates/core-local-ca.crt"
    echo "  sudo update-ca-certificates"
    echo
    echo "Chrome / Chromium / Firefox (NSS store, no sudo):"
    echo "  certutil -d sql:\$HOME/.pki/nssdb -A -t 'C,,' -n 'core local dev CA' -i '$ca'"
    echo
    echo "Firefox may also need it under Settings > Privacy & Security >"
    echo "Certificates > View Certificates > Authorities > Import."
    ;;
  hosts)
    echo "# Add to /etc/hosts:"
    for dir in "$SCRIPT_DIR"/proxy/sites/*/; do
      [ -d "$dir" ] || continue
      echo "127.0.0.1 $(basename "$dir")"
    done
    ;;
  proxy)
    sub="${1:-}"
    shift 2>/dev/null || true

    case "$sub" in
      add)
        domain="${1:-}"
        if [ -z "$domain" ]; then
          echo "Usage: $0 proxy add <domain>" >&2
          exit 1
        fi

        # The same host-name rule the proxy entrypoint applies when it scans
        # sites/. Rejecting here gives a useful error instead of a directory
        # the proxy silently skips.
        if ! printf '%s' "$domain" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
          echo "Not a valid host name: $domain" >&2
          exit 1
        fi

        dir="$SCRIPT_DIR/proxy/sites/$domain"
        if [ -d "$dir" ]; then
          echo "Site directory already present: proxy/sites/$domain"
        else
          mkdir -p "$dir"
          echo "Created proxy/sites/$domain"
        fi

        # /etc/hosts needs both families: a name that resolves to a real host
        # often prefers IPv6, and nginx listens on [::]:443 too.
        if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
        added=0
        for ip in 127.0.0.1 ::1; do
          if awk -v ip="$ip" -v d="$domain" \
               '$1 == ip { for (i = 2; i <= NF; i++) if ($i == d) found = 1 }
                END { exit !found }' /etc/hosts; then
            echo "/etc/hosts already maps $ip -> $domain"
            continue
          fi
          if [ "$added" -eq 0 ]; then
            echo "Adding $domain to /etc/hosts (may prompt for your password)"
          fi
          printf '%s\t%s\t# core-proxy\n' "$ip" "$domain" \
            | $SUDO tee -a /etc/hosts >/dev/null
          added=$((added + 1))
        done
        [ "$added" -gt 0 ] && echo "Added $added /etc/hosts entry/entries"

        # Issues the certificate and writes the server block.
        "$0" reload

        echo
        echo "Ready. Files map straight onto URL paths:"
        echo "  proxy/sites/$domain/assets/app.js  ->  https://$domain/assets/app.js"
        ;;
      rm|remove)
        force=""
        domain=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -f|--force) force=1 ;;
            -*) echo "Unknown option: $1" >&2; exit 1 ;;
            *)  domain="$1" ;;
          esac
          shift
        done

        if [ -z "$domain" ]; then
          echo "Usage: $0 proxy rm <domain> [-f]" >&2
          exit 1
        fi
        if ! printf '%s' "$domain" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
          echo "Not a valid host name: $domain" >&2
          exit 1
        fi

        dir="$SCRIPT_DIR/proxy/sites/$domain"
        certs="$SCRIPT_DIR/proxy/certs"

        # Only lines this script wrote are safe to delete automatically: tagged
        # '# core-proxy' and carrying this domain as their only host name.
        owned=$(awk -v d="$domain" \
          '$2 == d && $3 == "#" && $4 == "core-proxy" { print "  " $0 }' /etc/hosts)
        # Anything else mentioning the domain is the user's own edit; report it
        # rather than touching it.
        foreign=$(awk -v d="$domain" '
          $2 == d && $3 == "#" && $4 == "core-proxy" { next }
          { for (i = 2; i <= NF; i++) { if ($i == "#") break; if ($i == d) { print "  " $0; break } } }
        ' /etc/hosts)

        nfiles=0
        [ -d "$dir" ] && nfiles=$(find "$dir" -type f | wc -l | tr -d ' ')

        if [ ! -d "$dir" ] && [ -z "$owned" ]; then
          echo "Nothing to remove: no proxy/sites/$domain and no core-proxy hosts entry."
          exit 0
        fi

        echo "About to remove $domain:"
        if [ -d "$dir" ]; then
          echo "  proxy/sites/$domain  ($nfiles file(s))"
        fi
        [ -f "$certs/$domain.crt" ] && echo "  proxy/certs/$domain.crt + .key"
        if [ -n "$owned" ]; then
          echo "  /etc/hosts:"
          echo "$owned"
        fi

        if [ -z "$force" ]; then
          if [ ! -t 0 ]; then
            echo "Refusing to remove non-interactively without -f." >&2
            exit 1
          fi
          printf 'Proceed? [y/N] '
          read -r reply || reply=""
          case "$reply" in
            y|Y|yes|YES) ;;
            *) echo "Aborted."; exit 1 ;;
          esac
        fi

        if [ -d "$dir" ]; then
          rm -rf "$dir"
          echo "Removed proxy/sites/$domain"
        fi
        rm -f "$certs/$domain.crt" "$certs/$domain.key"

        if [ -n "$owned" ]; then
          if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
          tmp=$(mktemp)
          awk -v d="$domain" \
            '!($2 == d && $3 == "#" && $4 == "core-proxy")' /etc/hosts > "$tmp"
          $SUDO cp /etc/hosts /etc/hosts.core-proxy.bak
          $SUDO cp "$tmp" /etc/hosts
          rm -f "$tmp"
          echo "Removed /etc/hosts entries (backup at /etc/hosts.core-proxy.bak)"
        fi

        if [ -n "$foreign" ]; then
          echo
          echo "Left alone — /etc/hosts lines not written by core-proxy:"
          echo "$foreign"
        fi

        "$0" reload
        ;;
      *)
        echo "Usage: $0 proxy add|rm <domain>" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    usage
    ;;
esac
