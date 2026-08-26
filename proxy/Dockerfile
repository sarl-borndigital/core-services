FROM nginx:1.27-alpine

# The base image bundles the OpenSSL libraries but not the CLI, which the
# entrypoint script needs to mint the local CA and per-domain certificates.
RUN apk add --no-cache openssl

# Scripts in this directory are executed by the image's own entrypoint before
# nginx starts, so certificates and server blocks exist by the time it boots.
COPY docker-entrypoint.d/40-certs-and-vhosts.sh /docker-entrypoint.d/40-certs-and-vhosts.sh
RUN chmod +x /docker-entrypoint.d/40-certs-and-vhosts.sh

EXPOSE 80 443
