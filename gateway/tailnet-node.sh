#!/bin/bash
# The shared gateway from intisy-compose/workflows gateway/, vendored byte for byte. Sourced by a
# stack's docker-compose.sh, whose delete removes the stack's node from the tailnet with it. The
# PowerShell twin is tailnet-node.ps1, with the same messages.

tailnet_machines_page=https://login.tailscale.com/admin/machines
tailnet_api=https://api.tailscale.com/api/v2

tailnet_step() { printf '\033[36m%s\033[0m\n' "$*"; }
tailnet_ok()   { printf '  \033[32m%s\033[0m\n' "$*"; }
tailnet_err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# tailnet_node_id: the stable node ID of the current profile in the tailscaled.state on stdin, or
# nothing when the state names none. The ID, never the name, picks the node: another device may carry
# the same name.
tailnet_node_id() {
    python3 -c '
import base64, json, re, sys
try:
    state = json.load(sys.stdin)
    current = base64.b64decode(state["_current-profile"]).decode()
    profiles = json.loads(base64.b64decode(state["_profiles"]))
    node = next(profile.get("NodeID") or "" for profile in profiles.values() if profile.get("Key") == current)
except Exception:
    sys.exit(0)
if re.fullmatch(r"[A-Za-z0-9]+", node):
    print(node)
' 2>/dev/null || true
}

# tailnet_api_token CONFIG_FILE: the last TS_API_TOKEN the file sets, trimmed and unquoted, or nothing.
tailnet_api_token() {
    [ -f "$1" ] || return 0
    tr -d '\r' <"$1" | awk '
        match($0, /^[ \t]*TS_API_TOKEN[ \t]*=/) {
            value = substr($0, RLENGTH + 1); sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value)
            gsub(/^"+|"+$/, "", value)
        }
        END { print value }'
}

tailnet_manual_step() {
    tailnet_err "  Remove $1 (node ID $2) on the Machines page: $tailnet_machines_page"
}

# tailnet_delete_status NODE_ID TOKEN: the HTTP status of the API's DELETE of the device, or 000 when
# nothing answered. The token goes through curl's config on stdin, so it is on no command line.
tailnet_delete_status() {
    local code
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$2" |
        curl --config - -s -o /dev/null -w '%{http_code}' --max-time 30 -X DELETE "$tailnet_api/device/$1") || true
    echo "${code:-000}"
}

# remove_tailnet_node NODE_ID NAME CONFIG_FILE: removes the node with that stable ID through the
# Tailscale API with the TS_API_TOKEN of CONFIG_FILE. Returns 0 when the node is gone, 2 when there is
# no token (the manual step is printed instead) and 1 when the API did not remove it.
remove_tailnet_node() {
    local node_id=$1 name=$2 token code
    token=$(tailnet_api_token "$3")
    if [ -z "$token" ]; then
        tailnet_err "No TS_API_TOKEN in $(basename "$3"), so $name stays in the tailnet."
        tailnet_manual_step "$name" "$node_id"
        return 2
    fi
    if [[ ! $token =~ ^[A-Za-z0-9_-]+$ ]]; then
        tailnet_err "TS_API_TOKEN in $(basename "$3") is not a Tailscale API token, so $name was not removed."
        tailnet_manual_step "$name" "$node_id"
        return 1
    fi
    tailnet_step "Removing $name (node ID $node_id) from the tailnet..."
    code=$(tailnet_delete_status "$node_id" "$token")
    case $code in
        200 | 204) tailnet_ok "Removed $name from the tailnet."; return 0 ;;
        404)
            tailnet_ok "The tailnet has no node $node_id any more, so there is nothing to remove."
            tailnet_ok "If $name is still listed, the token is for another tailnet: remove it on $tailnet_machines_page"
            return 0 ;;
        000) tailnet_err "The Tailscale API did not answer, so $name was not removed." ;;
        401 | 403) tailnet_err "The Tailscale API refused TS_API_TOKEN (HTTP $code): it has expired or may not remove devices, so $name was not removed." ;;
        *) tailnet_err "The Tailscale API answered HTTP $code, so $name was not removed." ;;
    esac
    tailnet_manual_step "$name" "$node_id"
    return 1
}

# remove_tailnet_identity STATE_FOLDER NAME CONFIG_FILE: the tailnet half of a stack's delete, for a
# stack whose node state is STATE_FOLDER. Removes the node the state identifies, then the folder, so a
# later up joins fresh. The folder stays whenever its node may still be in the tailnet and the API can
# still remove it: an API error, or a state that names no node.
remove_tailnet_identity() {
    local folder=${1:?names the tailnet state folder} name=$2 config=$3 node_id result=0
    if [ ! -f "$folder/tailscaled.state" ]; then
        tailnet_ok "No node identity in $folder, so no node is removed from the tailnet."
        rm -rf "$folder"
        return 0
    fi
    node_id=$(tailnet_node_id <"$folder/tailscaled.state")
    if [ -z "$node_id" ]; then
        tailnet_err "$folder/tailscaled.state names no node, so none is removed and $folder is kept."
        tailnet_err "  Remove $name on the Machines page, $tailnet_machines_page, then delete $folder."
        return 1
    fi
    remove_tailnet_node "$node_id" "$name" "$config" || result=$?
    if [ "$result" -eq 1 ]; then
        tailnet_err "$folder is kept, so delete can run again."
        return 1
    fi
    rm -rf "$folder"
    tailnet_ok "Removed $folder; the next up joins the tailnet fresh."
}
