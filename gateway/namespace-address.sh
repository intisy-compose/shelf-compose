#!/bin/sh
# The shared gateway from intisy-compose/workflows gateway/, vendored byte for byte.
# namespace-address.sh [--single]: prints this network namespace's Docker network IPv4 addresses, space
# separated, read from /proc so it runs in any image with sh and awk. gateway.sh binds the local sites
# to them, and an app in the gateway's namespace binds one with --single, which fails unless there is
# exactly one: the gateway reaches that app as gateway:<port>, which Docker resolves to it.
set -eu
addresses=$(awk '
    /\|--/ { address = $2; next }
    /\/32 host LOCAL/ && address !~ /^127\./ && !seen[address]++ { printf "%s ", address }
' /proc/net/fib_trie)
addresses=${addresses% }
if [ -z "$addresses" ]; then
    echo "namespace-address: no Docker network address in this namespace" >&2
    exit 1
fi
if [ "${1:-}" = --single ] && [ "$addresses" != "${addresses%% *}" ]; then
    echo "namespace-address: this namespace has several Docker network addresses ($addresses); an app binds one" >&2
    exit 1
fi
echo "$addresses"
