#!/bin/sh
# The shared gateway from intisy-compose/workflows gateway/, vendored byte for byte. Writes the serve
# config tailscale reads from the stack's serve.json and, when PUBLIC_ACCESS is on, opens Funnel on
# every forwarded port Funnel can carry (443, 8443, 10000), then starts tailscale.
set -eu
stack_config=/config/serve.json
serve_config=${TS_SERVE_CONFIG:?}

case $(echo "${PUBLIC_ACCESS:-false}" | tr '[:upper:]' '[:lower:]') in
    1 | true | yes | on) public=true ;;
    *) public=false ;;
esac

funnel_ports=$(grep -oE '"(443|8443|10000)"[[:space:]]*:' "$stack_config" | grep -oE '[0-9]+' || true)
if [ "$public" = true ] && [ -n "$funnel_ports" ]; then
    allowed=$(for port in $funnel_ports; do printf '    "${TS_CERT_DOMAIN}:%s": true,\n' "$port"; done | sed '$ s/,$//')
    sed '$ d' "$stack_config" | sed '$ s/}[[:space:]]*$/},/' >"$serve_config"
    printf '  "AllowFunnel": {\n%s\n  }\n}\n' "$allowed" >>"$serve_config"
    echo "PUBLIC_ACCESS is on: Funnel opens port(s) $(echo $funnel_ports) to the internet"
else
    cp "$stack_config" "$serve_config"
fi

exec /usr/local/bin/containerboot
