#!/usr/bin/env bash
# The Linux CLI, with the same commands and messages as docker-compose.ps1.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    echo "docker-compose.sh needs bash 4.3 or newer; this is bash $BASH_VERSION" >&2
    exit 1
fi
set -euo pipefail
# shellcheck disable=SC2034 # read by the CLI parity check, not here
windows_only=()

# The pinned `name:` must win, because the restore guard checks the volume by that name.
unset COMPOSE_PROJECT_NAME

here=$(cd "$(dirname "$0")" && pwd)
# Git Bash on Windows: docker.exe needs a Windows path here, and must get container paths unrewritten.
if [ -n "${MSYSTEM:-}" ]; then here=$(cd "$here" && pwd -W); export MSYS_NO_PATHCONV=1; fi

# shellcheck source=scripts/data-on-disk.sh
. "$here/scripts/data-on-disk.sh"
# shellcheck source=scripts/prove-data.sh
. "$here/scripts/prove-data.sh"
# shellcheck source=scripts/database-key.sh
. "$here/scripts/database-key.sh"

config_file="$here/config.env"
example_file="$here/config.env.example"
backups_folder="$here/data/backups"
dump_pattern="shelf-*.dump"
compose=(docker compose --project-directory "$here" --env-file "$config_file")
database_volume="shelf-compose_shelf-db"
secret_names=(POSTGRES_PASSWORD JWT_SECRET SESSION_SECRET INVITE_TOKEN_SECRET FINGERPRINT)
fresh=false

step() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m%s\033[0m\n' "$*"; }
note() { printf '\033[90m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
fail() { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./docker-compose.sh [backup|catalog|data|down|init-config|logs|prove-data|rebuild|restart|restore|status|up|url]
  backup       Dump the database to data/backups now
  catalog      check | sync [--prune] | add <file> | update <file> | list | images | cutout <photo> <png>  (see CATALOG.md in data/)
  data         status | use [owner/repo[@ref]]  point data/ at a data repo (none = template)
  down         Stop and remove the containers (the database volume and data/ stay)
  init-config  Create config.env and generate every missing secret and key
  logs         [service]  follow logs, e.g. logs shelf
  prove-data   DESTRUCTIVE: dump, delete every volume, start, and compare every table (needs the stack up)
  rebuild      [--fresh]  rebuild the built images (shelf, migrate) and recreate the stack, restoring as up does
  restart      [--fresh]  recreate the stack, restoring an empty database as up does
  restore      [file]  restore the database from data/backups (newest by default)
  status       Show the containers and their health
  up           [--fresh]  join the tailnet, restore an empty database from data/backups, start the stack (default); --fresh starts it empty instead
  url          Print the tailnet URLs
EOF
    exit 1
}

# read_options [--fresh] ...: --fresh sets fresh=true; any other argument shows the usage.
read_options() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            --fresh) fresh=true ;;
            *) usage ;;
        esac
    done
}

no_options() { [ $# -eq 0 ] || usage; }

# config_value NAME: the last value config.env gives NAME, trimmed and without surrounding quotes.
config_value() {
    [ -f "$config_file" ] || return 0
    tr -d '\r' <"$config_file" | awk -v name="$1" '
        match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) {
            key = substr($0, 1, RLENGTH - 1); gsub(/[ \t]/, "", key)
            if (key != name) next
            value = substr($0, RLENGTH + 1); sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value)
            gsub(/^"+|"+$/, "", value); found = 1
        }
        END { if (found) print value }'
}

assert_config() {
    local name missing=()
    [ -f "$config_file" ] || fail "No config.env - run './docker-compose.sh init-config' first."
    for name in "${secret_names[@]}" ANON_KEY SERVICE_ROLE_KEY; do
        [ -n "$(config_value "$name")" ] || missing+=("$name")
    done
    [ ${#missing[@]} -eq 0 ] || fail "config.env is missing: $(join_by ', ' "${missing[@]}") - run init-config."
}

join_by() {
    local separator=$1 first=$2
    shift 2
    printf '%s' "$first" "${@/#/$separator}"
}

new_secret() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# new_supabase_key ROLE SECRET: a JWT for ROLE signed with SECRET (HS256), valid for ten years.
new_supabase_key() {
    python3 - "$1" "$2" <<'EOF'
import base64, hashlib, hmac, sys, time

def base64url(data):
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")

role, secret = sys.argv[1], sys.argv[2]
issued_at = int(time.time())
header = base64url(b'{"alg":"HS256","typ":"JWT"}')
claims = '{"role":"%s","iss":"supabase","iat":%d,"exp":%d}' % (role, issued_at, issued_at + 10 * 365 * 24 * 3600)
payload = base64url(claims.encode("utf-8"))
signature = base64url(hmac.new(secret.encode("utf-8"), (header + "." + payload).encode("utf-8"), hashlib.sha256).digest())
print(header + "." + payload + "." + signature)
EOF
}

init_config() {
    local name jwt_secret generated=() names=()
    [ -f "$config_file" ] || (umask 077 && cp "$example_file" "$config_file")
    for name in "${secret_names[@]}"; do
        [ -n "$(config_value "$name")" ] || generated+=("$name=$(new_secret)")
    done
    jwt_secret=$(generated_value JWT_SECRET "${generated[@]+"${generated[@]}"}") || jwt_secret=$(config_value JWT_SECRET)
    if generated_value JWT_SECRET "${generated[@]+"${generated[@]}"}" >/dev/null || [ -z "$(config_value ANON_KEY)" ]; then
        generated+=("ANON_KEY=$(new_supabase_key anon "$jwt_secret")")
    fi
    if generated_value JWT_SECRET "${generated[@]+"${generated[@]}"}" >/dev/null || [ -z "$(config_value SERVICE_ROLE_KEY)" ]; then
        generated+=("SERVICE_ROLE_KEY=$(new_supabase_key service_role "$jwt_secret")")
    fi
    if [ ${#generated[@]} -eq 0 ]; then ok "config.env already has every secret; nothing changed."; return; fi
    set_config_values "${generated[@]}"
    mapfile -t names < <(printf '%s\n' "${generated[@]%%=*}" | LC_ALL=C sort -f)
    ok "Generated $(join_by ', ' "${names[@]}") in config.env."
}

# generated_value NAME [NAME=VALUE...]: prints the value given to NAME, or fails when none is.
generated_value() {
    local name=$1 pair
    shift
    for pair in "$@"; do
        if [ "${pair%%=*}" = "$name" ]; then printf '%s' "${pair#*=}"; return 0; fi
    done
    return 1
}

# set_config_values NAME=VALUE...: rewrites each line that sets one of the names, keeping every other
# line, and writes the file back with LF endings, in place, so it keeps its mode.
set_config_values() {
    local pair line key output=""
    local -A values=()
    for pair in "$@"; do values[${pair%%=*}]=${pair#*=}; done
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        if [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] && [[ -v values[${BASH_REMATCH[1]}] ]]; then
            key=${BASH_REMATCH[1]}
            line="$key=${values[$key]}"
        fi
        output+="$line"$'\n'
    done <"$config_file"
    printf '%s' "$output" >"$config_file"
}

# get_tailnet_status: the node's ts.net name once it runs on the tailnet, or nothing.
get_tailnet_status() {
    "${compose[@]}" exec -T tailscale tailscale --socket=/var/run/tailscale/tailscaled.sock status --json 2>/dev/null |
        python3 -c 'import json,sys
try: s = json.load(sys.stdin)
except ValueError: sys.exit(0)
name = (s.get("Self") or {}).get("DNSName") or ""
print(name.rstrip(".") if s.get("BackendState") == "Running" else "")' 2>/dev/null || true
}

# The ts.net name is only known once the node has joined, and every other service is configured
# from it, so the tailscale container starts first and the URLs are written before the rest.
connect_tailnet() {
    local tailnet_host="" deadline
    if [ -z "$(config_value TS_AUTHKEY)" ] && [ ! -e "$here/data/tailscale/tailscaled.state" ]; then
        err "TS_AUTHKEY is empty in config.env and this node has not joined the tailnet yet."
        err "Create a key at https://login.tailscale.com/admin/settings/keys"
        exit 1
    fi
    step "Joining the tailnet..."
    "${compose[@]}" up -d tailscale
    deadline=$((SECONDS + 90))
    while [ "$SECONDS" -lt "$deadline" ]; do
        tailnet_host=$(get_tailnet_status)
        [ -z "$tailnet_host" ] || break
        sleep 2
    done
    if [ -z "$tailnet_host" ]; then
        err "The node did not join within 90s. An expired or used-up TS_AUTHKEY is the usual cause;"
        err "check './docker-compose.sh logs tailscale'."
        exit 1
    fi
    ok "Joined as $tailnet_host"
    if [ "$(config_value SHELF_HOST)" != "$tailnet_host" ]; then
        set_config_values "SHELF_HOST=$tailnet_host" "SERVER_URL=https://$tailnet_host" "SUPABASE_URL=https://$tailnet_host:8443"
        ok "Wrote SHELF_HOST, SERVER_URL and SUPABASE_URL to config.env."
    fi
}

confirm_database_key() {
    local message
    message=$(assert_database_key "$here/data/secrets/pgsodium_root.key" "$database_volume" "$backups_folder" "$dump_pattern") ||
        fail "$message"
}

show_urls() {
    echo
    echo "  shelf          : $(config_value SERVER_URL)   (from any device on your tailnet)"
    echo "                   http://localhost:8444   (on this PC)"
    echo "  Supabase       : $(config_value SUPABASE_URL)"
    echo "  Mail (Mailpit) : http://localhost:8025   (on this PC only)"
}

invoke_pg_restore() {
    "${compose[@]}" exec -T db-backup pg_restore -h db -U supabase_admin -d postgres --clean --if-exists "/backups/$1"
}

get_running_services() { "${compose[@]}" ps --status running --services 2>/dev/null || true; }

# With the stack down, the restore would fail at the exec and the trailing `up -d` would then start
# the whole stack on an empty database.
assert_restore_services_running() {
    local running service missing=()
    running=$(get_running_services)
    for service in db db-backup; do
        grep -qxF "$service" <<<"$running" || missing+=("$service")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    fail "Cannot restore: $(join_by ', ' "${missing[@]}") not running. Run ./docker-compose.sh up first, or ./docker-compose.sh up --fresh and then restore."
}

# assert_named_dump_restorable NAME: exits 1 before anything is stopped unless data/backups holds NAME
# and it passes the same probe as the newest dump does. `pg_restore --clean` drops every table first,
# so a dump with no table data would empty the live database.
assert_named_dump_restorable() {
    local name=$1 reason
    [ -f "$backups_folder/$name" ] || fail "No dump named $name in data/backups; nothing was stopped."
    reason=$(get_dump_rejection "$backups_folder/$name") || fail "$reason"
    [ -z "$reason" ] || fail "$name cannot be restored: $reason; nothing was stopped."
}

# invoke_restore [FILE]: restores FILE, or the newest restorable dump, into the running database.
invoke_restore() {
    local file=${1:-} name reason last_rejection="" restore_exit=0
    [[ $file != -* ]] || usage
    assert_restore_services_running
    if [ -z "$file" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            reason=$(get_dump_rejection "$backups_folder/$name") || fail "$reason"
            if [ -z "$reason" ]; then file=$name; break; fi
            last_rejection="$name: $reason"
        done < <(complete_dumps "$backups_folder" "$dump_pattern" || true)
        [ -n "$file" ] || [ -z "$last_rejection" ] ||
            fail "No dump in data/backups can be restored; the last one checked, $last_rejection."
        [ -n "$file" ] || fail "No backups in data/backups."
    else
        assert_named_dump_restorable "${file##*/}"
    fi
    file=${file##*/}
    step "Restoring $file (shelf, auth and storage are stopped meanwhile)..."
    "${compose[@]}" stop shelf gateway auth storage
    invoke_pg_restore "$file" || restore_exit=$?
    if [ "$restore_exit" -ne 0 ]; then
        fail "pg_restore reported errors (exit $restore_exit); check the output above. shelf, gateway, auth and storage stay stopped."
    fi
    "${compose[@]}" up -d
    ok "Restored $file."
}

# get_backup_image: the image of the db-backup service, whose client tools read dumps.
get_backup_image() {
    tr -d '\r' <"$here/docker-compose.yml" | awk '
        /^  db-backup:/ { inside = 1; next }
        inside && match($0, /^    image:[ \t]*[^ \t]+/) { value = $0; sub(/^    image:[ \t]*/, "", value); sub(/[ \t].*/, "", value); print value; found = 1; exit }
        END { exit !found }'
}

# get_dump_rejection PATH: why the dump cannot be restored, or nothing when pg_restore can list it and
# it holds table data. It runs in a throwaway container of the stack's own postgres client image with
# the dump's folder mounted read-only, so it works while the stack is down. An empty database dumps
# to a valid file with no table data. When docker itself could not run the probe (125, 126, 127: the
# image missing offline, the daemon failing), nothing is known about the dump, so it prints why and
# fails instead of rejecting it, which would let an older dump be restored in its place.
get_dump_rejection() {
    local path=$1 image listing list_exit=0
    image=$(get_backup_image) || { echo "no image found for the db-backup service"; return 1; }
    listing=$(docker run --rm -v "${path%/*}:/backups:ro" "$image" pg_restore --list "/backups/${path##*/}" 2>/dev/null) || list_exit=$?
    if is_docker_run_failure "$list_exit"; then
        echo "docker could not run pg_restore --list on ${path##*/} (exit $list_exit): check that Docker runs and has or can pull $image"
        return 1
    fi
    if [ "$list_exit" -ne 0 ]; then echo "pg_restore cannot list it (exit $list_exit)"; return 0; fi
    grep -q "TABLE DATA" <<<"$listing" || echo "it holds no table data"
}

is_docker_run_failure() { [ "$1" -eq 125 ] || [ "$1" -eq 126 ] || [ "$1" -eq 127 ]; }

# test_dump_is_restorable PATH: true when the dump can be restored; exits 1 when docker cannot tell.
test_dump_is_restorable() {
    local reason
    reason=$(get_dump_rejection "$1") || fail "$reason"
    [ -z "$reason" ]
}

format_dump_age() {
    local age=$(($(date +%s) - $1))
    if [ "$age" -ge 86400 ]; then echo "$((age / 86400)) d $((age % 86400 / 3600)) h old"; return; fi
    if [ "$age" -ge 3600 ]; then echo "$((age / 3600)) h $((age % 3600 / 60)) min old"; return; fi
    echo "$((age / 60)) min old"
}

# confirm_restore_decision VERB: sets restore_decision_lines to what to do with the database volume;
# exits 1 before anything starts when the answer is Refuse.
confirm_restore_decision() {
    local verb=$1 line
    restore_decision_lines=$(restore_decision "$database_volume" "$backups_folder" "$dump_pattern" get_dump_rejection "$fresh") ||
        fail "Nothing was started, because a dump in data/backups could not be checked; run ./docker-compose.sh $verb again once Docker can run the check."
    case "$(decision_value action)" in
        Refuse)
            while IFS= read -r line; do err "$line"; done < <(format_restore_refusal "$restore_decision_lines" "$database_volume" "data/backups" "$verb")
            exit 1 ;;
        Fresh)
            if [ "$fresh" = true ]; then
                step "Starting with an empty database (--fresh)."
                write_fresh_dump_warning
            fi ;;
    esac
}

# decision_value KEY: the value of the decision's first KEY line.
decision_value() { sed -n "s/^$1 //p" <<<"$restore_decision_lines" | head -n 1; }

write_fresh_dump_warning() {
    [ -n "$(complete_dumps "$backups_folder" "$dump_pattern" 2>/dev/null || true)" ] || return 0
    err "Warning: the hourly dumps of the empty database rotate the old dumps out after BACKUP_KEEP hours unless './docker-compose.sh restore <file>' runs first."
}

wait_database_reachable() {
    local deadline=$((SECONDS + 120))
    while [ "$SECONDS" -lt "$deadline" ]; do
        "${compose[@]}" exec -T db-backup pg_isready -h db -U supabase_admin -d postgres >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# invoke_empty_database_restore DUMP: sets restore_failure to why restoring DUMP into the empty
# database failed, or to nothing when it worked.
invoke_empty_database_restore() {
    local restore_exit=0
    restore_failure=""
    if ! "${compose[@]}" up -d db db-backup; then restore_failure="The database did not start."; return; fi
    if ! wait_database_reachable; then restore_failure="The database did not become reachable within 120 s."; return; fi
    invoke_pg_restore "$1" || restore_exit=$?
    [ "$restore_exit" -eq 0 ] || restore_failure="pg_restore reported errors (exit $restore_exit); check the output above."
}

# undo_failed_restore FAILURE DUMP: stops the stack and removes the database volume after a failed
# restore into it, then exits 1. The volume was empty before this run, so removing it loses nothing,
# and the next `up` finds it empty again and retries instead of keeping a half-restored database.
undo_failed_restore() {
    local failure=$1 dump_name=$2
    err "$failure"
    step "Stopping the stack and removing $database_volume, which was empty before this run..."
    "${compose[@]}" down || true
    if ! docker volume rm "$database_volume" >/dev/null; then
        err "Could not remove $database_volume; remove it (docker volume rm $database_volume) before the next up."
    fi
    err "Restoring $dump_name failed. Run ./docker-compose.sh up to try again, or start empty and restore by hand:"
    err "  ./docker-compose.sh up --fresh   then   ./docker-compose.sh restore $dump_name"
    exit 1
}

# restore_empty_database: restores the decision's dump into the empty database before anything else
# starts. Only db and db-backup run meanwhile, so migrate, auth and storage first meet the restored
# schema instead of initialising one the restore then drops.
restore_empty_database() {
    local dump line
    [ "$(decision_value action)" = Restore ] || return 0
    dump=$(decision_value dump)
    while IFS= read -r line; do
        line=${line#rejected }
        note "  skipping ${line%%$'\t'*}: ${line#*$'\t'}"
    done < <(grep '^rejected ' <<<"$restore_decision_lines" || true)
    step "Restoring $dump ($(format_dump_age "$(stat -c %Y "$backups_folder/$dump")")) into the empty database..."
    invoke_empty_database_restore "$dump"
    [ -z "$restore_failure" ] || undo_failed_restore "$restore_failure" "$dump"
    ok "Restored $dump."
}

invoke_up() {
    confirm_database_key
    assert_config
    confirm_restore_decision up
    connect_tailnet
    restore_empty_database
    step "Starting shelf..."
    "${compose[@]}" up -d && show_urls
}

invoke_recreate() {
    local verb=$1
    confirm_database_key
    assert_config
    confirm_restore_decision "$verb"
    connect_tailnet
    restore_empty_database
    if [ "$verb" = rebuild ]; then
        step "Rebuilding..."
        "${compose[@]}" build || exit 1
    fi
    step "Recreating..."
    "${compose[@]}" up -d --force-recreate
    show_urls
}

invoke_backup() {
    local file
    file="shelf-$(date -u +%Y%m%d-%H%M%S).dump"
    step "Dumping the database to data/backups/$file..."
    "${compose[@]}" exec -T db-backup sh -c "pg_dump -h db -U supabase_admin -d postgres -Fc -f /backups/$file.tmp && mv /backups/$file.tmp /backups/$file" ||
        fail "Backup failed."
    ok "Backed up to data/backups/$file."
}

# split_data_source SOURCE: sets data_url and data_ref from owner/repo[@ref] or a git URL[@ref]. The
# ref follows the last @ after a URL's user@, so git@host:owner/repo@ref keeps its user.
split_data_source() {
    local rest=$1 user=""
    if [[ $rest =~ ^([A-Za-z][A-Za-z0-9+.-]*://[^/@]+@)(.*)$ || $rest =~ ^([^/@:]+@)([^/:]+:.*)$ ]]; then
        user=${BASH_REMATCH[1]}
        rest=${BASH_REMATCH[2]}
    fi
    data_ref=main
    if [[ $rest == *@* ]]; then
        data_ref=${rest##*@}
        rest=${rest%@*}
    fi
    if [[ -z $data_ref || $data_ref == -* ]]; then
        printf '\033[31m%s\033[0m\n' "A data ref must not be empty or start with '-': '$data_ref'" >&2
        exit 1
    fi
    data_url=$user$rest
    [[ $data_url == *://* || -n $user ]] || data_url="https://github.com/$data_url.git"
}

invoke_data() {
    local subcommand url ref
    subcommand=$(printf '%s' "${1:-status}" | tr '[:upper:]' '[:lower:]')
    case "$subcommand" in
        status) git -C "$here" submodule status -- data ;;
        use)
            if [ -n "${2:-}" ]; then
                split_data_source "$2"
                url=$data_url
                ref=$data_ref
            else
                url=$(git -C "$here" config -f .gitmodules submodule.data.url)
                ref=main
            fi
            step "Pointing data at $url @ $ref"
            [ -e "$here/data/.git" ] || git -C "$here" submodule update --init -- data >/dev/null 2>&1 || true
            git -C "$here" config submodule.data.url "$url"
            git -C "$here/data" remote set-url origin "$url"
            git -C "$here/data" fetch -q origin "$ref"
            git -C "$here/data" checkout -q FETCH_HEAD
            ok "data now at $(git -C "$here/data" rev-parse --short HEAD)" ;;
        *) usage ;;
    esac
}

cd "$here"
command=$(printf '%s' "${1-up}" | tr '[:upper:]' '[:lower:]')
[ $# -eq 0 ] || shift
case "$command" in
    init-config) no_options "$@"; init_config ;;
    up)          read_options "$@"; invoke_up ;;
    down)        no_options "$@"; step "Stopping everything..."; "${compose[@]}" down ;;
    restart)     read_options "$@"; invoke_recreate restart ;;
    rebuild)     read_options "$@"; invoke_recreate rebuild ;;
    url)         no_options "$@"; show_urls ;;
    status)      no_options "$@"; "${compose[@]}" ps -a ;;
    logs)        "${compose[@]}" logs -f "$@" ;;
    backup)      no_options "$@"; assert_config; invoke_backup ;;
    restore)     [ $# -le 1 ] || usage; assert_config; invoke_restore "$@" ;;
    prove-data)  no_options "$@"; assert_config; invoke_prove_data ;;
    data)        invoke_data "$@" ;;
    catalog)     assert_config; exec python3 "$here/scripts/catalog.py" "$@" ;;
    *)           usage ;;
esac
