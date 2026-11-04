#!/bin/bash
# shellcheck disable=SC2154 # here, backups_folder and dump_pattern are docker-compose.sh's, which sources this
# The bash twin of prove-data.ps1. Source only; needs docker-compose.sh's invoke_backup and
# test_dump_is_restorable, and data-on-disk.sh.

prove_project="shelf-compose"
prove_backup_container="shelf-db-backup"
prove_database_container="shelf-db"
prove_uncompared_tables=(pgboss.job)

# compare_table_counts BEFORE AFTER [UNCOMPARED...]: the table-by-table differences between two sets
# of "schema.table|count" lines, one printable line each; nothing when they match. Uncompared tables
# are skipped; write_uncompared_counts prints them instead.
compare_table_counts() {
    local before=$1 after=$2 name before_count after_count
    shift 2
    local -A before_counts=() after_counts=() skipped=()
    for name in "$@"; do skipped[$name]=1; done
    read_counts before_counts "$before"
    read_counts after_counts "$after"
    while IFS= read -r name; do
        if [ -z "$name" ] || [ -n "${skipped[$name]:-}" ]; then continue; fi
        before_count=${before_counts[$name]:-missing}
        after_count=${after_counts[$name]:-missing}
        [ "$before_count" = "$after_count" ] || echo "$name before=$before_count after=$after_count"
    done < <(printf '%s\n' "${!before_counts[@]}" "${!after_counts[@]}" | LC_ALL=C sort -u)
}

# read_counts ARRAY LINES: fills the associative ARRAY from "schema.table|count" lines.
# shellcheck disable=SC2034 # counts is a nameref: the caller's array is the one filled
read_counts() {
    local -n counts=$1
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        counts[${line%%|*}]=${line#*|}
    done <<<"$2"
}

# write_uncompared_counts BEFORE AFTER: prints the counts of the tables the comparison skips.
# pgboss.job is pg-boss's job queue, which its housekeeping prunes and refills on every start, so a
# restore legitimately ends with different rows than the dump held.
write_uncompared_counts() {
    local name
    local -A before_counts=() after_counts=()
    read_counts before_counts "$1"
    read_counts after_counts "$2"
    for name in "${prove_uncompared_tables[@]}"; do
        note "  $name (not compared) before=${before_counts[$name]:-missing} after=${after_counts[$name]:-missing}"
    done
}

get_shelf_table_counts() { table_row_counts "$prove_backup_container" db supabase_admin postgres; }

test_container_is_running() { [ -n "$(docker ps -q --filter "name=^$1$")" ]; }

# invoke_stack VERB: runs a docker-compose.sh verb; only "down" has its exit code trusted, because
# `up` is judged by the table counts that follow it.
invoke_stack() {
    local verb=$1 stack_exit=0
    "$here/docker-compose.sh" "$verb" || stack_exit=$?
    if [ "$verb" = down ] && [ "$stack_exit" -ne 0 ]; then
        err "docker-compose.sh down failed with exit code $stack_exit"
        return 1
    fi
}

write_recovery_hint() {
    err "The volumes were deleted. Recover with: ./docker-compose.sh up"
    err "If that keeps failing: ./docker-compose.sh up --fresh   then   ./docker-compose.sh restore $1"
}

# get_stack_volumes: this stack's own volumes, matched by compose project label and re-checked by name
# prefix, so a volume of another project is never named whatever the label filter says.
get_stack_volumes() {
    local names name
    names=$(docker volume ls -q --filter "label=com.docker.compose.project=$prove_project") || {
        err "could not list the volumes of $prove_project"
        return 1
    }
    while IFS= read -r name; do
        [[ $name == "${prove_project}_"* ]] && echo "$name"
    done <<<"$names"
    return 0
}

remove_stack_volumes() {
    local names volumes=() volume
    names=$(get_stack_volumes) || return 1
    [ -z "$names" ] || mapfile -t volumes <<<"$names"
    if [ ${#volumes[@]} -eq 0 ]; then
        err "no volume labelled com.docker.compose.project=$prove_project was found"
        return 1
    fi
    for volume in "${volumes[@]}"; do note "  removing $volume"; done
    docker volume rm "${volumes[@]}" || { err "could not remove the volumes of $prove_project"; return 1; }
}

# invoke_prove_data: proves that deleting every volume of the stack loses nothing: dump, count,
# delete, start, count. DESTRUCTIVE: it deletes the stack's volumes, so run it only with the owner's
# go-ahead. It refuses to start without data/secrets/pgsodium_root.key, because the restored database
# cannot be decrypted without it. A fresh dump is taken right before the "before" count, so writes
# after an older dump cannot look like a failed restore, and the stack must be running, because the
# counts come from its database.
invoke_prove_data() {
    local container newest before after differences line
    [ -e "$here/data/secrets/pgsodium_root.key" ] ||
        fail "data/secrets/pgsodium_root.key is missing; the restored database could not be decrypted"
    for container in "$prove_backup_container" "$prove_database_container"; do
        test_container_is_running "$container" || fail "$container is not running; start the stack first"
    done

    step "Writing a fresh dump ..."
    invoke_backup
    newest=$(newest_dump "$backups_folder" "$dump_pattern") || fail "data/backups cannot be listed"
    [ -n "$newest" ] || fail "no complete dump exists in data/backups"
    test_dump_is_restorable "$backups_folder/$newest" ||
        fail "$newest cannot be listed by pg_restore or holds no table data; nothing was deleted"

    step "Counting rows before ..."
    before=$(get_shelf_table_counts) || fail "the rows could not be counted; nothing was deleted"
    [ "$(count_lines "$before")" -gt 0 ] || fail "no table was counted; nothing was deleted"
    note "  $(count_lines "$before") tables, dump $newest"

    step "Stopping the stack and deleting its volumes ..."
    if ! invoke_stack down || ! remove_stack_volumes; then write_recovery_hint "$newest"; exit 1; fi

    step "Starting the stack and waiting for the self-restore ..."
    invoke_stack up

    step "Counting rows after ..."
    if ! after=$(get_shelf_table_counts); then write_recovery_hint "$newest"; exit 1; fi
    write_uncompared_counts "$before" "$after"
    differences=$(compare_table_counts "$before" "$after" "${prove_uncompared_tables[@]}")
    if [ -n "$differences" ]; then
        while IFS= read -r line; do err "  DIFFERS $line"; done <<<"$differences"
        write_recovery_hint "$newest"
        exit 1
    fi
    ok "all $(count_lines "$after") tables match"
    ok "every table came back"
}

count_lines() { grep -c . <<<"$1" || true; }
