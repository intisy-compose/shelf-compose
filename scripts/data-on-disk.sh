#!/bin/bash
# Shared helpers for keeping a stack's data under its data/ folder and restoring an emptied database
# volume: the bash twin of data-on-disk.ps1, one function per PowerShell function, with the same decisions.
# Source only: loading this file defines functions and does nothing else.
# Each stack vendors a byte copy as scripts/data-on-disk.sh.

# is_missing_volume_answer EXIT_CODE OUTPUT: true only when `docker volume inspect` failed because the
# volume does not exist. A daemon outage, a permission error, a timeout or a missing docker binary
# (127, or no exit code at all) are not "missing", so they never lead to a restore over data.
is_missing_volume_answer() {
    local exit_code=$1 output=$2
    [[ $exit_code =~ ^[0-9]+$ ]] && [ "$exit_code" -ne 0 ] && grep -qi "no such volume" <<<"$output"
}

# database_volume_is_empty VOLUME: true when the named Docker volume does not exist or holds no
# Postgres cluster. PG_VERSION marks a cluster; it is searched to depth 4 because pg0 keeps its cluster
# at instances/<name>/data/. When Docker cannot answer, the result is false, so an unreadable volume
# is never mistaken for an empty one and restored over.
database_volume_is_empty() {
    local volume=$1 output exit_code=0 found
    output=$(docker volume inspect "$volume" 2>&1) || exit_code=$?
    if is_missing_volume_answer "$exit_code" "$output"; then return 0; fi
    [ "$exit_code" -eq 0 ] || return 1
    found=$(docker run --rm -v "$volume:/v:ro" alpine:3.21 find /v -maxdepth 4 -name PG_VERSION 2>/dev/null) || return 1
    [ -z "$found" ]
}

# complete_dumps FOLDER PATTERN: the name of every complete dump in a folder, newest first, one per
# line. Only names of the form <app>-YYYYMMDD-HHMMSS.dump are supported: their name order, ignoring
# case, is their age order, and PATTERN matches ignoring case, as on Windows. A zero-byte file or a
# .tmp is an interrupted dump and is never listed; a symlink counts with the size of its target.
# A folder that exists but cannot be listed fails with a message naming it, so no caller takes it
# for an empty one.
complete_dumps() (
    folder=$1 pattern=$2
    [ -d "$folder" ] || exit 0
    if ! listing=$(find "$folder/." ! -name . -prune); then
        echo "Cannot list $folder" >&2
        exit 1
    fi
    shopt -s nocasematch
    while IFS= read -r path; do
        name=${path##*/}
        # shellcheck disable=SC2053 # PATTERN is a glob on purpose
        if [ -n "$path" ] && [[ $name == $pattern ]] && [[ $name != *.tmp ]] && dump_has_bytes "$path"; then
            printf '%s\n' "$name"
        fi
    done <<<"$listing" | LC_ALL=C sort -r -f
)

# dump_has_bytes PATH: true when a file, or the file a symlink points to, is not empty.
dump_has_bytes() { [ -f "$1" ] && [ -s "$1" ]; }

# newest_dump FOLDER PATTERN: the name of the newest complete dump in a folder, or nothing; fails as
# complete_dumps does on a folder that cannot be listed.
newest_dump() {
    local dumps
    dumps=$(complete_dumps "$1" "$2") || return 1
    if [ -n "$dumps" ]; then printf '%s\n' "${dumps%%$'\n'*}"; fi
}

# table_row_counts CONTAINER HOST USER DATABASE [PSQL] [PASSWORD]: the row count of every base table
# outside pg_catalog and information_schema, one "schema.table|count" line each. One query counts all
# tables through query_to_xml, so there is no round trip per table.
table_row_counts() {
    local container=$1 database_host=$2 user=$3 database=$4 psql=${5:-psql} password=${6:-} lines
    local query="select table_schema || '.' || table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema') order by 1"
    local environment=()
    if [ -n "$password" ]; then environment=(-e "PGPASSWORD=$password"); fi
    lines=$(docker exec ${environment[@]+"${environment[@]}"} "$container" "$psql" -h "$database_host" -U "$user" -d "$database" -At -F "|" -c "$query") || {
        echo "psql in $container failed with exit code $?" >&2
        return 1
    }
    grep -v '^$' <<<"$lines" || true
}

# restore_decision VOLUME FOLDER PATTERN [REJECT_FUNCTION] [ALLOW_FRESH]: what `up` does with the
# database volume, as lines: "action Keep|Restore|Fresh|Refuse", then "dump NAME" for Restore, then
# "rejected NAME<TAB>REASON" for each newer dump that was skipped.
# Refuse answers an empty volume next to complete dumps that REJECT_FUNCTION all rejects, or next to
# a folder that cannot be listed (rejected under the folder's own path): an empty database started
# there would be dumped hourly and rotate those dumps out within BACKUP_KEEP hours.
# REJECT_FUNCTION is called with a dump's path and prints why it cannot be restored, or nothing when
# it can; its lines join with spaces, as the ps1's "$(...)" does. A non-zero exit means it could not
# judge the dump (the ps1's callback throws): the decision stops there, prints the callback's output
# on stderr and fails, so a probe that never ran cannot pass an older dump for the newest.
# ALLOW_FRESH=true starts an empty database instead of restoring, but never touches a volume that holds one.
restore_decision() {
    local volume=$1 folder=$2 pattern=$3 reject_function=${4:-} allow_fresh=${5:-false}
    local name reason reason_exit listing rejected=()
    if ! database_volume_is_empty "$volume"; then new_restore_decision Keep ""; return 0; fi
    if [ "$allow_fresh" = true ]; then new_restore_decision Fresh ""; return 0; fi
    if ! listing=$(complete_dumps "$folder" "$pattern"); then
        new_restore_decision Refuse "" "$folder"$'\t'"it cannot be listed"
        return 0
    fi
    while IFS= read -r name <&3; do
        [ -n "$name" ] || continue
        reason=""
        reason_exit=0
        if [ -n "$reject_function" ]; then reason=$("$reject_function" "$folder/$name" </dev/null) || reason_exit=$?; fi
        reason=${reason//$'\n'/ }
        if [ "$reason_exit" -ne 0 ]; then
            echo "${reason:-$reject_function failed with exit code $reason_exit} ($name)" >&2
            return 1
        fi
        if [ -z "$reason" ]; then
            new_restore_decision Restore "$name" ${rejected[@]+"${rejected[@]}"}
            return 0
        fi
        rejected+=("$name"$'\t'"$reason")
    done 3<<<"$listing"
    if [ ${#rejected[@]} -gt 0 ]; then
        new_restore_decision Refuse "" "${rejected[@]}"
        return 0
    fi
    new_restore_decision Fresh ""
}

# new_restore_decision ACTION DUMP [NAME<TAB>REASON...]: prints a decision in restore_decision's
# format; an empty DUMP prints no dump line.
new_restore_decision() {
    local action=$1 dump=$2 rejection
    shift 2
    echo "action $action"
    if [ -n "$dump" ]; then echo "dump $dump"; fi
    for rejection in "$@"; do echo "rejected $rejection"; done
}

# format_restore_refusal DECISION VOLUME FOLDER_NAME VERB [CLI] [FRESH_FLAG]: the lines to print when
# a decision is Refuse, every rejected dump with its reason, and the way on. CLI and FRESH_FLAG
# default to ./docker-compose.sh and --fresh.
format_restore_refusal() {
    local decision=$1 volume=$2 folder_name=$3 verb=$4 cli=${5:-./docker-compose.sh} fresh_flag=${6:---fresh} line
    echo "The database volume $volume is empty, but no dump in $folder_name can be restored:"
    while IFS= read -r line; do
        [[ $line == "rejected "* ]] || continue
        line=${line#rejected }
        echo "  ${line%%$'\t'*}: ${line#*$'\t'}"
    done <<<"$decision"
    echo "Nothing was started. Put a good dump into $folder_name (from the array or Kopia) and run $verb again,"
    echo "or start with an empty database on purpose: $cli $verb $fresh_flag"
}
