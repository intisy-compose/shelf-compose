#!/bin/bash
# shellcheck disable=SC2154 # state is set by the fake docker, which sources this
# The fake docker's answers, keyed on the command. Its state is a folder of small files, each written
# by the test that needs it and read here with a default:
#   volume           missing | empty | cluster | unreachable (default empty): shelf-compose_shelf-db
#   unlistable       dump names, or globs, pg_restore --list fails on (exit 1)
#   no-table-data    dump names whose listing holds no TABLE DATA line
#   running          services `compose ps --status running --services` names
#   containers       container names `docker ps -q --filter name=^NAME$` finds
#   volumes          names `docker volume ls -q` prints
#   counts-N         the Nth table count's psql output (counts when there is none)
#   pg-restore-exit, backup-exit, up-db-exit, volume-rm-exit, build-exit: exit codes (default 0)
# A `volume rm` of shelf-compose_shelf-db makes the volume missing, as a real removal would.

state_value() { cat "$state/$1" 2>/dev/null || echo "${2:-}"; }

# listed_in FILE NAME: a line of the state FILE is NAME, or a glob that matches it.
listed_in() {
    local pattern
    [ -f "$state/$1" ] || return 1
    while IFS= read -r pattern; do
        # shellcheck disable=SC2053 # a line may be a glob on purpose
        [[ -n $pattern && $2 == $pattern ]] && return 0
    done <"$state/$1"
    return 1
}

answer_volume_inspect() {
    case "$(state_value volume empty)" in
        missing) echo "Error response from daemon: get shelf-compose_shelf-db: no such volume" >&2; return 1 ;;
        unreachable) echo "Cannot connect to the Docker daemon" >&2; return 1 ;;
        *) echo "[]" ;;
    esac
}

answer_pg_restore_list() {
    local name=${!#}
    name=${name##*/}
    listed_in unlistable "$name" && return 1
    listed_in no-table-data "$name" && { echo ";     Archive created at 2026-10-01"; return 0; }
    echo "4242; 0 16384 TABLE DATA public Asset postgres"
}

# answer_backup COMMAND: writes the dump the sh -c pg_dump command names into $FAKE_BACKUPS.
answer_backup() {
    local name
    name=$(sed -n 's|.*mv /backups/[^ ]* /backups/\([^ ]*\)$|\1|p' <<<"$1")
    [ "$(state_value backup-exit 0)" -eq 0 ] || return "$(state_value backup-exit)"
    [ -n "$name" ] && printf 'PGDMP fake dump' >"${FAKE_BACKUPS:?}/$name"
}

answer_volume_rm() {
    local volume
    [ "$(state_value volume-rm-exit 0)" -eq 0 ] || return "$(state_value volume-rm-exit)"
    for volume in "$@"; do
        [ "$volume" != shelf-compose_shelf-db ] || echo missing >"$state/volume"
        echo "$volume"
    done
}

answer_table_counts() {
    local calls
    calls=$(grep -c ' psql ' "$state/calls")
    if [ -f "$state/counts-$calls" ]; then cat "$state/counts-$calls"; else state_value counts; fi
}

answer_container_id() {
    local name=${1#*name=^}
    listed_in containers "${name%\$}" && echo 0123456789ab
}

answer() {
    case "$*" in
        "volume inspect "*) answer_volume_inspect ;;
        "run --rm -v "*":/v:ro alpine:3.21 find "*) [ "$(state_value volume empty)" != cluster ] || echo /v/PG_VERSION ;;
        "run --rm -v "*":/backups:ro "*" pg_restore --list "*) answer_pg_restore_list "$@" ;;
        "compose exec -T tailscale "*) echo '{"BackendState": "Running", "Self": {"DNSName": "shelf.tail-test.ts.net."}}' ;;
        "compose exec -T db-backup pg_isready "*) return 0 ;;
        "compose exec -T db-backup pg_restore "*) return "$(state_value pg-restore-exit 0)" ;;
        "compose exec -T db-backup sh -c "*) answer_backup "${!#}" ;;
        "compose ps --status running --services") state_value running ;;
        "compose up -d db db-backup") return "$(state_value up-db-exit 0)" ;;
        "compose build"*) return "$(state_value build-exit 0)" ;;
        "volume rm "*) shift 2; answer_volume_rm "$@" ;;
        "volume ls "*) state_value volumes ;;
        "ps -q --filter name=^"*) answer_container_id "$*" ;;
        "exec shelf-db-backup psql "*) answer_table_counts ;;
        *) return 0 ;;
    esac
}
