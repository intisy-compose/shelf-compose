#!/bin/sh
# The shared gateway from intisy-compose/workflows gateway/, vendored byte for byte. Starts Caddy with
# GATEWAY_LOCAL_ADDRESSES set to this namespace's Docker network addresses, which the Caddyfile binds
# every http://:<port> site to. tailscale in userspace mode hands a tailnet connection to a port its
# serve config does not forward to 127.0.0.1, so a site that listened there would be on the tailnet.
set -eu
addresses=$(ip -4 -o addr show scope global | awk '{ sub(/\/.*/, "", $4); print $4 }' | tr '\n' ' ')
if [ -z "${addresses% }" ]; then
    echo "gateway: no Docker network address in this namespace, so no local site can be bound" >&2
    exit 1
fi
export GATEWAY_LOCAL_ADDRESSES="${addresses% }"
echo "gateway: local sites listen on $GATEWAY_LOCAL_ADDRESSES"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
