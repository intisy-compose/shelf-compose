#!/bin/bash
# The bash twin of database-key.ps1. Source after data-on-disk.sh: assert_database_key needs
# database_volume_is_empty and complete_dumps.

# assert_database_key KEY_PATH VOLUME [BACKUPS_FOLDER] [DUMP_PATTERN]: makes sure the pgsodium root key
# exists on disk before the database starts; prints why not and fails otherwise.
# The key is bind-mounted into the db container. A key generated while the database volume already
# holds a cluster, or while dumps exist that were made with the old key, would not decrypt them and
# would silently replace the lost one, so this fails instead and leaves the file absent. That holds
# for a deliberate `up --fresh` too: the dumps are still needed later. A new key is 64 lowercase hex
# characters with no newline, readable by its owner only: the db container's entrypoint copies it as
# root from the read-only bind.
assert_database_key() {
    local key_path=$1 volume=$2 backups_folder=${3:-} dump_pattern=${4:-shelf-*.dump} dumps
    [ -f "$key_path" ] && return 0
    if [ -d "$key_path" ]; then
        echo "$key_path is a folder, not the encryption key file. Docker creates that folder when it starts the database without the key; remove it and put the key file there (or remove it alone when the database volume is empty and there are no dumps)."
        return 1
    fi
    if ! database_volume_is_empty "$volume"; then
        echo "The encryption key $key_path is missing but volume $volume holds a database. Restore the key file there; a new key cannot decrypt it."
        return 1
    fi
    if [ -n "$backups_folder" ]; then
        if ! dumps=$(complete_dumps "$backups_folder" "$dump_pattern" 2>&1); then
            echo "$dumps"
            return 1
        fi
        if [ -n "$dumps" ]; then
            echo "The encryption key $key_path is missing but $backups_folder holds database dumps. They can only be restored with the original pgsodium_root.key: put that file at $key_path. A new key would not decrypt them, so none is generated, and that includes 'up --fresh': the dumps are still needed later."
            return 1
        fi
    fi
    mkdir -p "$(dirname "$key_path")"
    (umask 077 && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$key_path")
}
