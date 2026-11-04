#!/usr/bin/env bash
# shellcheck disable=SC2016 # patterns and fixtures hold a literal $
# The Linux CLI's tests: each case copies the CLI into a scratch stack and runs it against a fake
# docker, git and python3 first on PATH, so nothing on the host is touched. Plain bash: an `ok` or
# `FAIL` line per case, non-zero exit on any failure.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repository=$(cd "$here/../.." && pwd)
fakes="$here/fakes"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
stack="$scratch/shelf-compose"
state="$scratch/state"
REAL_PYTHON3=$(command -v python3)
export REAL_PYTHON3

failures=0
case_name=""
case_failed=false
output=""
status=0
extra_path=""

new_stack() {
    rm -rf "$stack" "$state"
    mkdir -p "$stack/scripts" "$stack/data/backups" "$stack/data/secrets" "$state"
    cp "$repository/docker-compose.sh" "$repository/docker-compose.yml" "$repository/config.env.example" "$stack/"
    cp "$repository"/scripts/*.sh "$stack/scripts/"
    chmod +x "$stack/docker-compose.sh"
    : >"$state/calls"
    printf '%s' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef >"$stack/data/secrets/pgsodium_root.key"
    write_filled_config
}

write_filled_config() {
    printf '%s\n' TS_AUTHKEY=tskey-test TS_HOSTNAME=shelf SHELF_HOST= SERVER_URL= SUPABASE_URL= \
        POSTGRES_PASSWORD=pg JWT_SECRET=jwt ANON_KEY=anon SERVICE_ROLE_KEY=service SESSION_SECRET=session \
        INVITE_TOKEN_SECRET=invite FINGERPRINT=fingerprint BACKUP_KEEP=48 >"$stack/config.env"
}

begin() {
    case_name=$1
    case_failed=false
    output=""
    extra_path=""
    new_stack
}

finish() {
    if $case_failed; then
        failures=$((failures + 1))
        printf '     %s\n' "${output//$'\n'/$'\n'     }"
    else
        echo "ok   $case_name"
    fi
}

# run_cli ARGUMENTS...: runs the scratch CLI with the fakes, keeping its output and exit code.
run_cli() {
    output=$(cd "$scratch" && PATH="${extra_path:+$extra_path:}$fakes:$PATH" FAKE_DOCKER_DIR="$state" FAKE_BACKUPS="$stack/data/backups" \
        bash "$stack/docker-compose.sh" "$@" 2>&1)
    status=$?
}

check() {
    local description=$1
    shift
    if ! "$@"; then
        $case_failed || echo "FAIL $case_name"
        echo "     - $description"
        case_failed=true
    fi
}

status_is() { [ "$status" -eq "$1" ]; }
said() { grep -qF -- "$1" <<<"$output"; }
not_said() { ! said "$1"; }
called() { grep -qE -- "$1" "$state/calls"; }
not_called() { ! called "$1"; }
call_count_is() { [ "$(grep -cE -- "$1" "$state/calls")" -eq "$2" ]; }
config_has() { grep -qxF -- "$1" "$stack/config.env"; }

# called_before FIRST SECOND: the first call matching FIRST comes before the first matching SECOND.
called_before() {
    local first second
    first=$(grep -nE -- "$1" "$state/calls" | head -n 1 | cut -d: -f1)
    second=$(grep -nE -- "$2" "$state/calls" | head -n 1 | cut -d: -f1)
    [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
}

# add_dump NAME [AGE_SECONDS]: a complete dump in the scratch stack's data/backups.
add_dump() {
    printf 'PGDMP fake dump' >"$stack/data/backups/$1"
    touch -d "@$(($(date +%s) - ${2:-600}))" "$stack/data/backups/$1"
}

set_state() { printf '%s\n' "${@:2}" >"$state/$1"; }

ps1_commands() {
    tr -d '\r' <"$repository/docker-compose.ps1" | awk '
        /^\$usage[[:space:]]*=[[:space:]]*@\{/ { inside = 1; next }
        inside && /^\}/ { exit }
        inside && /^[[:space:]]*"[^"]+"[[:space:]]*=/ { key = $0; sub(/^[[:space:]]*"/, "", key); sub(/".*/, "", key); print key }'
}

config_value_of() { sed -n "s/^$1=//p" "$stack/config.env" | tail -n 1; }

# jwt_is_valid TOKEN ROLE SECRET: the token is HS256-signed with SECRET, for ROLE, valid for ten years.
jwt_is_valid() {
    "$REAL_PYTHON3" - "$1" "$2" "$3" <<'EOF'
import base64, hashlib, hmac, json, sys
token, role, secret = sys.argv[1:]
header, payload, signature = token.split(".")
def decode(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
expected = hmac.new(secret.encode(), (header + "." + payload).encode(), hashlib.sha256).digest()
claims = json.loads(decode(payload))
ok = (hmac.compare_digest(decode(signature), expected)
      and json.loads(decode(header)) == {"alg": "HS256", "typ": "JWT"}
      and claims["role"] == role and claims["iss"] == "supabase"
      and claims["exp"] - claims["iat"] == 10 * 365 * 24 * 3600)
sys.exit(0 if ok else 1)
EOF
}

## Skeleton

begin "the usage lists every command of the ps1's usage table"
run_cli help
check "exits 1" status_is 1
while IFS= read -r command; do
    check "usage names $command" grep -qE "^  $command " <<<"$output"
done < <(ps1_commands)
finish

begin "an unknown command shows the usage"
run_cli frobnicate
check "exits 1" status_is 1
check "prints the usage" said "Usage: ./docker-compose.sh ["
check "calls no docker" not_called .
finish

begin "an unknown option shows the usage and starts nothing"
run_cli up --bogus
check "exits 1" status_is 1
check "prints the usage" said "Usage: ./docker-compose.sh ["
check "calls no docker" not_called .
finish

begin "an empty command shows the usage instead of running up"
run_cli ""
check "exits 1" status_is 1
check "prints the usage" said "Usage: ./docker-compose.sh ["
check "calls no docker" not_called .
finish

begin "--fresh alone is not a command"
run_cli --fresh
check "exits 1" status_is 1
check "calls no docker" not_called .
finish

begin "the PowerShell spelling -Fresh is an unknown option"
run_cli up -Fresh
check "exits 1" status_is 1
check "calls no docker" not_called .
finish

begin "a command without options refuses one"
run_cli down --force
check "exits 1" status_is 1
check "calls no compose down" not_called "^compose down"
finish

begin "COMPOSE_PROJECT_NAME is unset"
output=$(cd "$scratch" && COMPOSE_PROJECT_NAME=elsewhere PATH="$fakes:$PATH" FAKE_DOCKER_DIR="$state" \
    bash "$stack/docker-compose.sh" status 2>&1)
check "docker never sees it" grep -qx unset "$state/compose-project-name"
finish

begin "the command is case-insensitive, as in the ps1"
run_cli STATUS
check "runs compose ps -a" called "^compose ps -a$"
finish

begin "every command without the stack dispatches to its compose call"
run_cli down
check "down runs compose down" called "^compose down$"
check "down says so" said "Stopping everything..."
run_cli status
check "status runs compose ps -a" called "^compose ps -a$"
run_cli logs shelf
check "logs follows the named service" called "^compose logs -f shelf$"
finish

begin "url prints the tailnet URLs from config.env"
printf '%s\n' SERVER_URL=https://shelf.tail-test.ts.net SUPABASE_URL=https://shelf.tail-test.ts.net:8443 >>"$stack/config.env"
run_cli url
check "exits 0" status_is 0
check "prints the shelf URL" said "shelf          : https://shelf.tail-test.ts.net   (from any device on your tailnet)"
check "prints the Supabase URL" said "Supabase       : https://shelf.tail-test.ts.net:8443"
finish

begin "a command that needs config.env refuses without one"
rm "$stack/config.env"
run_cli backup
check "exits 1" status_is 1
check "names init-config" said "No config.env - run './docker-compose.sh init-config' first."
finish

begin "a missing secret is named"
sed -i 's/^FINGERPRINT=.*/FINGERPRINT=/' "$stack/config.env"
run_cli backup
check "exits 1" status_is 1
check "names the secret" said "config.env is missing: FINGERPRINT - run init-config."
finish

## init-config

begin "init-config creates config.env with every secret, with LF endings"
rm "$stack/config.env"
run_cli init-config
check "exits 0" status_is 0
check "names every generated value" said "Generated ANON_KEY, FINGERPRINT, INVITE_TOKEN_SECRET, JWT_SECRET, POSTGRES_PASSWORD, SERVICE_ROLE_KEY, SESSION_SECRET in config.env."
for name in POSTGRES_PASSWORD JWT_SECRET SESSION_SECRET INVITE_TOKEN_SECRET FINGERPRINT; do
    check "$name is 64 lowercase hex" grep -qxE "$name=[0-9a-f]{64}" "$stack/config.env"
done
check "no CR byte" [ "$(tr -cd '\r' <"$stack/config.env" | wc -c)" -eq 0 ]
check "the example's comments stay" grep -qF "# How many hourly database dumps data/backups keeps." "$stack/config.env"
check "ANON_KEY verifies against JWT_SECRET" jwt_is_valid "$(config_value_of ANON_KEY)" anon "$(config_value_of JWT_SECRET)"
check "SERVICE_ROLE_KEY verifies against JWT_SECRET" jwt_is_valid "$(config_value_of SERVICE_ROLE_KEY)" service_role "$(config_value_of JWT_SECRET)"
finish

begin "config.env holds secrets, so it is created 0600 and stays 0600 when rewritten"
if [ -n "${MSYSTEM:-}" ]; then
    echo "skip $case_name: Git Bash on NTFS has no file modes"
else
    rm "$stack/config.env"
    chmod 0644 "$stack/config.env.example"
    run_cli init-config
    check "created 0600" [ "$(stat -c %a "$stack/config.env")" = 600 ]
    sed -i 's/^TS_AUTHKEY=.*/TS_AUTHKEY=tskey-test/' "$stack/config.env"
    run_cli up
    check "the tailnet rewrite happened" config_has SHELF_HOST=shelf.tail-test.ts.net
    check "still 0600 after the rewrite" [ "$(stat -c %a "$stack/config.env")" = 600 ]
    finish
fi

begin "init-config keeps existing values and fills only the empty ones"
printf '%s\r\n' "# kept comment" TS_AUTHKEY=tskey-mine POSTGRES_PASSWORD=mine JWT_SECRET=myjwt ANON_KEY=myanon \
    SERVICE_ROLE_KEY= SESSION_SECRET=session INVITE_TOKEN_SECRET=invite FINGERPRINT= 'SMTP_FROM="shelf <shelf@localhost>"' >"$stack/config.env"
run_cli init-config
check "names only the generated ones" said "Generated FINGERPRINT, SERVICE_ROLE_KEY in config.env."
check "POSTGRES_PASSWORD kept" config_has POSTGRES_PASSWORD=mine
check "JWT_SECRET kept" config_has JWT_SECRET=myjwt
check "ANON_KEY kept" config_has ANON_KEY=myanon
check "TS_AUTHKEY kept" config_has TS_AUTHKEY=tskey-mine
check "a quoted value kept" config_has 'SMTP_FROM="shelf <shelf@localhost>"'
check "the comment kept" config_has "# kept comment"
check "SERVICE_ROLE_KEY signed with the kept JWT_SECRET" jwt_is_valid "$(config_value_of SERVICE_ROLE_KEY)" service_role myjwt
check "CRLF became LF" [ "$(tr -cd '\r' <"$stack/config.env" | wc -c)" -eq 0 ]
finish

begin "init-config with every secret changes nothing"
cp "$stack/config.env" "$scratch/before.env"
run_cli init-config
check "says so" said "config.env already has every secret; nothing changed."
check "the file is unchanged" cmp -s "$scratch/before.env" "$stack/config.env"
finish

begin "a new JWT_SECRET re-signs both keys"
sed -i 's/^JWT_SECRET=.*/JWT_SECRET=/' "$stack/config.env"
run_cli init-config
check "names the three" said "Generated ANON_KEY, JWT_SECRET, SERVICE_ROLE_KEY in config.env."
check "ANON_KEY verifies against the new secret" jwt_is_valid "$(config_value_of ANON_KEY)" anon "$(config_value_of JWT_SECRET)"
finish

## The key check

begin "key check: a key file present passes"
run_cli up
check "exits 0" status_is 0
check "starts the stack" called "^compose up -d$"
finish

begin "key check: a folder in the key's place fails, before Assert-Config"
rm "$stack/data/secrets/pgsodium_root.key"
mkdir "$stack/data/secrets/pgsodium_root.key"
rm "$stack/config.env"
run_cli up
check "exits 1" status_is 1
check "explains the Docker folder" said "is a folder, not the encryption key file. Docker creates that folder"
check "the key check came first" not_said "No config.env"
check "starts nothing" not_called "^compose up"
finish

begin "key check: a missing key with a cluster in the volume fails"
rm "$stack/data/secrets/pgsodium_root.key"
set_state volume cluster
run_cli up
check "exits 1" status_is 1
check "says the volume holds a database" said "is missing but volume shelf-compose_shelf-db holds a database"
check "writes no key" [ ! -e "$stack/data/secrets/pgsodium_root.key" ]
check "starts nothing" not_called "^compose up"
finish

begin "key check: a missing key with complete dumps fails, --fresh included"
rm "$stack/data/secrets/pgsodium_root.key"
add_dump shelf-20261001-000000.dump
run_cli up
check "exits 1" status_is 1
check "says the dumps need the original key" said "holds database dumps. They can only be restored with the original pgsodium_root.key"
run_cli up --fresh
check "exits 1 with --fresh" status_is 1
check "names up --fresh" said "that includes 'up --fresh'"
check "writes no key" [ ! -e "$stack/data/secrets/pgsodium_root.key" ]
check "starts nothing" not_called "^compose up"
finish

begin "key check: no key, an empty volume and no dumps write a new key"
rm "$stack/data/secrets/pgsodium_root.key"
run_cli up
check "exits 0" status_is 0
check "the key is 64 lowercase hex with no newline" grep -qxE '[0-9a-f]{64}' "$stack/data/secrets/pgsodium_root.key"
check "the key is 64 bytes" [ "$(wc -c <"$stack/data/secrets/pgsodium_root.key" | tr -d ' ')" -eq 64 ]
if [ -z "${MSYSTEM:-}" ]; then
    check "the key is mode 0600" [ "$(stat -c %a "$stack/data/secrets/pgsodium_root.key")" = 600 ]
fi
finish

begin "key check: a failed key write leaves no key, and the next run writes a whole one"
rm "$stack/data/secrets/pgsodium_root.key"
mkdir -p "$scratch/failing-bin"
printf '%s\n' '#!/bin/bash' 'printf " 01 23"' 'exit 1' >"$scratch/failing-bin/od"
chmod +x "$scratch/failing-bin/od"
extra_path="$scratch/failing-bin"
run_cli up
check "exits 1" status_is 1
check "says the key could not be written" said "data/secrets/pgsodium_root.key could not be written"
check "no key file left" [ ! -e "$stack/data/secrets/pgsodium_root.key" ]
check "no temporary file left" [ ! -e "$stack/data/secrets/pgsodium_root.key.tmp" ]
check "starts nothing" not_called "^compose up"
extra_path=""
run_cli up
check "the next run exits 0" status_is 0
check "and writes a whole key" grep -qxE '[0-9a-f]{64}' "$stack/data/secrets/pgsodium_root.key"
finish

begin "key check: a key file of the wrong length is refused, not used"
printf '%s' 0123456789abcdef >"$stack/data/secrets/pgsodium_root.key"
run_cli up
check "exits 1" status_is 1
check "says it is not a whole key" said "is not a 64-character hex key (it holds 16 bytes)"
check "the file is left as it was" grep -qx 0123456789abcdef "$stack/data/secrets/pgsodium_root.key"
check "starts nothing" not_called "^compose up"
finish

begin "key check: a key with a trailing newline is refused"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef >"$stack/data/secrets/pgsodium_root.key"
run_cli up
check "exits 1" status_is 1
check "says it holds 65 bytes" said "(it holds 65 bytes)"
finish

## The restore decision in up, restart, rebuild

begin "a dump docker cannot probe stops up before anything starts, instead of restoring an older one"
add_dump shelf-20261001-000000.dump 7200
add_dump shelf-20261002-000000.dump 600
set_state probe-fails shelf-20261002-000000.dump
run_cli up
check "exits 1" status_is 1
check "names the dump and the docker exit" said "docker could not run pg_restore --list on shelf-20261002-000000.dump (exit 125)"
check "says nothing was started" said "Nothing was started, because a dump in data/backups could not be checked"
check "no compose up at all" not_called "^compose up"
check "never restores the older dump" not_called "pg_restore -h db"
finish

begin "exit 126 and 127 of the probe stop up too, exit 1 is a bad dump"
add_dump shelf-20261001-000000.dump 7200
add_dump shelf-20261002-000000.dump 600
set_state probe-fails shelf-20261002-000000.dump
set_state probe-exit 127
run_cli up
check "127 stops" status_is 1
set_state probe-exit 126
run_cli up
check "126 stops" status_is 1
check "no compose up after either" not_called "^compose up"
set_state probe-exit 1
run_cli up
check "1 skips that dump and restores the older" called "pg_restore -h db .*/backups/shelf-20261001-000000.dump$"
check "and says why it skipped" said "skipping shelf-20261002-000000.dump: pg_restore cannot list it (exit 1)"
finish

begin "Refuse: every dump rejected prints each with its reason and starts nothing"
add_dump shelf-20261001-000000.dump 7200
add_dump shelf-20261002-000000.dump 3600
set_state unlistable shelf-20261002-000000.dump
set_state no-table-data shelf-20261001-000000.dump
run_cli up
check "exits 1" status_is 1
check "names the empty volume" said "The database volume shelf-compose_shelf-db is empty, but no dump in data/backups can be restored:"
check "the unlistable dump with its reason" said "  shelf-20261002-000000.dump: pg_restore cannot list it (exit 1)"
check "the dump without table data with its reason" said "  shelf-20261001-000000.dump: it holds no table data"
check "the way on is --fresh" said "or start with an empty database on purpose: ./docker-compose.sh up --fresh"
check "no compose up at all" not_called "^compose up"
finish

begin "Refuse names the verb it refused"
add_dump shelf-20261001-000000.dump
set_state unlistable shelf-20261001-000000.dump
run_cli restart
check "exits 1" status_is 1
check "the way on is restart --fresh" said "./docker-compose.sh restart --fresh"
check "no compose up at all" not_called "^compose up"
finish

begin "--fresh on an empty volume restores nothing and warns about BACKUP_KEEP"
add_dump shelf-20261001-000000.dump
run_cli up --fresh
check "exits 0" status_is 0
check "says it starts empty" said "Starting with an empty database (--fresh)."
check "warns about BACKUP_KEEP" said "rotate the old dumps out after BACKUP_KEEP hours unless './docker-compose.sh restore <file>' runs first."
check "no pg_restore" not_called "pg_restore -h"
check "starts the stack" called "^compose up -d$"
finish

begin "--fresh with no dumps says so without the warning"
run_cli up --fresh
check "exits 0" status_is 0
check "says it starts empty" said "Starting with an empty database (--fresh)."
check "no BACKUP_KEEP warning" not_said "BACKUP_KEEP"
finish

begin "a volume holding a cluster is kept, --fresh or not"
set_state volume cluster
add_dump shelf-20261001-000000.dump
run_cli up --fresh
check "exits 0" status_is 0
check "no pg_restore" not_called "pg_restore -h"
check "no separate database start" not_called "^compose up -d db db-backup$"
check "no fresh message" not_said "Starting with an empty database"
finish

begin "Docker not answering keeps the volume"
set_state volume unreachable
add_dump shelf-20261001-000000.dump
run_cli up
check "exits 0" status_is 0
check "no pg_restore" not_called "pg_restore -h"
finish

begin "Restore: skips the rejected dump, restores the next with only db and db-backup up first"
add_dump shelf-20261001-000000.dump 7200
add_dump shelf-20261002-000000.dump 600
set_state unlistable shelf-20261002-000000.dump
run_cli up
check "exits 0" status_is 0
check "prints the skipped dump with its reason" said "  skipping shelf-20261002-000000.dump: pg_restore cannot list it (exit 1)"
check "names the dump and its age" said "Restoring shelf-20261001-000000.dump (2 h 0 min old) into the empty database..."
check "the tailnet first" called_before "^compose up -d tailscale$" "^compose up -d db db-backup$"
check "db and db-backup before the restore" called_before "^compose up -d db db-backup$" "pg_restore -h db"
check "restores the older dump" called "^compose exec -T db-backup pg_restore -h db -U supabase_admin -d postgres --clean --if-exists /backups/shelf-20261001-000000.dump$"
check "the full up after the restore" called_before "pg_restore -h db" "^compose up -d$"
check "says it restored" said "Restored shelf-20261001-000000.dump."
finish

begin "a failed pg_restore stops the stack and removes the volume it created"
add_dump shelf-20261001-000000.dump
set_state pg-restore-exit 1
run_cli up
check "exits 1" status_is 1
check "names the failure" said "pg_restore reported errors (exit 1); check the output above."
check "down before volume rm" called_before "^compose down$" "^volume rm shelf-compose_shelf-db$"
check "never the full up" not_called "^compose up -d$"
check "names the retry" said "Restoring shelf-20261001-000000.dump failed. Run ./docker-compose.sh up to try again, or start empty and restore by hand:"
check "names the manual way" said "  ./docker-compose.sh up --fresh   then   ./docker-compose.sh restore shelf-20261001-000000.dump"
check "no removal failure claimed" not_said "Could not remove"
finish

begin "a failed volume removal after a failed restore is said"
add_dump shelf-20261001-000000.dump
set_state pg-restore-exit 1
set_state volume-rm-exit 1
run_cli up
check "exits 1" status_is 1
check "says the volume could not be removed" said "Could not remove shelf-compose_shelf-db; remove it (docker volume rm shelf-compose_shelf-db) before the next up."
finish

begin "a database that does not start rolls back too"
add_dump shelf-20261001-000000.dump
set_state up-db-exit 1
run_cli up
check "exits 1" status_is 1
check "names the failure" said "The database did not start."
check "removes the volume" called "^volume rm shelf-compose_shelf-db$"
finish

begin "restart restores like up, then recreates"
add_dump shelf-20261001-000000.dump
run_cli restart
check "exits 0" status_is 0
check "restores first" called_before "pg_restore -h db" "^compose up -d --force-recreate$"
check "never builds" not_called "^compose build"
finish

begin "rebuild builds after the restore, then recreates"
add_dump shelf-20261001-000000.dump
run_cli rebuild
check "exits 0" status_is 0
check "restore before build" called_before "pg_restore -h db" "^compose build$"
check "build before recreate" called_before "^compose build$" "^compose up -d --force-recreate$"
finish

begin "a failed build stops rebuild"
set_state build-exit 1
run_cli rebuild
check "exits 1" status_is 1
check "no recreate" not_called "^compose up -d --force-recreate$"
finish

## Tailnet

begin "up writes SHELF_HOST, SERVER_URL and SUPABASE_URL once joined"
run_cli up
check "says it joined" said "Joined as shelf.tail-test.ts.net"
check "SHELF_HOST" config_has SHELF_HOST=shelf.tail-test.ts.net
check "SERVER_URL" config_has SERVER_URL=https://shelf.tail-test.ts.net
check "SUPABASE_URL" config_has SUPABASE_URL=https://shelf.tail-test.ts.net:8443
check "says it wrote them" said "Wrote SHELF_HOST, SERVER_URL and SUPABASE_URL to config.env."
check "prints the URLs" said "shelf          : https://shelf.tail-test.ts.net"
run_cli up
check "the second up writes nothing" call_count_is "^compose up -d tailscale$" 2
check "and says nothing about writing" not_said "Wrote SHELF_HOST"
finish

begin "up without TS_AUTHKEY and without a node identity stops"
sed -i 's/^TS_AUTHKEY=.*/TS_AUTHKEY=/' "$stack/config.env"
run_cli up
check "exits 1" status_is 1
check "says so" said "TS_AUTHKEY is empty in config.env and this node has not joined the tailnet yet."
check "starts nothing" not_called "^compose up"
finish

begin "a node identity on disk needs no TS_AUTHKEY"
sed -i 's/^TS_AUTHKEY=.*/TS_AUTHKEY=/' "$stack/config.env"
mkdir -p "$stack/data/tailscale"
: >"$stack/data/tailscale/tailscaled.state"
run_cli up
check "exits 0" status_is 0
finish

## Manual restore, backup, data, catalog

begin "restore refuses without db and db-backup running"
add_dump shelf-20261001-000000.dump
set_state running gateway
run_cli restore
check "exits 1" status_is 1
check "names both" said "Cannot restore: db, db-backup not running. Run ./docker-compose.sh up first, or ./docker-compose.sh up --fresh and then restore."
check "stops nothing" not_called "^compose stop"
finish

begin "restore names only the service that is not running"
add_dump shelf-20261001-000000.dump
set_state running db gateway
run_cli restore
check "names db-backup" said "Cannot restore: db-backup not running."
finish

begin "restore takes the newest restorable dump and restarts only after pg_restore"
add_dump shelf-20261001-000000.dump 7200
add_dump shelf-20261002-000000.dump 600
set_state no-table-data shelf-20261002-000000.dump
set_state running db db-backup shelf
run_cli restore
check "exits 0" status_is 0
check "says what it restores" said "Restoring shelf-20261001-000000.dump (shelf, auth and storage are stopped meanwhile)..."
check "stops the app services first" called_before "^compose stop shelf gateway auth storage$" "pg_restore -h db"
check "restores the older dump" called "pg_restore -h db -U supabase_admin -d postgres --clean --if-exists /backups/shelf-20261001-000000.dump$"
check "starts the stack after" called_before "pg_restore -h db" "^compose up -d$"
check "says it restored" said "Restored shelf-20261001-000000.dump."
finish

begin "a failed manual restore leaves the app stopped"
add_dump shelf-20261001-000000.dump
set_state running db db-backup
set_state pg-restore-exit 3
run_cli restore
check "exits 1" status_is 1
check "says so" said "pg_restore reported errors (exit 3); check the output above. shelf, gateway, auth and storage stay stopped."
check "no up after" not_called "^compose up -d$"
finish

begin "restore of a named file probes it, then restores it by its name only"
add_dump shelf-20261003-000000.dump
set_state running db db-backup
run_cli restore data/backups/shelf-20261003-000000.dump
check "exits 0" status_is 0
check "probes it first" called_before "pg_restore --list /backups/shelf-20261003-000000.dump$" "^compose stop shelf gateway auth storage$"
check "restores that file" called "--clean --if-exists /backups/shelf-20261003-000000.dump$"
check "says it restored" said "Restored shelf-20261003-000000.dump."
finish

begin "restore of a named file that is not in data/backups stops nothing"
add_dump shelf-20261001-000000.dump
set_state running db db-backup
run_cli restore shelf-2026100-000000.dump
check "exits 1" status_is 1
check "says so" said "No dump named shelf-2026100-000000.dump in data/backups; nothing was stopped."
check "stops nothing" not_called "^compose stop"
check "restores nothing" not_called "pg_restore -h db"
finish

begin "restore of a named dump without table data stops nothing"
add_dump shelf-20261001-000000.dump
set_state no-table-data shelf-20261001-000000.dump
set_state running db db-backup
run_cli restore shelf-20261001-000000.dump
check "exits 1" status_is 1
check "names the reason" said "shelf-20261001-000000.dump cannot be restored: it holds no table data; nothing was stopped."
check "stops nothing" not_called "^compose stop"
check "restores nothing" not_called "pg_restore -h db"
finish

begin "restore of a named dump docker cannot probe stops nothing"
add_dump shelf-20261001-000000.dump
set_state probe-fails shelf-20261001-000000.dump
set_state running db db-backup
run_cli restore shelf-20261001-000000.dump
check "exits 1" status_is 1
check "names the docker exit" said "docker could not run pg_restore --list on shelf-20261001-000000.dump (exit 125)"
check "stops nothing" not_called "^compose stop"
finish

begin "restore without any dump says so"
set_state running db db-backup
run_cli restore
check "exits 1" status_is 1
check "says so" said "No backups in data/backups."
finish

begin "restore with every dump rejected names the last reason"
add_dump shelf-20261001-000000.dump 7200
add_dump shelf-20261002-000000.dump 600
set_state no-table-data 'shelf-*.dump'
set_state running db db-backup
run_cli restore
check "exits 1" status_is 1
check "names the last dump checked and why" said "No dump in data/backups can be restored; the last one checked, shelf-20261001-000000.dump: it holds no table data."
check "does not claim there are none" not_said "No backups in data/backups."
check "stops nothing" not_called "^compose stop"
finish

begin "restore stops when docker cannot probe a dump"
add_dump shelf-20261001-000000.dump 7200
add_dump shelf-20261002-000000.dump 600
set_state probe-fails shelf-20261002-000000.dump
set_state running db db-backup
run_cli restore
check "exits 1" status_is 1
check "names the docker exit" said "docker could not run pg_restore --list on shelf-20261002-000000.dump (exit 125)"
check "stops nothing" not_called "^compose stop"
check "restores nothing" not_called "pg_restore -h db"
finish

begin "backup writes a .tmp, then renames it"
run_cli backup
check "exits 0" status_is 0
check "pg_dump to .tmp, then mv" called '^compose exec -T db-backup sh -c pg_dump -h db -U supabase_admin -d postgres -Fc -f /backups/shelf-[0-9]{8}-[0-9]{6}\.dump\.tmp && mv /backups/shelf-[0-9]{8}-[0-9]{6}\.dump\.tmp /backups/shelf-[0-9]{8}-[0-9]{6}\.dump$'
check "says where" said "Backed up to data/backups/shelf-"
finish

begin "a failed backup says so"
set_state backup-exit 1
run_cli backup
check "exits 1" status_is 1
check "says so" said "Backup failed."
finish

begin "data status and use point the submodule"
run_cli data
check "status by default" called "^git -C .* submodule status -- data$"
run_cli data use someone/shelf-data@v2
check "the GitHub URL" called "^git -C .* config submodule.data.url https://github.com/someone/shelf-data.git$"
check "fetches the ref" called "^git -C .*/data fetch -q origin v2$"
check "says where data is" said "data now at 0abc123"
run_cli data bogus
check "an unknown subcommand shows the usage" status_is 1
finish

begin "catalog runs python3 scripts/catalog.py with its arguments"
run_cli catalog sync --prune
check "exits 0" status_is 0
check "python3 with the arguments" called "^python3 catalog.py sync --prune$"
finish

## prove-data

prove_ready() {
    set_state containers shelf-db shelf-db-backup
    set_state volume cluster
    set_state volumes shelf-compose_shelf-db shelf-compose_shelf-db-config other-compose_db
    set_state counts-1 'public.Asset|12' 'auth.users|2' 'pgboss.job|3'
    set_state counts-2 'public.Asset|12' 'auth.users|2' 'pgboss.job|1'
}

begin "prove-data refuses when a container is not running"
set_state containers shelf-db
run_cli prove-data
check "exits 1" status_is 1
check "names it" said "shelf-db-backup is not running; start the stack first"
check "no backup" not_called "pg_dump"
check "nothing removed" not_called "^volume rm"
finish

begin "prove-data refuses without the key"
prove_ready
rm "$stack/data/secrets/pgsodium_root.key"
run_cli prove-data
check "exits 1" status_is 1
check "names the key" said "data/secrets/pgsodium_root.key is missing; the restored database could not be decrypted"
finish

begin "prove-data deletes nothing when the newest dump is not restorable"
prove_ready
set_state no-table-data 'shelf-*.dump'
run_cli prove-data
check "exits 1" status_is 1
check "says nothing was deleted" said "cannot be listed by pg_restore or holds no table data; nothing was deleted"
check "no down" not_called "^compose down"
check "nothing removed" not_called "^volume rm"
finish

begin "prove-data deletes nothing when docker cannot probe the newest dump"
prove_ready
set_state probe-fails 'shelf-*.dump'
run_cli prove-data
check "exits 1" status_is 1
check "names the docker exit" said "(exit 125)"
check "no down" not_called "^compose down"
check "nothing removed" not_called "^volume rm"
finish

begin "prove-data deletes nothing when no table was counted"
prove_ready
set_state counts-1 ''
run_cli prove-data
check "exits 1" status_is 1
check "says so" said "no table was counted; nothing was deleted"
check "no down" not_called "^compose down"
check "nothing removed" not_called "^volume rm"
finish

begin "prove-data passes, leaving pgboss.job uncompared and other projects' volumes alone"
prove_ready
run_cli prove-data
check "exits 0" status_is 0
check "takes a fresh dump first" called_before "pg_dump" "^compose down$"
check "counts 3 tables before" said "3 tables, dump shelf-"
check "removes only this stack's volumes" called "^volume rm shelf-compose_shelf-db shelf-compose_shelf-db-config$"
check "never another project's" not_called "other-compose_db"
check "restores the fresh dump into the emptied volume" called "pg_restore -h db .*/backups/shelf-[0-9]{8}-[0-9]{6}\.dump$"
check "prints pgboss.job uncompared" said "pgboss.job (not compared) before=3 after=1"
check "all tables match" said "all 3 tables match"
check "says every table came back" said "every table came back"
finish

begin "prove-data names each differing table and the way back"
prove_ready
set_state counts-2 'public.Asset|11' 'pgboss.job|3'
run_cli prove-data
check "exits 1" status_is 1
check "the differing count" said "DIFFERS public.Asset before=12 after=11"
check "the missing table" said "DIFFERS auth.users before=2 after=missing"
check "the recovery hint" said "The volumes were deleted. Recover with: ./docker-compose.sh up"
check "the manual way" said "If that keeps failing: ./docker-compose.sh up --fresh   then   ./docker-compose.sh restore shelf-"
finish

begin "prove-data with no volume of its own deletes nothing and gives the hint"
prove_ready
set_state volumes other-compose_db
run_cli prove-data
check "exits 1" status_is 1
check "says none was found" said "no volume labelled com.docker.compose.project=shelf-compose was found"
check "nothing removed" not_called "^volume rm"
check "the recovery hint" said "Recover with: ./docker-compose.sh up"
finish

echo
if [ "$failures" -eq 0 ]; then echo "all cases pass"; else echo "$failures cases fail"; fi
[ "$failures" -eq 0 ]
