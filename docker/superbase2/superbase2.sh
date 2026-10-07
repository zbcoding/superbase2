#!/bin/bash
#
# SuperBase² — multi-project orchestration for self-hosted Supabase
#
# Shares heavy containers (Postgres, Kong, Studio, imgproxy, analytics, vector)
# and spins up lightweight per-project containers (GoTrue, PostgREST, Realtime,
# Storage, Edge Functions, postgres-meta).
#
# Usage:
#   ./superbase2.sh setup <name>          Create + start a project in one step
#   ./superbase2.sh create <name>         Create a new project (DB + secrets only)
#   ./superbase2.sh destroy <name>        Destroy a project (removes containers + data)
#   ./superbase2.sh list                  List all projects
#   ./superbase2.sh up [name]             Start project containers (all if no name)
#   ./superbase2.sh down [name]           Stop project containers (all if no name)
#   ./superbase2.sh status [name]         Show container status
#   ./superbase2.sh client-config <name>  Print client SDK config
#   ./superbase2.sh rebuild-kong          Regenerate Kong config and reload
#   ./superbase2.sh verify [name]        Check container JWT secrets match manifest
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# State (manifest + per-project disk dirs) lives in SB2_STATE_DIR when set
# — required for the Coolify layout, where Studio and the agent share a
# named volume instead of bind-mounting the repo.
STATE_DIR="${SB2_STATE_DIR:-$SCRIPT_DIR}"
PROJECTS_DIR="$STATE_DIR/projects"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
PROJECTS_MANIFEST="$STATE_DIR/projects.json"

mkdir -p "$STATE_DIR"

# Ensure the manifest file exists (prevents Docker from bind-mounting a directory)
[ -f "$PROJECTS_MANIFEST" ] || echo '{ "projects": [] }' > "$PROJECTS_MANIFEST"

# Require jq for JSON manipulation
if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' is required but not installed."
    echo "  Install it with:  apt-get install jq  /  brew install jq  /  apk add jq"
    exit 1
fi

# Load the main .env for shared config. Present when the script runs on the
# host, and in the overlay's sb2-agent (which mounts docker/ at /workspace);
# on Coolify and standalone the shared creds come in through the container
# environment.
# It's compose dotenv, not shell: upstream ships unquoted values with spaces
# (STUDIO_DEFAULT_ORGANIZATION=Default Organization), so parse KEY=VALUE
# lines and strip one pair of surrounding quotes instead of sourcing it.
load_dotenv() {
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key=${BASH_REMATCH[2]}
        value=${BASH_REMATCH[3]}
        if [[ $value =~ ^\"(.*)\"[[:space:]]*$ || $value =~ ^\'(.*)\'[[:space:]]*$ ]]; then
            value=${BASH_REMATCH[1]}
        fi
        export "$key=$value"
    done < "$1"
}
if [ -f "$DOCKER_DIR/.env" ]; then
    load_dotenv "$DOCKER_DIR/.env"
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Resolve a main-stack container by its compose service name. On a stock
# standalone install the names are literal (`supabase-db`, `supabase-kong`),
# but Coolify names compose services `<service>-<app-uuid>-<deploy-id>`
# (e.g. `db-nwcirqsw…-052516224648`). We discover them from the
# `com.docker.compose.service` label so the script works in both layouts.
#
# Override the database container with SB2_DB_CONTAINER if you have a
# non-standard naming scheme.

# When invoked from inside an sb2 container (agent, kong-sb2-init) we read our
# own compose project label from /etc/hostname → docker inspect, so lookups are
# scoped to this stack and never match a same-named service belonging to
# another stack on the host. On a host-side run /etc/hostname is the host's
# hostname (not a container id) and the inspect fails harmlessly.
own_compose_project() {
    local own_id=""
    [ -r /etc/hostname ] && own_id=$(tr -d '[:space:]' < /etc/hostname 2>/dev/null || true)
    [ -n "$own_id" ] || return 0
    docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$own_id" 2>/dev/null || true
}

# Print the running container for a main-stack service, or nothing.
# $1 = compose service name, $2 = literal name used by the standalone layout.
service_container() {
    local service="$1"
    local literal="${2:-}"

    local own_project found=""
    own_project=$(own_compose_project)
    if [ -n "$own_project" ]; then
        found=$(docker ps \
            --filter "label=com.docker.compose.service=$service" \
            --filter "label=com.docker.compose.project=$own_project" \
            --format '{{.Names}}' 2>/dev/null | head -n 1)
    elif [ -n "$literal" ] && docker inspect "$literal" &>/dev/null; then
        # Host-side run: prefer the standalone layout's literal name over an
        # unscoped label match, which could pick another stack's container.
        found="$literal"
    else
        found=$(docker ps --filter "label=com.docker.compose.service=$service" \
                          --format '{{.Names}}' 2>/dev/null | head -n 1)
    fi
    echo "$found"
}

db_container() {
    if [ -n "${SB2_DB_CONTAINER:-}" ]; then
        echo "$SB2_DB_CONTAINER"
        return
    fi
    local found
    found=$(service_container db supabase-db)
    # Fallback: literal name used by the standalone (non-Coolify) layout.
    echo "${found:-supabase-db}"
}

# Kong is the `kong` service in docker-compose.coolify.yml, but upstream's
# docker-compose.kong.yml (used by the standalone overlay) turns `api-gw` into
# Kong, container `supabase-kong`. Without that override `api-gw` is Envoy,
# so check the image before treating the container as Kong.
kong_container() {
    local service found
    for service in kong api-gw; do
        found=$(service_container "$service" supabase-kong)
        [ -n "$found" ] || continue
        case "$(docker inspect -f '{{.Config.Image}}' "$found" 2>/dev/null)" in
            *kong*) echo "$found"; return ;;
        esac
    done
}

# kong/kong images run as kong, uid/gid 1001.
KONG_UID=1001

# Install the rendered Kong config at $2. It carries every project's API keys,
# so it is readable by Kong's user only. Non-root host runs can't chown, so
# they do it through a throwaway container (alpine:3.19 is already pulled for
# superbase2-init). The rename works either way: the directory is ours.
install_kong_config() {
    local src="$1" dest="$2" staged="$2.new"
    cp "$src" "$staged"
    chmod 600 "$staged"
    if [ "$(id -u)" = 0 ]; then
        chown "$KONG_UID:$KONG_UID" "$staged"
    elif ! docker run --rm --user 0 --entrypoint chown \
            -v "$(dirname "$staged"):/api:z" alpine:3.19 \
            "$KONG_UID:$KONG_UID" "/api/$(basename "$staged")" >/dev/null 2>&1; then
        echo "Warning: couldn't hand $dest to Kong's user; leaving it world-readable"
        chmod 644 "$staged"
    fi
    mv -f "$staged" "$dest"
}

# Each project's edge functions run user code, so they get their own network
# (sb2-fn-<name>) instead of the shared stack network, where they could reach
# every project's unauthenticated pg-meta, the main pg-meta (supabase_admin),
# Studio and this agent. Only Kong (alias `kong`, the functions' SUPABASE_URL
# host) and Postgres (alias $POSTGRES_HOST) join it. The network is external
# to the project's compose file, so `down` leaves it; destroy removes it.
#
# Recreated containers (a Coolify redeploy) lose the attachment, so this runs
# on every start, every rebuild-kong and the agent's periodic check
# (connect-networks). Idempotent.
_connect_functions_network() {
    local net="sb2-fn-$1" kong_ctr db_ctr db_alias="${POSTGRES_HOST:-db}"
    if ! docker network inspect "$net" >/dev/null 2>&1; then
        # A concurrent run may have just created it.
        docker network create "$net" >/dev/null 2>&1 || docker network inspect "$net" >/dev/null
    fi
    kong_ctr=$(kong_container)
    db_ctr=$(db_container)
    # An IP POSTGRES_HOST is reached by routing, not by name.
    [[ "$db_alias" =~ ^[0-9.]+$|: ]] && db_alias=""
    _attach_to_network "$net" "$kong_ctr" kong
    _attach_to_network "$net" "$db_ctr" "$db_alias"
}

_attach_to_network() {
    local net="$1" ctr="$2" alias="$3"
    if [ -z "$ctr" ] || ! docker inspect "$ctr" >/dev/null 2>&1; then
        echo "Warning: no running container to attach to $net${alias:+ as $alias}" >&2
        return 0
    fi
    if [ "$(docker inspect -f "{{if index .NetworkSettings.Networks \"$net\"}}yes{{end}}" "$ctr" 2>/dev/null)" = yes ]; then
        return 0
    fi
    docker network connect ${alias:+--alias "$alias"} "$net" "$ctr" >/dev/null 2>&1 \
        || echo "Warning: failed to attach $ctr to $net" >&2
}

cmd_connect_networks() {
    local proj
    for proj in $(list_projects); do
        docker network inspect "sb2-fn-$proj" >/dev/null 2>&1 && _connect_functions_network "$proj"
    done
    return 0
}

_remove_functions_network() {
    local net="sb2-fn-$1" ctr
    docker network inspect "$net" >/dev/null 2>&1 || return 0
    for ctr in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net"); do
        docker network disconnect -f "$net" "$ctr" >/dev/null 2>&1 || true
    done
    docker network rm "$net" >/dev/null 2>&1 || echo "Warning: failed to remove network $net"
}

# Serialize every state-changing command (create, destroy, up, down,
# rotate-keys, rebuild-kong, ...) across processes and containers: the agent,
# the kong-sb2-init one-shot and host-side CLI runs all share STATE_DIR.
# Concurrent runs would otherwise interleave writes to kong.yml, the project
# .env files and the compose files. flock releases automatically when the
# process exits, so a crashed run can't leave a stale lock behind.
acquire_state_lock() {
    if ! command -v flock &>/dev/null; then
        echo "Error: 'flock' is required but not installed (util-linux / busybox)." >&2
        exit 1
    fi
    exec 9>"$STATE_DIR/.superbase2.lock"
    # Poll with -n: BusyBox flock (sb2-agent image) has no -w timeout option.
    local waited=0 timeout="${SB2_LOCK_TIMEOUT:-900}"
    until flock -n 9; do
        if [ "$waited" -eq 0 ]; then
            echo "Waiting for another superbase2.sh command to finish..." >&2
        fi
        if [ "$waited" -ge "$timeout" ]; then
            echo "Error: timed out waiting for another superbase2.sh command to finish." >&2
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# Lock for projects.json, shared with Studio (apps/studio/lib/superbase2/
# projects.ts): the lock file is created with O_EXCL (noclobber) and holds
# "<pid>:<epoch-ms>"; a lock older than 10 s is considered stale. Keep the
# critical section well under that, or Studio will break the lock.
MANIFEST_LOCK="$PROJECTS_MANIFEST.lock"
MANIFEST_LOCK_STALE_MS=10000

_now_ms() {
    date +%s%3N
}

acquire_manifest_lock() {
    local deadline=$(( $(_now_ms) + 15000 ))
    while ! ( set -o noclobber; printf '%s:%s' "$$" "$(_now_ms)" > "$MANIFEST_LOCK" ) 2>/dev/null; do
        local held_since
        held_since=$(cut -d: -f2 "$MANIFEST_LOCK" 2>/dev/null || true)
        if [[ "$held_since" =~ ^[0-9]+$ ]] && [ $(( $(_now_ms) - held_since )) -gt "$MANIFEST_LOCK_STALE_MS" ]; then
            # Rename before deleting so two processes breaking the same stale
            # lock can't delete a fresh one (same protocol as Studio).
            mv "$MANIFEST_LOCK" "$MANIFEST_LOCK.stale.$$" 2>/dev/null && rm -f "$MANIFEST_LOCK.stale.$$"
            continue
        fi
        if [ "$(_now_ms)" -gt "$deadline" ]; then
            echo "Error: timed out waiting for the manifest lock ($MANIFEST_LOCK)." >&2
            exit 1
        fi
        sleep 0.05
    done
}

release_manifest_lock() {
    rm -f "$MANIFEST_LOCK"
}

# Export the images the main stack is running for the services each project
# also runs, so per-project containers always match the main stack instead of
# the template's fallback pins. A Coolify redeploy that bumps an image then
# reaches every project on its next `up` (the agent runs `reconcile` at start).
#
# Returns 1 (listing the missing services) if any main-stack service isn't
# running: falling back to the template pins could downgrade a project whose
# database a newer image already migrated on an earlier `up`.
export_main_stack_images() {
    local entry service literal var image ctr missing=""
    for entry in auth:supabase-auth:GOTRUE_IMAGE \
                 rest:supabase-rest:POSTGREST_IMAGE \
                 realtime:realtime-dev.supabase-realtime:REALTIME_IMAGE \
                 storage:supabase-storage:STORAGE_IMAGE \
                 imgproxy:supabase-imgproxy:IMGPROXY_IMAGE \
                 meta:supabase-meta:POSTGRES_META_IMAGE \
                 functions:supabase-edge-functions:EDGE_RUNTIME_IMAGE; do
        IFS=: read -r service literal var <<< "$entry"
        # An explicit override (e.g. from the host .env) wins.
        [ -n "${!var:-}" ] && continue
        ctr=$(service_container "$service" "$literal")
        image=""
        [ -n "$ctr" ] && image=$(docker inspect -f '{{.Config.Image}}' "$ctr" 2>/dev/null || true)
        if [ -n "$image" ]; then
            export "$var=$image"
        else
            missing="$missing $service"
        fi
    done
    if [ -n "$missing" ]; then
        echo "Error: main-stack service(s) not running:$missing." >&2
        echo "  Per-project containers use the same images as the main stack; start it first" >&2
        echo "  (or set the matching *_IMAGE variables to override)." >&2
        return 1
    fi
}

gen_hex() {
    openssl rand -hex "$1"
}

gen_base64() {
    openssl rand -base64 "$1"
}

base64_url_encode() {
    openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

gen_jwt() {
    local role="$1"
    local secret="$2"
    local header='{"alg":"HS256","typ":"JWT"}'
    local iat
    iat=$(date +%s)
    local exp=$((iat + 5 * 3600 * 24 * 365)) # 5 years

    local payload="{\"role\":\"${role}\",\"iss\":\"supabase\",\"iat\":${iat},\"exp\":${exp}}"
    local header_b64
    header_b64=$(printf '%s' "$header" | base64_url_encode)
    local payload_b64
    payload_b64=$(printf '%s' "$payload" | base64_url_encode)
    local signed_content="${header_b64}.${payload_b64}"
    local signature
    signature=$(printf '%s' "$signed_content" | openssl dgst -binary -sha256 -hmac "$secret" | base64_url_encode)
    printf '%s' "${signed_content}.${signature}"
}

gen_project_ref() {
    openssl rand -hex 10
}

ensure_projects_dir() {
    mkdir -p "$PROJECTS_DIR"
}

# Read disabled_services array from manifest for a given project name.
# Returns space-separated list of disabled services, or empty string.
get_disabled_services() {
    local name="$1"
    if [ -f "$PROJECTS_MANIFEST" ] && [ -s "$PROJECTS_MANIFEST" ]; then
        jq -r --arg name "$name" \
            '(.projects[] | select(.name == $name) | .disabled_services // []) | .[]' \
            "$PROJECTS_MANIFEST" 2>/dev/null || true
    fi
}

# Remove disabled service blocks from a docker-compose file.
# Each service block starts with "  <service>-<name>:" and ends before the next
# service or top-level key. Uses awk for multi-line block removal.
#
# Filtering is scoped to the `services:` section only — sibling top-level
# sections (volumes, networks, configs, secrets) frequently contain entries
# whose names collide with service names (e.g. a `functions-vrsite:` named
# volume), and stripping those would break the resulting compose file.
#
# A disabled service also takes its companion blocks with it — the
# `<svc>-init-<name>` seeder (it references the disabled service's volume) and,
# for storage, `imgproxy-<name>` (it mounts the storage volume) — so we don't
# leave an orphan referencing an undeclared volume.
filter_disabled_services() {
    local compose_file="$1"
    local name="$2"
    local disabled
    disabled=$(get_disabled_services "$name")

    if [ -z "$disabled" ]; then
        return  # Nothing to filter
    fi

    local tmp_file
    tmp_file=$(mktemp)
    # Expand the path now: the EXIT trap can fire after this function returns
    # (reconcile runs each project in a subshell), when the local is gone and
    # `set -u` would abort on it.
    trap "rm -f '$tmp_file' '$tmp_file.new'" EXIT
    cp "$compose_file" "$tmp_file"

    for svc in $disabled; do
        # The service key in the compose file is "<svc>-<name>:"
        local svc_key="${svc}-${name}"
        local init_key="${svc}-init-${name}"
        local companion_key=""
        [ "$svc" = "storage" ] && companion_key="imgproxy-${name}"
        awk \
            -v svc_line="  ${svc_key}:" \
            -v init_line="  ${init_key}:" \
            -v companion_line="${companion_key:+  ${companion_key}:}" '
        BEGIN { skip=0; in_services=0 }
        # Enter / leave the services: section based on top-level keys.
        /^services:[[:space:]]*$/ { in_services=1; skip=0; print; next }
        /^[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*$/ { in_services=0; skip=0 }
        # Only strip blocks inside the services: section.
        in_services && ($0 == svc_line || $0 == init_line || (companion_line != "" && $0 == companion_line)) { skip=1; next }
        # Stop skipping at the next sibling service (2-space indent + alpha).
        skip && /^  [a-zA-Z]/ { skip=0 }
        # Or at the next top-level key.
        skip && /^[a-zA-Z]/ { skip=0 }
        !skip { print }
        ' "$tmp_file" > "${tmp_file}.new"
        mv "${tmp_file}.new" "$tmp_file"
    done

    mv "$tmp_file" "$compose_file"
}

# Write the JSON manifest that Studio reads (bind-mounted into the container).
# Called after every create/destroy to keep it in sync with project .env files.
sync_manifest() {
    # Merge disk-scanned projects with existing manifest entries.
    # Disk entries win on conflicts; manifest-only entries (e.g. API-created) are preserved.
    # The disk scan runs before taking the manifest lock (it can take a while
    # with many projects); only the read-merge-write of projects.json is locked.

    # Build array of disk-scanned projects
    local disk_json='[]'
    declare -A disk_projects
    for d in "$PROJECTS_DIR"/*/; do
        [ -d "$d" ] || continue
        local name ref db jwt_secret anon_key service_role_key created_at
        local secret_key_base pg_meta_crypto_key s3_access_key_id s3_access_key_secret db_password
        name=$(basename "$d")
        [ -f "$d/.env" ] || continue
        disk_projects["$name"]=1
        ref=$(grep "^PROJECT_REF=" "$d/.env" | cut -d= -f2-)
        db=$(grep "^PROJECT_DB=" "$d/.env" | cut -d= -f2-)
        jwt_secret=$(grep "^PROJECT_JWT_SECRET=" "$d/.env" | cut -d= -f2-)
        anon_key=$(grep "^PROJECT_ANON_KEY=" "$d/.env" | cut -d= -f2-)
        service_role_key=$(grep "^PROJECT_SERVICE_ROLE_KEY=" "$d/.env" | cut -d= -f2-)
        created_at=$(grep "^# Generated:" "$d/.env" | sed 's/# Generated: //')
        [ -z "$created_at" ] && created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        # Secondary secrets — must be synced to manifest so disk state reconstruction works
        secret_key_base=$(grep "^PROJECT_SECRET_KEY_BASE=" "$d/.env" | cut -d= -f2-)
        db_enc_key=$(grep "^PROJECT_DB_ENC_KEY=" "$d/.env" | cut -d= -f2-)
        pg_meta_crypto_key=$(grep "^PROJECT_PG_META_CRYPTO_KEY=" "$d/.env" | cut -d= -f2-)
        s3_access_key_id=$(grep "^PROJECT_S3_ACCESS_KEY_ID=" "$d/.env" | cut -d= -f2-)
        s3_access_key_secret=$(grep "^PROJECT_S3_ACCESS_KEY_SECRET=" "$d/.env" | cut -d= -f2-)
        # `|| true` because unlike the keys above this one is absent on projects
        # that predate per-project roles, and `set -o pipefail` would abort the
        # whole sync on the failed grep.
        db_password=$(grep "^PROJECT_DB_PASSWORD=" "$d/.env" | cut -d= -f2- || true)

        disk_json=$(echo "$disk_json" | jq \
            --arg ref "$ref" \
            --arg name "$name" \
            --arg db "$db" \
            --arg jwt "$jwt_secret" \
            --arg anon "$anon_key" \
            --arg srk "$service_role_key" \
            --arg ca "$created_at" \
            --arg skb "$secret_key_base" \
            --arg dek "$db_enc_key" \
            --arg pmck "$pg_meta_crypto_key" \
            --arg s3id "$s3_access_key_id" \
            --arg s3sec "$s3_access_key_secret" \
            --arg dbpw "$db_password" \
            '. + [{ref: $ref, name: $name, db: $db, jwt_secret: $jwt, anon_key: $anon, service_role_key: $srk, status: "ACTIVE_HEALTHY", created_at: $ca, secret_key_base: $skb, db_enc_key: $dek, pg_meta_crypto_key: $pmck, s3_access_key_id: $s3id, s3_access_key_secret: $s3sec, db_password: $dbpw}]')
    done

    # Collect disk project names into a jq-friendly array
    local disk_names_json='[]'
    for dname in "${!disk_projects[@]}"; do
        disk_names_json=$(echo "$disk_names_json" | jq --arg n "$dname" '. + [$n]')
    done

    acquire_manifest_lock
    # Studio writes projects.json under the same lock, so reading it here and
    # writing it back below can't drop an entry Studio added in between.
    local existing_json='{"projects":[]}'
    if [ -f "$PROJECTS_MANIFEST" ] && [ -s "$PROJECTS_MANIFEST" ]; then
        # Fail instead of treating an unreadable manifest as empty: that would
        # silently drop every API-created project that has no disk state yet.
        if ! existing_json=$(jq '.' "$PROJECTS_MANIFEST"); then
            release_manifest_lock
            echo "Error: $PROJECTS_MANIFEST is not valid JSON; refusing to overwrite it." >&2
            exit 1
        fi
    fi

    # Preserve manifest-only entries (API-created projects not yet on disk)
    local manifest_only
    manifest_only=$(echo "$existing_json" | jq --argjson names "$disk_names_json" \
        '[.projects[] | select(.name as $n | $names | index($n) | not)]')

    # disabled_services is written by the Studio API into the manifest only —
    # it has no .env counterpart, so rebuilding a disk entry from .env drops it
    # and silently re-enables services the user turned off. Carry it across.
    local disabled_map
    disabled_map=$(echo "$existing_json" | jq \
        '[.projects[] | select(.disabled_services != null) | {key: .name, value: .disabled_services}] | from_entries')

    # Merge: disk projects first, then manifest-only entries. Write to a temp
    # file in the same directory and rename, so Studio never reads a partial file.
    local manifest_tmp
    manifest_tmp=$(mktemp "$PROJECTS_MANIFEST.XXXXXX")
    jq -n --argjson disk "$disk_json" --argjson manifest "$manifest_only" --argjson disabled "$disabled_map" \
        '{projects: (($disk | map(if $disabled[.name] then . + {disabled_services: $disabled[.name]} else . end)) + $manifest)}' \
        > "$manifest_tmp"
    chmod 600 "$manifest_tmp"
    mv "$manifest_tmp" "$PROJECTS_MANIFEST"
    release_manifest_lock
}

project_exists() {
    [ -d "$PROJECTS_DIR/$1" ]
}

list_projects() {
    if [ -d "$PROJECTS_DIR" ]; then
        for d in "$PROJECTS_DIR"/*/; do
            [ -d "$d" ] && basename "$d"
        done
    fi
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_create() {
    local name="$1"

    # Validate project name: lowercase letters and digits; 2-48 chars.
    # No uppercase — Docker Compose rejects it in the project name (supabase-<name>),
    # so the project could be created but never started.
    # No underscores — Docker DNS does not support them in service hostnames (RFC 1123),
    # which would break per-project container resolution (e.g. meta-<name>).
    # No hyphens — reserved for future use and avoided for DB name safety.
    if [[ ! "$name" =~ ^[a-z0-9]+$ ]]; then
        echo "Error: Invalid project name '$name'."
        echo "Project names may only contain lowercase letters and numbers (no underscores or hyphens)."
        exit 1
    fi

    if [ ${#name} -lt 2 ]; then
        echo "Error: Project name '$name' is too short (min 2 characters)."
        exit 1
    fi

    if [ ${#name} -gt 48 ]; then
        echo "Error: Project name '$name' is too long (max 48 characters)."
        exit 1
    fi

    if project_exists "$name"; then
        echo "Error: Project '$name' already exists."
        exit 1
    fi

    echo "Creating project: $name"

    ensure_projects_dir
    local project_dir="$PROJECTS_DIR/$name"
    mkdir -p "$project_dir"
    # Storage + functions are named Docker volumes in the generated compose
    # (see templates/docker-compose.project.yml.tpl). An init service inside
    # that compose seeds main/index.ts into the functions volume on first
    # boot, so we don't write anything to disk here.

    # Generate unique secrets
    local project_ref
    project_ref=$(gen_project_ref)
    local jwt_secret
    jwt_secret=$(gen_base64 30)
    local anon_key
    anon_key=$(gen_jwt "anon" "$jwt_secret")
    local service_role_key
    service_role_key=$(gen_jwt "service_role" "$jwt_secret")
    local secret_key_base
    secret_key_base=$(gen_base64 48)
    local db_enc_key
    # Realtime uses AES-128-ECB which requires a 16-byte key. gen_hex 8 → 16 hex chars = 16 ASCII bytes.
    db_enc_key=$(gen_hex 8)
    local pg_meta_crypto_key
    pg_meta_crypto_key=$(gen_base64 24)
    local s3_access_key_id
    s3_access_key_id=$(gen_hex 16)
    local s3_access_key_secret
    s3_access_key_secret=$(gen_hex 32)
    local db_name="project_${name}"
    local db_password
    # Hex so it needs no escaping in a connection string or in DDL.
    db_password=$(gen_hex 24)

    # Write project .env. It holds the project's JWT secret and DB password:
    # restrict it before any secret is written.
    : > "$project_dir/.env"
    chmod 600 "$project_dir/.env"
    cat > "$project_dir/.env" <<EOF
# Project: $name
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

PROJECT_NAME=$name
PROJECT_REF=$project_ref
PROJECT_DB=$db_name

# JWT
PROJECT_JWT_SECRET=$jwt_secret
PROJECT_ANON_KEY=$anon_key
PROJECT_SERVICE_ROLE_KEY=$service_role_key

# Secrets
PROJECT_SECRET_KEY_BASE=$secret_key_base
PROJECT_DB_ENC_KEY=$db_enc_key
PROJECT_PG_META_CRYPTO_KEY=$pg_meta_crypto_key
PROJECT_S3_ACCESS_KEY_ID=$s3_access_key_id
PROJECT_S3_ACCESS_KEY_SECRET=$s3_access_key_secret
PROJECT_DB_PASSWORD=$db_password

# Shared infra (from main .env)
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_HOST=db
POSTGRES_PORT=${POSTGRES_PORT:-5432}
JWT_EXPIRY=${JWT_EXPIRY:-3600}

# URLs
SUPABASE_PUBLIC_URL=${SUPABASE_PUBLIC_URL:-http://localhost:8000}
SITE_URL=${SITE_URL:-http://localhost:3000}
ADDITIONAL_REDIRECT_URLS=${ADDITIONAL_REDIRECT_URLS:-}

# Auth settings
DISABLE_SIGNUP=${DISABLE_SIGNUP:-false}
ENABLE_EMAIL_SIGNUP=${ENABLE_EMAIL_SIGNUP:-true}
ENABLE_EMAIL_AUTOCONFIRM=${ENABLE_EMAIL_AUTOCONFIRM:-false}
ENABLE_PHONE_SIGNUP=${ENABLE_PHONE_SIGNUP:-true}
ENABLE_PHONE_AUTOCONFIRM=${ENABLE_PHONE_AUTOCONFIRM:-true}
ENABLE_ANONYMOUS_USERS=${ENABLE_ANONYMOUS_USERS:-false}
SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL:-admin@example.com}
SMTP_HOST=${SMTP_HOST:-supabase-mail}
SMTP_PORT=${SMTP_PORT:-2500}
SMTP_USER=${SMTP_USER:-fake_mail_user}
SMTP_PASS=${SMTP_PASS:-fake_mail_password}
SMTP_SENDER_NAME=${SMTP_SENDER_NAME:-fake_sender}

# Storage
GLOBAL_S3_BUCKET=${GLOBAL_S3_BUCKET:-stub}
REGION=${REGION:-local}
STORAGE_TENANT_ID=$project_ref
IMGPROXY_ENABLE_WEBP_DETECTION=${IMGPROXY_ENABLE_WEBP_DETECTION:-true}

# Functions
FUNCTIONS_VERIFY_JWT=${FUNCTIONS_VERIFY_JWT:-true}

# PostgREST
PGRST_DB_SCHEMAS=${PGRST_DB_SCHEMAS:-public,storage,graphql_public}
PGRST_DB_MAX_ROWS=${PGRST_DB_MAX_ROWS:-1000}
PGRST_DB_EXTRA_SEARCH_PATH=${PGRST_DB_EXTRA_SEARCH_PATH:-public,extensions}

# Network
SUPABASE_NETWORK_NAME=${SUPABASE_NETWORK_NAME:-supabase_default}
EOF

    # Generate docker-compose override for this project
    sed \
        -e "s|{{PROJECT_NAME}}|$name|g" \
        -e "s|{{PROJECT_REF}}|$project_ref|g" \
        -e "s|{{PROJECT_DB}}|$db_name|g" \
        "$TEMPLATES_DIR/docker-compose.project.yml.tpl" \
        > "$project_dir/docker-compose.yml"

    # Create the database and initialize schemas
    echo "Creating database: $db_name"
    _init_project_db "$name" "$db_name" "$jwt_secret" "${JWT_EXPIRY:-3600}" "$db_password"

    # Sync manifest for Studio and rebuild Kong
    sync_manifest

    # Remove disabled service blocks from the compose file (if any were
    # set via the API before cmd_create, or via manifest editing)
    filter_disabled_services "$project_dir/docker-compose.yml" "$name"

    cmd_rebuild_kong

    echo ""
    echo "Project '$name' created successfully!"
    echo "  Ref:              $project_ref"
    echo "  Database:         $db_name"
    echo ""
    echo "Start it with:  ./superbase2.sh up $name"
    echo "Client config:  ./superbase2.sh client-config $name"
}

# Create or repair the project's own Postgres login role.
#
# The role is named after the database and owns it, so the DATABASE_URL we hand
# out authenticates as a role that can CREATE in public and ALTER/DROP its own
# tables. Idempotent — this is also the password-rotation path.
#
# Deliberately NOT a member of anon/authenticated/service_role: those hold
# CONNECT on every project database, so membership would let one project's
# credential open every other project's database.
#
# Keep in sync with createProjectRole() in apps/studio/lib/superbase2/db.ts.
_ensure_project_db_role() {
    local role="$1"
    local password="$2"

    if ! [[ "$password" =~ ^[a-f0-9]{32,128}$ ]]; then
        echo "Error: database password must be 32-128 lowercase hex characters."
        exit 1
    fi

    # supabase_admin, not postgres: creating a role with BYPASSRLS and granting
    # pg_read_all_data both require superuser.
    docker exec -i "$(db_container)" psql -U supabase_admin -d postgres <<EOSQL
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$role') THEN
    EXECUTE format('ALTER ROLE %I WITH LOGIN INHERIT BYPASSRLS PASSWORD %L', '$role', '$password');
  ELSE
    EXECUTE format('CREATE ROLE %I LOGIN INHERIT BYPASSRLS PASSWORD %L', '$role', '$password');
  END IF;
END
\$\$;
-- No CREATEROLE / CREATEDB / REPLICATION, and no pg_read_all_data: upstream's
-- \`postgres\` role has them, but roles and databases are cluster-global and a
-- project must not reach outside its own database. Read access to the
-- service-managed schemas is granted per-database instead.
ALTER ROLE "$role" SET search_path TO "\$user", public, extensions;
-- Marks the role for the login trigger that keeps it out of the main stack's
-- databases (_block_project_roles_in_main_dbs). The group holds no privileges.
SELECT 'CREATE ROLE sb2_project_login NOLOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sb2_project_login') \gexec
GRANT sb2_project_login TO "$role";
EOSQL
}

# Set KEY=VALUE in a project .env (replace or append), atomically.
_set_env_var() {
    local env_file="$1" key="$2" value="$3"
    local tmp_env
    tmp_env=$(mktemp)
    awk -v k="$key" -v v="$value" '
        index($0, k "=") == 1 { print k "=" v; seen=1; next }
        { print }
        END { if (!seen) print k "=" v }
    ' "$env_file" > "$tmp_env"
    chmod 600 "$tmp_env"
    mv "$tmp_env" "$env_file"
}

# Give Realtime its own database role instead of supabase_admin.
#
# Realtime connects with DB_USER and creates its own schemas, tables,
# publications and replication slots there. As supabase_admin (superuser) a
# compromised Realtime container owned the whole cluster; this role is
# NOSUPERUSER and cannot connect to any other project's database.
#
# Idempotent, and run on every start (_start_project): it also repairs
# projects created before this role existed, whose _realtime/realtime schemas
# are owned by postgres/supabase_admin and whose `realtime` schema was never
# created at all. Writes PROJECT_REALTIME_DB_USER, PROJECT_REALTIME_DB_PASSWORD
# and PROJECT_REALTIME_SLOT_SUFFIX into the project .env for the compose file.
#
# The role needs PostgreSQL 16+ (GRANT ... WITH INHERIT FALSE); older servers
# fall back to supabase_admin with a warning. Keep the role name in
# sync with dropProjectDatabase() in apps/studio/lib/superbase2/db.ts.
_ensure_realtime_db() {
    local name="$1"
    local env_file="$PROJECTS_DIR/$name/.env"
    local db rt_user rt_password slot_suffix

    db=$(grep "^PROJECT_DB=" "$env_file" | cut -d= -f2-)
    if [ -z "$db" ]; then
        echo "Error: PROJECT_DB missing from $env_file"
        exit 1
    fi
    # '_rt' keeps the name <= 59 chars; Postgres silently truncates at 63.
    rt_user="${db}_rt"

    rt_password=$(grep "^PROJECT_REALTIME_DB_PASSWORD=" "$env_file" | cut -d= -f2- || true)
    if ! [[ "$rt_password" =~ ^[a-f0-9]{32,128}$ ]]; then
        rt_password=$(gen_hex 24)
    fi

    # Replication slot names are cluster-global and Realtime's defaults are not
    # per-project, so two running projects fight over one slot. Names allow
    # [a-z0-9_] and a 19-char suffix (44-char prefix, 63-char limit).
    slot_suffix=$(printf '%s' "$db" | md5sum | cut -c1-16)

    local db_ctr version
    db_ctr=$(db_container)
    version=$(docker exec "$db_ctr" psql -U supabase_admin -d postgres -tAc "SHOW server_version_num;")
    if [ "${version:-0}" -lt 160000 ]; then
        # GRANT ... WITH INHERIT FALSE (what keeps the role out of every other
        # project's database) does not exist before PostgreSQL 16. Rather than
        # leave those installs unable to start a project, keep the previous
        # behaviour (Realtime as supabase_admin) and say so.
        echo "WARNING: PostgreSQL server_version_num=$version (< 160000): Realtime for '$name' will run as the supabase_admin superuser."
        echo "         Upgrade to PostgreSQL 16+ for a least-privilege Realtime role."
        docker exec -i "$db_ctr" psql -U supabase_admin -d "$db" -v ON_ERROR_STOP=1 <<'EOSQL'
CREATE SCHEMA IF NOT EXISTS _realtime;
CREATE SCHEMA IF NOT EXISTS realtime;
EOSQL
        local super_password
        super_password=$(grep "^POSTGRES_PASSWORD=" "$env_file" | cut -d= -f2-)
        _set_env_var "$env_file" PROJECT_REALTIME_DB_USER supabase_admin
        _set_env_var "$env_file" PROJECT_REALTIME_DB_PASSWORD "$super_password"
        _set_env_var "$env_file" PROJECT_REALTIME_SLOT_SUFFIX "$slot_suffix"
        return 0
    fi

    # Quoted heredoc: no shell expansion, so no escaping of $ or backticks.
    # Values arrive as psql variables. supabase_admin, not postgres:
    # supabase_realtime_admin is a supautils-reserved role that only a
    # superuser may create or grant.
    docker exec -i "$db_ctr" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
        -v db="$db" -v rt="$rt_user" -v pw="$rt_password" <<'EOSQL'
SELECT format(
  CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'rt')
       THEN 'ALTER ROLE %1$I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS REPLICATION INHERIT PASSWORD %2$L'
       ELSE 'CREATE ROLE %1$I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS REPLICATION INHERIT PASSWORD %2$L'
  END, :'rt', :'pw') \gexec
-- Realtime does set_config('role', <jwt role>) for RLS checks, so it needs SET
-- on these. INHERIT FALSE is essential: anon/authenticated/service_role hold
-- CONNECT on every project database, and inheriting them would open all of them.
SELECT format('GRANT anon, authenticated, service_role TO %I WITH INHERIT FALSE, SET TRUE', :'rt') \gexec
-- realtime.list_changes() is declared SET log_min_messages.
SELECT format('GRANT SET ON PARAMETER log_min_messages TO %I', :'rt') \gexec
SELECT 'CREATE ROLE supabase_realtime_admin WITH NOINHERIT NOLOGIN NOREPLICATION'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_realtime_admin') \gexec
GRANT supabase_realtime_admin TO postgres;
SELECT format('GRANT supabase_realtime_admin TO %I', :'rt') \gexec
-- Mark both project roles for the login trigger installed by
-- _block_project_roles_in_main_dbs. The groups hold no privileges. The login
-- role is normally marked at creation; this repairs older projects.
SELECT 'CREATE ROLE sb2_project_realtime NOLOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sb2_project_realtime') \gexec
SELECT format('GRANT sb2_project_realtime TO %I WITH INHERIT FALSE, SET FALSE', :'rt') \gexec
SELECT 'CREATE ROLE sb2_project_login NOLOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sb2_project_login') \gexec
SELECT format('GRANT sb2_project_login TO %I', :'db')
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db') \gexec

\c :db
-- CONNECT to log in; CREATE because PG15+ needs it for CREATE PUBLICATION.
SELECT format('GRANT CONNECT, CREATE ON DATABASE %I TO %I', :'db', :'rt') \gexec
SELECT format('CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION %I', :'rt') \gexec
SELECT format('ALTER SCHEMA _realtime OWNER TO %I', :'rt') \gexec
-- Self-hosted Realtime does not create the tenant schema itself.
SELECT format('CREATE SCHEMA IF NOT EXISTS realtime AUTHORIZATION %I', :'rt') \gexec
SELECT format('ALTER SCHEMA realtime OWNER TO %I', :'rt') \gexec
GRANT USAGE, CREATE ON SCHEMA realtime TO supabase_realtime_admin;
-- Subscribing to Postgres Changes runs realtime.subscription_check_filters(),
-- which casts every information_schema.columns row to regclass before the
-- view's privilege filter is applied. Without USAGE on a schema that holds any
-- table (auth, storage, or one the user creates later) that cast fails with
-- "permission denied for schema" and no subscription works. Superusers skip
-- the check, which is why this only shows up with a least-privilege role.
-- USAGE alone grants no access to the objects inside.
CREATE OR REPLACE FUNCTION extensions.sb2_realtime_grant_usage()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog
AS $fn$
DECLARE
  rt text := current_database() || '_rt';
  s record;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace
    WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
      AND NOT has_schema_privilege(rt, oid, 'USAGE')
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', s.nspname, rt);
  END LOOP;
END;
$fn$;
CREATE OR REPLACE FUNCTION extensions.sb2_realtime_schema_usage()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog
AS $fn$
BEGIN
  PERFORM extensions.sb2_realtime_grant_usage();
END;
$fn$;
-- Schemas created later: CREATE SCHEMA, and CREATE EXTENSION for extensions
-- that bring their own (cron, pgmq, ...).
DROP EVENT TRIGGER IF EXISTS sb2_realtime_schema_usage;
CREATE EVENT TRIGGER sb2_realtime_schema_usage ON ddl_command_end
  WHEN TAG IN ('CREATE SCHEMA', 'CREATE EXTENSION')
  EXECUTE FUNCTION extensions.sb2_realtime_schema_usage();
-- Schemas that exist now.
SELECT extensions.sb2_realtime_grant_usage();
-- Tenant migration 20240401105812 needs superuser for its role work, which is
-- done above; mark it applied (the tables it re-owns are dropped by a later one).
CREATE TABLE IF NOT EXISTS realtime.schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0));
SELECT format('ALTER TABLE realtime.schema_migrations OWNER TO %I', :'rt') \gexec
INSERT INTO realtime.schema_migrations VALUES (20240401105812, now()) ON CONFLICT DO NOTHING;

-- Existing projects: hand Realtime's objects (created while it ran as
-- supabase_admin) to the new role. Objects Realtime itself gave to
-- supabase_realtime_admin (realtime.messages, realtime.topic()) stay as they are.
SELECT set_config('sb2.rt', :'rt', false);
DO $$
DECLARE
  rt text := current_setting('sb2.rt');
  r record;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS obj, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('_realtime', 'realtime')
      AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
      AND c.relowner <> 'supabase_realtime_admin'::regrole
      AND c.relowner <> rt::regrole
      -- identity/serial sequences follow their table
      AND NOT (c.relkind = 'S' AND EXISTS (
        SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a', 'i')))
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO %I',
      CASE r.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW'
                     WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
      r.obj, rt);
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure AS obj
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('_realtime', 'realtime')
      AND p.proowner <> 'supabase_realtime_admin'::regrole
      AND p.proowner <> rt::regrole
  LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO %I', r.obj, rt);
  END LOOP;

  -- enum / composite / domain types (array types follow their element type)
  FOR r IN
    SELECT t.oid::regtype AS obj, t.typtype
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname IN ('_realtime', 'realtime')
      AND t.typelem = 0
      AND (t.typrelid = 0 OR (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')
      AND t.typowner <> 'supabase_realtime_admin'::regrole
      AND t.typowner <> rt::regrole
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO %I',
      CASE r.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, r.obj, rt);
  END LOOP;

  -- Realtime drops and recreates this publication when it looks stale.
  FOR r IN SELECT pubname FROM pg_publication WHERE pubname LIKE 'supabase_realtime_messages%' LOOP
    EXECUTE format('ALTER PUBLICATION %I OWNER TO %I', r.pubname, rt);
  END LOOP;

  -- Older sb2 versions ignored the tenant name and always seeded 'realtime-dev',
  -- which nothing reads. Realtime now seeds realtime-<project> itself; drop the
  -- stale one (its extensions rows cascade).
  IF to_regclass('_realtime.tenants') IS NOT NULL THEN
    DELETE FROM _realtime.tenants WHERE external_id = 'realtime-dev';
  END IF;
END $$;
EOSQL

    if [ "$version" -ge 170000 ]; then
        _block_project_roles_in_main_dbs "$db_ctr"
    else
        echo "WARNING: PostgreSQL server_version_num=$version (< 170000): no login event triggers, so the"
        echo "         database roles of '$name' can still log in to the main 'postgres' database. Upgrade to PostgreSQL 17+."
    fi

    _set_env_var "$env_file" PROJECT_REALTIME_DB_USER "$rt_user"
    _set_env_var "$env_file" PROJECT_REALTIME_DB_PASSWORD "$rt_password"
    _set_env_var "$env_file" PROJECT_REALTIME_SLOT_SUFFIX "$slot_suffix"
}

# Keep project database roles out of the main stack's databases.
#
# PUBLIC holds CONNECT on `postgres` and `_supabase`. There, a project's login
# role (the DATABASE_URL user) could read the main JWT secret from the
# app.settings.jwt_secret GUC and forge main-stack service_role tokens, and a
# <db>_rt role could SET ROLE service_role (it may, for RLS checks in its own
# database) or open a logical replication slot on the main data. A login
# event trigger (PostgreSQL 17+) refuses members of sb2_project_login and
# sb2_project_realtime, including replication connections. Revoking CONNECT
# from PUBLIC instead would cut off every role the main stack and its users
# rely on.
#
# A login trigger that errors locks everyone out (recovery: start Postgres
# with -c event_triggers=off), so the membership check cannot fail: it joins
# on names and swallows errors. template1 is left alone, or every database
# created from it would refuse its own project's roles.
_block_project_roles_in_main_dbs() {
    local db_ctr="$1" main_db
    for main_db in postgres _supabase; do
        if ! docker exec "$db_ctr" psql -U supabase_admin -d postgres -tAc \
                "SELECT 1 FROM pg_database WHERE datname = '$main_db'" | grep -q 1; then
            continue
        fi
        docker exec -i "$db_ctr" psql -U supabase_admin -d "$main_db" -q -v ON_ERROR_STOP=1 <<'EOSQL'
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE OR REPLACE FUNCTION extensions.sb2_block_project_roles()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SET search_path = pg_catalog
AS $fn$
DECLARE
  blocked boolean := false;
BEGIN
  BEGIN
    SELECT EXISTS (
      SELECT 1 FROM pg_auth_members m
      JOIN pg_roles g ON g.oid = m.roleid
      JOIN pg_roles u ON u.oid = m.member
      WHERE g.rolname IN ('sb2_project_login', 'sb2_project_realtime')
        AND u.rolname = session_user)
    INTO blocked;
  EXCEPTION WHEN OTHERS THEN
    blocked := false;
  END;
  IF blocked THEN
    RAISE EXCEPTION 'role "%" belongs to a SuperBase² project and may only connect to its project database', session_user;
  END IF;
END;
$fn$;
SELECT 'CREATE EVENT TRIGGER sb2_block_project_roles ON login EXECUTE FUNCTION extensions.sb2_block_project_roles()'
 WHERE NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'sb2_block_project_roles') \gexec
-- Superseded by sb2_block_project_roles, which also covers the login roles.
DROP EVENT TRIGGER IF EXISTS sb2_block_project_realtime;
DROP FUNCTION IF EXISTS extensions.sb2_block_project_realtime();
EOSQL
    done
}

_init_project_db() {
    local name="$1"
    local db_name="$2"
    local jwt_secret="$3"
    local jwt_exp="$4"
    local db_password="$5"

    _ensure_project_db_role "$db_name" "$db_password"

    # Create the database — check for "already exists" explicitly
    local db_ctr
    db_ctr=$(db_container)
    if ! docker exec "$db_ctr" psql -U supabase_admin -c "CREATE DATABASE \"$db_name\" OWNER \"$db_name\";" 2>&1; then
        if docker exec "$db_ctr" psql -U supabase_admin -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name';" | grep -q 1; then
            echo "Database '$db_name' already exists — taking ownership."
            docker exec "$db_ctr" psql -U supabase_admin -c "ALTER DATABASE \"$db_name\" OWNER TO \"$db_name\";"
        else
            echo "Error: Failed to create database '$db_name'."
            exit 1
        fi
    fi

    # Escape single quotes in jwt_secret for safe SQL interpolation
    local safe_jwt_secret="${jwt_secret//\'/\'\'}"

    # Validate jwt_exp is numeric
    if ! [[ "$jwt_exp" =~ ^[0-9]+$ ]]; then
        echo "Error: JWT expiry must be numeric, got '$jwt_exp'"
        exit 1
    fi

    # Apply the same role passwords and extensions as the default database.
    # The roles already exist globally, we just need to set up the schemas.
    # Uses an unquoted heredoc so $db_name, $safe_jwt_secret, and $jwt_exp
    # are expanded by the shell. The only literal $ needed is in \$user
    # (the Postgres search_path variable), which is escaped with backslash.
    docker exec -i "$db_ctr" psql -U supabase_admin -v ON_ERROR_STOP=1 -d "$db_name" <<EOSQL
-- Set JWT config
ALTER DATABASE "$db_name" SET "app.settings.jwt_secret" TO '$safe_jwt_secret';
ALTER DATABASE "$db_name" SET "app.settings.jwt_exp" TO '$jwt_exp';

-- The _realtime and realtime schemas are created on every start by
-- _ensure_realtime_db(), owned by Realtime's own role.

-- Create storage schema (if needed by storage service)
CREATE SCHEMA IF NOT EXISTS storage;
ALTER SCHEMA storage OWNER TO supabase_storage_admin;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
ALTER ROLE supabase_storage_admin SET search_path TO 'storage', 'public', 'extensions', 'auth';

-- Create auth schema
CREATE SCHEMA IF NOT EXISTS auth;
ALTER SCHEMA auth OWNER TO supabase_auth_admin;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
ALTER ROLE supabase_auth_admin SET search_path TO 'auth', 'public', 'extensions';

-- Create graphql_public schema (required by PostgREST's default db-schemas config)
CREATE SCHEMA IF NOT EXISTS graphql_public;
GRANT USAGE ON SCHEMA graphql_public TO anon, authenticated, service_role;

-- public is owned by pg_database_owner, which resolves to the project role now
-- that it owns the database. Reassert it: a database created by an earlier sb2
-- version can have public owned by supabase_admin directly, and then database
-- ownership alone does not grant CREATE.
ALTER SCHEMA public OWNER TO pg_database_owner;

-- Grant schema usage
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

-- The grants above only cover objects created by supabase_admin (the role
-- running this). Tables the user creates over DATABASE_URL, or that pg-meta
-- creates for the table editor, are owned by the project role — without these,
-- PostgREST cannot see any of them.
ALTER DEFAULT PRIVILEGES FOR ROLE "$db_name" IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE "$db_name" IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE "$db_name" IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

-- Read access to the service-managed schemas, so the SQL editor and pg-meta
-- (both connect as the project role) can browse auth.users and storage.objects.
-- Scoped to this database rather than granted via pg_read_all_data, which would
-- also expose the main postgres database. The tables do not exist yet — GoTrue
-- and Storage create them on first run — so the default-privilege grants are
-- what actually apply.
GRANT USAGE ON SCHEMA auth, storage TO "$db_name";
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT SELECT ON TABLES TO "$db_name";
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT SELECT ON TABLES TO "$db_name";

-- Confine this project's credential to this project's database. PUBLIC holds
-- CONNECT by default, which would make the per-project password meaningless.
REVOKE CONNECT ON DATABASE "$db_name" FROM PUBLIC;

-- Service roles need CONNECT privilege on non-default databases.
-- Without this, PostgREST (authenticator) and Storage (supabase_storage_admin) fail to connect.
GRANT ALL ON DATABASE "$db_name" TO supabase_storage_admin;
GRANT ALL ON DATABASE "$db_name" TO supabase_auth_admin;
GRANT ALL ON DATABASE "$db_name" TO postgres;
GRANT CONNECT ON DATABASE "$db_name" TO authenticator;
GRANT CONNECT ON DATABASE "$db_name" TO anon;
GRANT CONNECT ON DATABASE "$db_name" TO authenticated;
GRANT CONNECT ON DATABASE "$db_name" TO service_role;

-- Create extensions schema and extensions
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgjwt WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA extensions;

-- Add extensions schema to the default search_path so functions like
-- uuid_generate_v4() work without schema-qualifying them.
ALTER DATABASE "$db_name" SET search_path TO "\$user", public, extensions;

-- Grant usage so all roles can access extension functions. The project role is
-- not a member of anon/authenticated/service_role, so it needs its own grant —
-- without it uuid_generate_v4() and friends are unresolvable over DATABASE_URL
-- even though they are on the search_path.
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA extensions TO "$db_name";
GRANT USAGE ON SCHEMA graphql_public TO "$db_name";

-- PostgREST schema-cache invalidation. The supabase/postgres image installs
-- these into the "postgres" database at cluster init only; a project database
-- created later inherits template1 and gets none of them, so PostgREST never
-- reloads its schema cache until its container restarts. Definitions copied
-- verbatim from the image's init migration.
CREATE OR REPLACE FUNCTION extensions.pgrst_ddl_watch()
 RETURNS event_trigger
 LANGUAGE plpgsql
AS \$\$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands()
  LOOP
    IF cmd.command_tag IN (
      'CREATE SCHEMA', 'ALTER SCHEMA'
    , 'CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE'
    , 'CREATE FOREIGN TABLE', 'ALTER FOREIGN TABLE'
    , 'CREATE VIEW', 'ALTER VIEW'
    , 'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW'
    , 'CREATE FUNCTION', 'ALTER FUNCTION'
    , 'CREATE TRIGGER'
    , 'CREATE TYPE', 'ALTER TYPE'
    , 'CREATE RULE'
    , 'COMMENT'
    )
    -- don't notify in case of CREATE TEMP table or other objects created on pg_temp
    AND cmd.schema_name is distinct from 'pg_temp'
    THEN
      NOTIFY pgrst, 'reload schema';
    END IF;
  END LOOP;
END; \$\$;

CREATE OR REPLACE FUNCTION extensions.pgrst_drop_watch()
 RETURNS event_trigger
 LANGUAGE plpgsql
AS \$\$
DECLARE
  obj record;
BEGIN
  FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects()
  LOOP
    IF obj.object_type IN (
      'schema'
    , 'table'
    , 'foreign table'
    , 'view'
    , 'materialized view'
    , 'function'
    , 'trigger'
    , 'type'
    , 'rule'
    )
    AND obj.is_temporary IS false -- no pg_temp objects
    THEN
      NOTIFY pgrst, 'reload schema';
    END IF;
  END LOOP;
END; \$\$;

-- CREATE EVENT TRIGGER has no IF NOT EXISTS, and this function is re-run on
-- existing projects, so drop first.
DROP EVENT TRIGGER IF EXISTS pgrst_ddl_watch;
DROP EVENT TRIGGER IF EXISTS pgrst_drop_watch;
CREATE EVENT TRIGGER pgrst_ddl_watch ON ddl_command_end EXECUTE PROCEDURE extensions.pgrst_ddl_watch();
CREATE EVENT TRIGGER pgrst_drop_watch ON sql_drop EXECUTE PROCEDURE extensions.pgrst_drop_watch();
EOSQL

    echo "Database '$db_name' initialized."
}

cmd_destroy() {
    local name="$1"
    local assume_yes="${2:-}"

    if ! project_exists "$name"; then
        if [ "$assume_yes" = "--yes" ]; then
            # Studio deletes projects that were created but never started; they
            # have no disk state or containers, and Studio drops the database.
            echo "Project '$name' has no disk state; nothing to remove."
            return 0
        fi
        echo "Error: Project '$name' does not exist."
        exit 1
    fi

    if [ "$assume_yes" != "--yes" ]; then
        echo "WARNING: This will destroy project '$name' including:"
        echo "  - All project containers"
        echo "  - The project database"
        echo "  - All stored files"
        echo ""
        read -r -p "Type the project name to confirm: " confirm
        if [ "$confirm" != "$name" ]; then
            echo "Aborted."
            exit 1
        fi
    fi

    local project_dir="$PROJECTS_DIR/$name"

    # Load project env. It's compose dotenv, not shell: values like SMTP_PASS
    # may hold spaces or $(), so parse instead of sourcing.
    load_dotenv "$project_dir/.env"

    # Stop containers
    echo "Stopping project containers..."
    if ! docker compose -f "$project_dir/docker-compose.yml" \
        --env-file "$project_dir/.env" \
        --project-name "supabase-${name}" \
        down -v 2>&1; then
        echo "Warning: Some containers may not have stopped cleanly."
    fi

    # Drop the database, then the project's login role. supabase_admin, not
    # postgres: postgres does not own the database and cannot drop it.
    echo "Dropping database: $PROJECT_DB"
    if ! docker exec "$(db_container)" psql -U supabase_admin -c "DROP DATABASE IF EXISTS \"$PROJECT_DB\";" 2>&1; then
        echo "Warning: Failed to drop database '$PROJECT_DB'. It may need manual cleanup."
    fi
    # Roles are cluster-global, so the login role outlives the database.
    if ! docker exec "$(db_container)" psql -U supabase_admin -c "DROP ROLE IF EXISTS \"$PROJECT_DB\";" 2>&1; then
        echo "Warning: Failed to drop role '$PROJECT_DB'. It may need manual cleanup."
    fi
    # Realtime's role. The REVOKE is required: a role holding a parameter ACL
    # cannot be dropped until it is revoked (pg_shdepend dependency).
    # DROP DATABASE already removed its inactive replication slots.
    local rt_role="${PROJECT_DB}_rt"
    if docker exec "$(db_container)" psql -U supabase_admin -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='${rt_role}'" | grep -q 1; then
        if ! docker exec "$(db_container)" psql -U supabase_admin -v ON_ERROR_STOP=1 \
            -c "REVOKE SET ON PARAMETER log_min_messages FROM \"${rt_role}\";" \
            -c "DROP ROLE \"${rt_role}\";" 2>&1; then
            echo "Warning: Failed to drop role '${rt_role}'. It may need manual cleanup."
        fi
    fi

    _remove_functions_network "$name"

    # Remove project directory
    rm -rf "$project_dir"

    # Sync manifest for Studio and rebuild Kong
    sync_manifest
    cmd_rebuild_kong

    echo "Project '$name' destroyed."
}

cmd_list() {
    local projects
    projects=$(list_projects)

    if [ -z "$projects" ]; then
        echo "No projects found."
        return
    fi

    printf "%-20s %-22s %-20s %s\n" "NAME" "REF" "DATABASE" "STATUS"
    printf "%-20s %-22s %-20s %s\n" "----" "---" "--------" "------"

    for name in $projects; do
        local project_dir="$PROJECTS_DIR/$name"
        if [ -f "$project_dir/.env" ]; then
            local ref db status
            ref=$(grep "^PROJECT_REF=" "$project_dir/.env" | cut -d= -f2-)
            db=$(grep "^PROJECT_DB=" "$project_dir/.env" | cut -d= -f2-)

            # Check if any containers are running
            local running
            running=$(docker ps --filter "name=supabase-${name}-" --format "{{.Names}}" 2>/dev/null | wc -l)
            if [ "$running" -gt 0 ]; then
                status="running ($running containers)"
            else
                status="stopped"
            fi

            printf "%-20s %-22s %-20s %s\n" "$name" "$ref" "$db" "$status"
        fi
    done
}

# Run "$1" once per remaining argument (a project name), each in its own
# subshell, so one broken project can't stop the others. Projects that failed
# are left in FAILED_PROJECTS. This must not be called from an if/&&/|| context:
# bash then ignores `set -e` for everything underneath, even in a subshell that
# turns it back on, and a failing step would be skipped instead of stopping
# that project's run.
FAILED_PROJECTS=()
_for_each_project() {
    local fn="$1" proj rc
    shift
    FAILED_PROJECTS=()
    for proj in "$@"; do
        set +e
        ( set -e; "$fn" "$proj" )
        rc=$?
        set -e
        if [ "$rc" -ne 0 ]; then
            echo "Error: project '$proj' failed (exit $rc); continuing with the others." >&2
            FAILED_PROJECTS+=("$proj")
        fi
    done
}

# Prepare disk state for every given project, rebuild Kong once, then start
# them. A project that fails is reported and skipped; the run exits 1 at the
# end if any did.
_start_projects() {
    local failed=() ready=() proj
    _for_each_project _ensure_disk_state "$@"
    failed=("${FAILED_PROJECTS[@]}")
    for proj in "$@"; do
        [[ " ${failed[*]} " == *" $proj "* ]] || ready+=("$proj")
    done

    cmd_rebuild_kong
    _for_each_project _start_project "${ready[@]}"
    failed+=("${FAILED_PROJECTS[@]}")

    if [ ${#failed[@]} -gt 0 ]; then
        echo "Error: failed to start project(s): ${failed[*]}" >&2
        exit 1
    fi
}

cmd_up() {
    local name="${1:-}"

    export_main_stack_images || exit 1

    if [ -z "$name" ]; then
        local all=()
        read -r -a all <<< "$(list_projects | tr '\n' ' ')"
        _start_projects "${all[@]}"
        return
    fi

    _ensure_disk_state "$name"
    cmd_rebuild_kong
    _start_project "$name"
}

# Stop and start a project. `up` refuses to start without the main stack's
# images, so check them before stopping anything: a restart during a main-stack
# redeploy must leave the project running, not stopped.
cmd_restart() {
    local name="$1"
    if ! project_exists "$name"; then
        echo "Error: Project '$name' does not exist."
        exit 1
    fi
    export_main_stack_images || exit 1
    cmd_down "$name"
    cmd_up "$name"
}

# Bring per-project containers back in line with the main stack after it was
# (re)deployed: the agent runs this on startup. Per-project stacks are separate
# compose projects started over the Docker socket, so a Coolify redeploy never
# touches them — without this they keep running the previous deploy's images
# and environment until someone restarts each project by hand.
#
# Only projects that currently have containers (running or exited) are
# recreated. `down` removes a project's containers, so a project the user
# stopped stays stopped. Names limit the run to those projects (the agent
# passes the drifted ones while a broken project's retries back off).
cmd_reconcile() {
    local started=() proj
    for proj in $(list_projects); do
        if [ $# -gt 0 ] && [[ " $* " != *" $proj "* ]]; then
            continue
        fi
        if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=supabase-${proj}")" ]; then
            started+=("$proj")
        fi
    done

    if [ ${#started[@]} -eq 0 ]; then
        echo "No started projects to reconcile."
        return 0
    fi

    export_main_stack_images || exit 1
    _start_projects "${started[@]}"
}

# The agent starts before the main-stack services reconcile copies images
# from. Wait for them, and for Postgres to accept connections (every project
# start runs SQL), before taking the state lock, so a slow main-stack start
# doesn't block other commands (e.g. kong-sb2-init's rebuild-kong).
#
# The image probe runs in a subshell: export_main_stack_images exports what it
# finds even when it fails, and an export would count as an explicit override
# on the next attempt, pinning an image the redeploy is about to replace.
_wait_for_main_stack() {
    local waited=0 timeout="${SB2_RECONCILE_WAIT:-600}"
    until ( export_main_stack_images ) 2>/dev/null \
            && docker exec "$(db_container)" pg_isready -U postgres -h localhost -q 2>/dev/null; do
        if [ "$waited" -ge "$timeout" ]; then
            ( export_main_stack_images ) || true
            echo "Error: main stack not ready after ${timeout}s; per-project containers were not reconciled." >&2
            exit 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

# Ensure disk state exists for a project (generate from manifest if needed).
_ensure_disk_state() {
    local name="$1"
    local project_dir="$PROJECTS_DIR/$name"

    # If project exists in manifest but has no disk directory, generate disk state
    if [ ! -d "$project_dir" ] && [ -f "$PROJECTS_MANIFEST" ]; then
        local manifest_entry
        manifest_entry=$(jq -r --arg name "$name" '.projects[] | select(.name == $name)' "$PROJECTS_MANIFEST" 2>/dev/null || true)

        if [ -n "$manifest_entry" ]; then
            echo "Project '$name' found in manifest but missing disk state. Generating files..."
            _generate_disk_state_from_manifest "$name" "$manifest_entry"
        else
            echo "Error: Project '$name' does not exist."
            exit 1
        fi
    elif [ ! -d "$project_dir" ]; then
        echo "Error: Project '$name' does not exist."
        exit 1
    fi

    # Stack-wide values copied into the project .env go stale when the stack
    # changes them (a new domain set in Coolify, a Coolify UUID-prefixed
    # network unknown when the project was created). Compose prefers the
    # running environment anyway; this keeps the file, and what client-config
    # prints from it, in line.
    if [ -f "$project_dir/.env" ]; then
        local key current
        for key in SUPABASE_NETWORK_NAME SUPABASE_PUBLIC_URL; do
            [ -n "${!key:-}" ] || continue
            current=$(grep "^$key=" "$project_dir/.env" | cut -d= -f2- || true)
            if [ "$current" != "${!key}" ]; then
                _set_env_var "$project_dir/.env" "$key" "${!key}"
                echo "Updated $key: $current -> ${!key}"
            fi
        done
    fi

    # Always regenerate the compose file from template before starting.
    # This ensures service toggles (disabled_services in manifest) take effect
    # without needing a separate "regenerate" step — just `down` then `up`.
    if [ -f "$project_dir/.env" ] && [ -f "$TEMPLATES_DIR/docker-compose.project.yml.tpl" ]; then
        local ref db
        ref=$(grep "^PROJECT_REF=" "$project_dir/.env" | cut -d= -f2-)
        db=$(grep "^PROJECT_DB=" "$project_dir/.env" | cut -d= -f2-)
        sed \
            -e "s|{{PROJECT_NAME}}|$name|g" \
            -e "s|{{PROJECT_REF}}|$ref|g" \
            -e "s|{{PROJECT_DB}}|$db|g" \
            "$TEMPLATES_DIR/docker-compose.project.yml.tpl" \
            > "$project_dir/docker-compose.yml"
        filter_disabled_services "$project_dir/docker-compose.yml" "$name"
    fi
}

# Start containers for a single project (assumes disk state + Kong are ready).
_start_project() {
    local name="$1"
    local project_dir="$PROJECTS_DIR/$name"

    echo "Starting project: $name"

    # Realtime's database role and schemas must exist before its container
    # starts, and its credentials land in the .env compose reads below.
    _ensure_realtime_db "$name"

    # The functions network is external to the compose file; it must exist
    # before `up`, with Kong and Postgres on it.
    _connect_functions_network "$name"

    # --remove-orphans: a service disabled since the last start (and its
    # companions, e.g. imgproxy for storage) is gone from the regenerated
    # compose file, so stop it instead of leaving it running.
    docker compose -f "$project_dir/docker-compose.yml" \
        --env-file "$project_dir/.env" \
        --project-name "supabase-${name}" \
        up -d --remove-orphans

    echo "Project '$name' started."
}

_generate_disk_state_from_manifest() {
    local name="$1"
    local manifest_json="$2"
    local project_dir="$PROJECTS_DIR/$name"

    # Extract fields from manifest JSON using jq
    local ref db jwt_secret anon_key service_role_key created_at
    ref=$(echo "$manifest_json" | jq -r '.ref')
    db=$(echo "$manifest_json" | jq -r '.db')
    jwt_secret=$(echo "$manifest_json" | jq -r '.jwt_secret')
    anon_key=$(echo "$manifest_json" | jq -r '.anon_key')
    service_role_key=$(echo "$manifest_json" | jq -r '.service_role_key')
    created_at=$(echo "$manifest_json" | jq -r '.created_at // ""')

    ensure_projects_dir
    mkdir -p "$project_dir"
    # Storage + functions volumes are named volumes managed by the generated
    # compose file — see _generate_disk_state_from_manifest's template output.

    # Read secondary secrets from manifest if available, otherwise generate new ones.
    # API-created projects store these in the manifest; losing them breaks running services.
    local secret_key_base db_enc_key pg_meta_crypto_key s3_access_key_id s3_access_key_secret
    secret_key_base=$(echo "$manifest_json" | jq -r '.secret_key_base // empty')
    db_enc_key=$(echo "$manifest_json" | jq -r '.db_enc_key // empty')
    pg_meta_crypto_key=$(echo "$manifest_json" | jq -r '.pg_meta_crypto_key // empty')
    s3_access_key_id=$(echo "$manifest_json" | jq -r '.s3_access_key_id // empty')
    s3_access_key_secret=$(echo "$manifest_json" | jq -r '.s3_access_key_secret // empty')
    [ -z "$secret_key_base" ] && secret_key_base=$(gen_base64 48)
    # AES-128-ECB key — 16 bytes, i.e. 16 hex chars (gen_hex 8). Old manifests with
     # 32-char keys would crash Realtime ("Bad key size"); regenerate them.
     if [ -z "$db_enc_key" ] || [ "${#db_enc_key}" -ne 16 ]; then db_enc_key=$(gen_hex 8); fi
    [ -z "$pg_meta_crypto_key" ] && pg_meta_crypto_key=$(gen_base64 24)
    [ -z "$s3_access_key_id" ] && s3_access_key_id=$(gen_hex 16)
    [ -z "$s3_access_key_secret" ] && s3_access_key_secret=$(gen_hex 32)

    # The project's Postgres login role password. Unlike the secrets above, this
    # one also lives in the cluster — if the manifest has none (project predates
    # per-project roles, or was created by an older Studio), generate one and
    # apply it, otherwise the .env we write would not authenticate.
    local db_password
    db_password=$(echo "$manifest_json" | jq -r '.db_password // empty')
    if [ -z "$db_password" ]; then
        db_password=$(gen_hex 24)
        _ensure_project_db_role "$db" "$db_password"
    fi

    # Write .env, restricted before any secret is written (see cmd_create).
    : > "$project_dir/.env"
    chmod 600 "$project_dir/.env"
    cat > "$project_dir/.env" <<EOF
# Project: $name
# Generated: ${created_at:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}

PROJECT_NAME=$name
PROJECT_REF=$ref
PROJECT_DB=$db

# JWT
PROJECT_JWT_SECRET=$jwt_secret
PROJECT_ANON_KEY=$anon_key
PROJECT_SERVICE_ROLE_KEY=$service_role_key

# Secrets
PROJECT_SECRET_KEY_BASE=$secret_key_base
PROJECT_DB_ENC_KEY=$db_enc_key
PROJECT_PG_META_CRYPTO_KEY=$pg_meta_crypto_key
PROJECT_S3_ACCESS_KEY_ID=$s3_access_key_id
PROJECT_S3_ACCESS_KEY_SECRET=$s3_access_key_secret
PROJECT_DB_PASSWORD=$db_password

# Shared infra (from main .env)
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_HOST=db
POSTGRES_PORT=${POSTGRES_PORT:-5432}
JWT_EXPIRY=${JWT_EXPIRY:-3600}

# URLs
SUPABASE_PUBLIC_URL=${SUPABASE_PUBLIC_URL:-http://localhost:8000}
SITE_URL=${SITE_URL:-http://localhost:3000}
ADDITIONAL_REDIRECT_URLS=${ADDITIONAL_REDIRECT_URLS:-}

# Auth settings
DISABLE_SIGNUP=${DISABLE_SIGNUP:-false}
ENABLE_EMAIL_SIGNUP=${ENABLE_EMAIL_SIGNUP:-true}
ENABLE_EMAIL_AUTOCONFIRM=${ENABLE_EMAIL_AUTOCONFIRM:-false}
ENABLE_PHONE_SIGNUP=${ENABLE_PHONE_SIGNUP:-true}
ENABLE_PHONE_AUTOCONFIRM=${ENABLE_PHONE_AUTOCONFIRM:-true}
ENABLE_ANONYMOUS_USERS=${ENABLE_ANONYMOUS_USERS:-false}
SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL:-admin@example.com}
SMTP_HOST=${SMTP_HOST:-supabase-mail}
SMTP_PORT=${SMTP_PORT:-2500}
SMTP_USER=${SMTP_USER:-fake_mail_user}
SMTP_PASS=${SMTP_PASS:-fake_mail_password}
SMTP_SENDER_NAME=${SMTP_SENDER_NAME:-fake_sender}

# Storage
GLOBAL_S3_BUCKET=${GLOBAL_S3_BUCKET:-stub}
REGION=${REGION:-local}
STORAGE_TENANT_ID=$ref
IMGPROXY_ENABLE_WEBP_DETECTION=${IMGPROXY_ENABLE_WEBP_DETECTION:-true}

# Functions
FUNCTIONS_VERIFY_JWT=${FUNCTIONS_VERIFY_JWT:-true}

# PostgREST
PGRST_DB_SCHEMAS=${PGRST_DB_SCHEMAS:-public,storage,graphql_public}
PGRST_DB_MAX_ROWS=${PGRST_DB_MAX_ROWS:-1000}
PGRST_DB_EXTRA_SEARCH_PATH=${PGRST_DB_EXTRA_SEARCH_PATH:-public,extensions}

# Network
SUPABASE_NETWORK_NAME=${SUPABASE_NETWORK_NAME:-supabase_default}
EOF

    # Generate docker-compose from template
    sed \
        -e "s|{{PROJECT_NAME}}|$name|g" \
        -e "s|{{PROJECT_REF}}|$ref|g" \
        -e "s|{{PROJECT_DB}}|$db|g" \
        "$TEMPLATES_DIR/docker-compose.project.yml.tpl" \
        > "$project_dir/docker-compose.yml"

    # Remove disabled service blocks from the compose file
    filter_disabled_services "$project_dir/docker-compose.yml" "$name"

    echo "Disk state generated for project '$name'."
}

cmd_down() {
    local name="${1:-}"

    if [ -z "$name" ]; then
        for proj in $(list_projects); do
            cmd_down "$proj"
        done
        return
    fi

    if ! project_exists "$name"; then
        echo "Error: Project '$name' does not exist."
        exit 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    echo "Stopping project: $name"
    docker compose -f "$project_dir/docker-compose.yml" \
        --env-file "$project_dir/.env" \
        --project-name "supabase-${name}" \
        down

    echo "Project '$name' stopped."
}

cmd_status() {
    local name="${1:-}"

    if [ -z "$name" ]; then
        for proj in $(list_projects); do
            echo "=== $proj ==="
            cmd_status "$proj"
            echo ""
        done
        return
    fi

    if ! project_exists "$name"; then
        echo "Error: Project '$name' does not exist."
        exit 1
    fi

    docker ps --filter "name=supabase-${name}-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    # Quick JWT secret drift check — warn if container secrets don't match .env
    local project_dir="$PROJECTS_DIR/$name"
    if [ -f "$project_dir/.env" ]; then
        local expected_jwt
        expected_jwt=$(grep "^PROJECT_JWT_SECRET=" "$project_dir/.env" | cut -d= -f2-)
        if [ -n "$expected_jwt" ]; then
            local rest_container="supabase-${name}-rest"
            local actual_jwt
            actual_jwt=$(docker inspect "$rest_container" --format "{{range .Config.Env}}{{println .}}{{end}}" 2>/dev/null \
                | grep "^PGRST_JWT_SECRET=" | cut -d= -f2-)
            if [ -n "$actual_jwt" ] && [ "$actual_jwt" != "$expected_jwt" ]; then
                echo ""
                echo "WARNING: JWT secret mismatch detected!"
                echo "  Container $rest_container has a different JWT secret than the project .env."
                echo "  Run './superbase2.sh verify $name' for details, then './superbase2.sh up $name' to fix."
            fi
        fi
    fi
}

cmd_client_config() {
    local name="$1"

    if ! project_exists "$name"; then
        echo "Error: Project '$name' does not exist."
        exit 1
    fi

    local project_dir="$PROJECTS_DIR/$name"
    # The stack's current public URL wins over the copy in the project .env,
    # which is only refreshed when the project starts.
    local public_url="${SUPABASE_PUBLIC_URL:-}"
    load_dotenv "$project_dir/.env"
    public_url="${public_url:-${SUPABASE_PUBLIC_URL:-http://localhost:8000}}"

    echo ""
    echo "=== Client Configuration for '$name' ==="
    echo ""
    echo "JavaScript/TypeScript:"
    echo "  import { createClient } from '@supabase/supabase-js'"
    echo ""
    echo "  const supabase = createClient("
    echo "    '${public_url}/project/${PROJECT_REF}',"
    echo "    '${PROJECT_ANON_KEY}'"
    echo "  )"
    echo ""
    echo "Environment variables:"
    echo "  SUPABASE_URL=${public_url}/project/${PROJECT_REF}"
    echo "  SUPABASE_ANON_KEY=${PROJECT_ANON_KEY}"
    echo "  SUPABASE_SERVICE_ROLE_KEY=${PROJECT_SERVICE_ROLE_KEY}"
    echo "  SUPABASE_JWT_SECRET=${PROJECT_JWT_SECRET}"
    echo ""
    echo "Direct database connection:"
    if [ -n "${PROJECT_DB_PASSWORD:-}" ]; then
        echo "  postgresql://${PROJECT_DB}:${PROJECT_DB_PASSWORD}@localhost:${POSTGRES_PORT}/${PROJECT_DB}"
    else
        echo "  postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${POSTGRES_PORT}/${PROJECT_DB}"
        echo "  (shared cluster password — run './superbase2.sh migrate-db-owner ${PROJECT_NAME}'"
        echo "   to give this project its own role and password.)"
    fi
    echo "  (requires the db port to be published on the host — 'docker port <db-container>'"
    echo "   prints nothing under Coolify. From another container use host 'db' instead.)"
    echo ""
}

cmd_setup() {
    local name="$1"

    # setup = create + up in one step (convenience for Coolify / SSH users)
    cmd_create "$name"
    cmd_up "$name"

    echo ""
    echo "Project '$name' is fully running!"
    echo "  Client config:  ./superbase2.sh client-config $name"
}

# Backfill a project created before per-project roles existed.
#
# Such projects have a database owned by supabase_admin (UI path) or postgres
# (CLI path) and tables in public owned by whoever pg-meta connected as, so the
# DATABASE_URL sb2 hands out cannot CREATE in public or ALTER its own tables.
# This gives the project its own role, transfers ownership to it, and writes the
# new password into .env + manifest. Data is untouched.
cmd_migrate_db_owner() {
    local name="$1"

    if ! project_exists "$name"; then
        echo "Error: Project '$name' does not exist."
        exit 1
    fi

    local env_file="$PROJECTS_DIR/$name/.env"
    local db
    db=$(grep "^PROJECT_DB=" "$env_file" | cut -d= -f2-)
    if [ -z "$db" ]; then
        echo "Error: PROJECT_DB missing from project .env."
        exit 1
    fi

    local db_password
    db_password=$(gen_hex 24)

    echo "Migrating '$name' ($db) to a per-project database role..."
    _ensure_project_db_role "$db" "$db_password"

    local db_ctr
    db_ctr=$(db_container)
    docker exec "$db_ctr" psql -U supabase_admin -v ON_ERROR_STOP=1 \
        -c "ALTER DATABASE \"$db\" OWNER TO \"$db\";"

    docker exec -i "$db_ctr" psql -U supabase_admin -v ON_ERROR_STOP=1 -d "$db" <<EOSQL
-- project_vrsite's case: public owned by supabase_admin directly, so database
-- ownership alone would not restore CREATE.
ALTER SCHEMA public OWNER TO pg_database_owner;

-- Reassign only public. REASSIGN OWNED BY is database-wide and would move
-- auth/storage/realtime objects too, breaking GoTrue, Storage and Realtime.
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname, c.relkind
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
       AND pg_get_userbyid(c.relowner) <> '$db'
       -- SERIAL/IDENTITY sequences cannot be reowned on their own ("is linked
       -- to table"); they follow their table's owner automatically.
       AND NOT (c.relkind = 'S' AND EXISTS (
             SELECT 1 FROM pg_depend d
              WHERE d.classid = 'pg_class'::regclass
                AND d.objid = c.oid
                AND d.deptype = 'a'))
     -- Tables before views: a view cannot be reowned to a role that lacks
     -- privileges on the tables it reads.
     ORDER BY CASE c.relkind WHEN 'r' THEN 0 WHEN 'p' THEN 0 ELSE 1 END
  LOOP
    EXECUTE format(
      CASE r.relkind
        WHEN 'S' THEN 'ALTER SEQUENCE public.%I OWNER TO %I'
        WHEN 'v' THEN 'ALTER VIEW public.%I OWNER TO %I'
        WHEN 'm' THEN 'ALTER MATERIALIZED VIEW public.%I OWNER TO %I'
        WHEN 'f' THEN 'ALTER FOREIGN TABLE public.%I OWNER TO %I'
        ELSE 'ALTER TABLE public.%I OWNER TO %I'
      END, r.relname, '$db');
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND pg_get_userbyid(p.proowner) <> '$db'
  LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO %I', r.sig, '$db');
  END LOOP;
END
\$\$;

ALTER DEFAULT PRIVILEGES FOR ROLE "$db" IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE "$db" IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE "$db" IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

-- Read access to the service-managed schemas for the SQL editor and pg-meta.
-- Unlike a fresh database these tables already exist, so grant on both the
-- existing ones and (via default privileges) any created later.
GRANT USAGE ON SCHEMA extensions TO "$db";
GRANT USAGE ON SCHEMA auth, storage TO "$db";
GRANT SELECT ON ALL TABLES IN SCHEMA auth TO "$db";
GRANT SELECT ON ALL TABLES IN SCHEMA storage TO "$db";
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT SELECT ON TABLES TO "$db";
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT SELECT ON TABLES TO "$db";

REVOKE CONNECT ON DATABASE "$db" FROM PUBLIC;
GRANT ALL ON DATABASE "$db" TO supabase_storage_admin;
GRANT ALL ON DATABASE "$db" TO supabase_auth_admin;
GRANT ALL ON DATABASE "$db" TO postgres;
GRANT CONNECT ON DATABASE "$db" TO authenticator;
GRANT CONNECT ON DATABASE "$db" TO anon;
GRANT CONNECT ON DATABASE "$db" TO authenticated;
GRANT CONNECT ON DATABASE "$db" TO service_role;
EOSQL

    # Persist the new credential. Appended when absent, which is the normal
    # case here — that is exactly what makes a project un-migrated.
    local tmp_env
    tmp_env=$(mktemp)
    awk -v dbpw="$db_password" '
        /^PROJECT_DB_PASSWORD=/ { print "PROJECT_DB_PASSWORD=" dbpw; seen=1; next }
        { print }
        END { if (!seen) print "PROJECT_DB_PASSWORD=" dbpw }
    ' "$env_file" > "$tmp_env"
    mv "$tmp_env" "$env_file"

    sync_manifest

    echo ""
    echo "Migrated '$name'. Restart it so pg-meta picks up the new role:"
    echo "  ./superbase2.sh down $name && ./superbase2.sh up $name"
}

cmd_rotate_keys() {
    local name="$1"

    if ! project_exists "$name"; then
        echo "Error: Project '$name' does not exist."
        exit 1
    fi

    local project_dir="$PROJECTS_DIR/$name"
    local env_file="$project_dir/.env"

    if [ ! -f "$env_file" ]; then
        echo "Error: Project .env not found at $env_file"
        exit 1
    fi

    local db
    db=$(grep "^PROJECT_DB=" "$env_file" | cut -d= -f2-)
    if [ -z "$db" ]; then
        echo "Error: PROJECT_DB missing from project .env."
        exit 1
    fi

    local jwt_secret anon_key service_role_key db_password
    jwt_secret=$(gen_base64 30)
    anon_key=$(gen_jwt "anon" "$jwt_secret")
    service_role_key=$(gen_jwt "service_role" "$jwt_secret")

    # Only roll the database password for projects that already have a role.
    # Creating one here without transferring ownership would advertise a
    # DATABASE_URL that authenticates but owns nothing — worse than leaving the
    # shared credential in place. migrate-db-owner is the way in.
    local has_db_role=0
    if grep -q "^PROJECT_DB_PASSWORD=." "$env_file"; then
        has_db_role=1
        db_password=$(gen_hex 24)
        echo "Rotating JWT secret + API keys + database password for project '$name'..."
        # Roll the role's password first. If it fails, .env still matches the
        # cluster, so the project keeps working and the run is a no-op.
        _ensure_project_db_role "$db" "$db_password"
    else
        db_password=""
        echo "Rotating JWT secret + API keys for project '$name'..."
        echo "NOTE: '$name' has no per-project database role, so its database password"
        echo "      is the shared POSTGRES_PASSWORD and is not rotated here."
        echo "      Run './superbase2.sh migrate-db-owner $name' to give it its own."
    fi

    # Atomically rewrite the secret lines in .env. Pass values via awk
    # variables to avoid sed-style escaping of '/', '+', '=' in JWTs.
    # PROJECT_DB_PASSWORD is only touched when the project has a role (rolldb=1),
    # so an un-migrated project keeps its .env free of an empty password line.
    local tmp_env
    tmp_env=$(mktemp)
    awk -v jwt="$jwt_secret" -v anon="$anon_key" -v srk="$service_role_key" \
        -v dbpw="$db_password" -v rolldb="$has_db_role" '
        /^PROJECT_JWT_SECRET=/        { print "PROJECT_JWT_SECRET=" jwt; next }
        /^PROJECT_ANON_KEY=/          { print "PROJECT_ANON_KEY=" anon; next }
        /^PROJECT_SERVICE_ROLE_KEY=/  { print "PROJECT_SERVICE_ROLE_KEY=" srk; next }
        /^PROJECT_DB_PASSWORD=/       { if (rolldb) { print "PROJECT_DB_PASSWORD=" dbpw } else { print }; next }
        { print }
    ' "$env_file" > "$tmp_env"
    mv "$tmp_env" "$env_file"

    # Update the per-database Postgres GUC used by the pgjwt extension.
    # Service JWT validation is driven by each container's *_JWT_SECRET env
    # var (refreshed by the restart below), but keeping the GUC in sync
    # avoids stale tokens minted in-DB after rotation.
    #
    # ALTER DATABASE requires ownership; on Supabase's image `supabase_admin`
    # is the bootstrap superuser and can ALTER any DB regardless of owner,
    # whereas `postgres` may only own DBs it created itself. Try the
    # superuser first and fall back to postgres for non-Supabase images.
    local safe_jwt_secret="${jwt_secret//\'/\'\'}"
    local db_ctr
    db_ctr=$(db_container)
    if ! docker exec "$db_ctr" psql -U supabase_admin -d "$db" \
            -c "ALTER DATABASE \"$db\" SET \"app.settings.jwt_secret\" TO '$safe_jwt_secret';" 2>/dev/null; then
        docker exec "$db_ctr" psql -U postgres -d "$db" \
            -c "ALTER DATABASE \"$db\" SET \"app.settings.jwt_secret\" TO '$safe_jwt_secret';"
    fi

    # Reflect the new keys into the manifest and Kong consumer credentials.
    sync_manifest
    cmd_rebuild_kong

    # Restart the project's containers so GoTrue/PostgREST/Realtime/Storage
    # pick up the new PROJECT_JWT_SECRET. Skip if nothing is running, or if
    # the caller is going to handle the restart out of band.
    #
    # Why SB2_ROTATE_SKIP_RESTART exists: cmd_down + cmd_up takes 30–90s,
    # which is longer than typical edge-proxy read timeouts (Coolify Traefik,
    # Cloudflare). When invoked through the agent → Studio → browser path,
    # the HTTP response would 502 even though the rotation succeeded on disk.
    # The Studio API route sets this and triggers the restart asynchronously
    # *after* responding with the new keys.
    if [ "${SB2_ROTATE_SKIP_RESTART:-0}" = "1" ]; then
        echo "Skipping container restart (SB2_ROTATE_SKIP_RESTART=1)."
    elif docker ps --filter "name=supabase-${name}-" --format "{{.Names}}" | grep -q .; then
        echo "Restarting project containers..."
        cmd_restart "$name"
    else
        echo "Project containers are not running — start them with: ./superbase2.sh up $name"
    fi

    echo "Rotation complete for '$name'."
}

cmd_rebuild_kong() {
    echo "Rebuilding Kong configuration..."

    local kong_yml="$DOCKER_DIR/volumes/api/kong.yml"
    local kong_temp="$DOCKER_DIR/volumes/api/temp.yml"
    local kong_backup="$DOCKER_DIR/volumes/api/kong.yml.bak"
    # Build into a temp file for atomic replacement — if interrupted
    # mid-build, the original kong.yml stays intact. Not `local`: the
    # EXIT trap fires after the function unwinds, so a local would be
    # out of scope and fail under `set -u`.
    kong_tmp=$(mktemp)
    trap 'rm -f "${kong_tmp:-}"' EXIT

    # Backup original — only if there's something to back up. On a fresh
    # install kong.yml hasn't been generated yet (only temp.yml exists).
    if [ -f "$kong_yml" ] && [ ! -f "$kong_backup" ]; then
        cp "$kong_yml" "$kong_backup"
    fi

    # Start with the template (base kong config)
    cp "$TEMPLATES_DIR/kong-base.yml.tpl" "$kong_tmp"

    # Strip the marker lines but keep the basic-auth plugin block.
    sed -e '/### SUPERBASE2_DASHBOARD_BASIC_AUTH_BEGIN ###/d' \
        -e '/### SUPERBASE2_DASHBOARD_BASIC_AUTH_END ###/d' \
        "$kong_tmp" > "${kong_tmp}.sed" && mv "${kong_tmp}.sed" "$kong_tmp"

    # Build per-project consumers, ACLs, and service routes.
    # Consumers and ACLs are injected at marker positions in the template
    # so Kong can authenticate per-project API keys.
    local consumers_block=""
    local acls_block=""

    for proj in $(list_projects); do
        local project_dir="$PROJECTS_DIR/$proj"
        if [ -f "$project_dir/.env" ]; then
            local ref anon_key service_role_key
            ref=$(grep "^PROJECT_REF=" "$project_dir/.env" | cut -d= -f2-)
            anon_key=$(grep "^PROJECT_ANON_KEY=" "$project_dir/.env" | cut -d= -f2-)
            service_role_key=$(grep "^PROJECT_SERVICE_ROLE_KEY=" "$project_dir/.env" | cut -d= -f2-)

            # Append consumer credentials for this project's keys
            consumers_block="${consumers_block}
  - username: anon-${proj}
    keyauth_credentials:
      - key: ${anon_key}
  - username: service_role-${proj}
    keyauth_credentials:
      - key: ${service_role_key}"

            # Per-project groups, not the shared anon/admin groups: those also
            # gate the main stack's routes, including /pg/ (pg-meta connected
            # as supabase_admin), so a project's service_role key in `admin`
            # would be a superuser SQL endpoint for the whole cluster. Scoping
            # also keeps one project's keys out of every other project's routes.
            acls_block="${acls_block}
  - consumer: anon-${proj}
    group: anon-${proj}
  - consumer: service_role-${proj}
    group: admin-${proj}"
        fi
    done

    # Inject consumers and ACLs at the marker positions.
    # Write blocks to temp files, then use sed to read them in at the markers.
    # This avoids awk issues with multi-line variable values.
    if [ -n "$consumers_block" ]; then
        local consumers_tmp acls_tmp result_tmp
        consumers_tmp=$(mktemp)
        acls_tmp=$(mktemp)
        result_tmp=$(mktemp)

        printf '%s' "$consumers_block" > "$consumers_tmp"
        printf '%s' "$acls_block" > "$acls_tmp"

        # Replace markers with file contents using sed's 'r' command
        sed -e "/### SUPERBASE2_CONSUMERS_MARKER ###/{
            r $consumers_tmp
            d
        }" -e "/### SUPERBASE2_ACLS_MARKER ###/{
            r $acls_tmp
            d
        }" "$kong_tmp" > "$result_tmp"
        mv "$result_tmp" "$kong_tmp"

        rm -f "$consumers_tmp" "$acls_tmp"
    else
        # No projects — just remove markers (temp file avoids non-portable sed -i)
        sed -e '/### SUPERBASE2_CONSUMERS_MARKER ###/d' \
            -e '/### SUPERBASE2_ACLS_MARKER ###/d' \
            "$kong_tmp" > "${kong_tmp}.sed" && mv "${kong_tmp}.sed" "$kong_tmp"
    fi

    # Append per-project service routes
    for proj in $(list_projects); do
        local project_dir="$PROJECTS_DIR/$proj"
        if [ -f "$project_dir/.env" ]; then
            local ref
            ref=$(grep "^PROJECT_REF=" "$project_dir/.env" | cut -d= -f2-)

            cat >> "$kong_tmp" <<EOF

  ## ── Project: $proj ($ref) ────────────────────────────────

  ## Auth routes for $proj
  - name: auth-v1-open-${proj}
    url: http://auth-${proj}:9999/verify
    routes:
      - name: auth-v1-open-${proj}
        strip_path: true
        paths:
          - /project/${ref}/auth/v1/verify
    plugins:
      - name: cors
  - name: auth-v1-open-callback-${proj}
    url: http://auth-${proj}:9999/callback
    routes:
      - name: auth-v1-open-callback-${proj}
        strip_path: true
        paths:
          - /project/${ref}/auth/v1/callback
    plugins:
      - name: cors
  - name: auth-v1-open-authorize-${proj}
    url: http://auth-${proj}:9999/authorize
    routes:
      - name: auth-v1-open-authorize-${proj}
        strip_path: true
        paths:
          - /project/${ref}/auth/v1/authorize
    plugins:
      - name: cors
  - name: auth-v1-open-sso-acs-${proj}
    url: http://auth-${proj}:9999/sso/saml/acs
    routes:
      - name: auth-v1-open-sso-acs-${proj}
        strip_path: true
        paths:
          - /project/${ref}/auth/v1/sso/saml/acs
    plugins:
      - name: cors
  - name: auth-v1-open-sso-metadata-${proj}
    url: http://auth-${proj}:9999/sso/saml/metadata
    routes:
      - name: auth-v1-open-sso-metadata-${proj}
        strip_path: true
        paths:
          - /project/${ref}/auth/v1/sso/saml/metadata
    plugins:
      - name: cors
  - name: auth-v1-${proj}
    url: http://auth-${proj}:9999/
    routes:
      - name: auth-v1-all-${proj}
        strip_path: true
        paths:
          - /project/${ref}/auth/v1/
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: false
      - name: request-transformer
        config:
          add:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
          replace:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
      - name: acl
        config:
          hide_groups_header: true
          allow:
            - admin-${proj}
            - anon-${proj}

  ## REST routes for $proj
  ## OpenAPI root: this project's service_role key only, as in the base config
  - name: rest-v1-openapi-${proj}
    url: http://rest-${proj}:3000/
    routes:
      - name: rest-v1-openapi-root-${proj}
        strip_path: true
        expression: 'http.path == "/project/${ref}/rest/v1/"'
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: false
      - name: request-transformer
        config:
          add:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
          replace:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
      - name: acl
        config:
          hide_groups_header: true
          allow:
            - admin-${proj}
  - name: rest-v1-${proj}
    url: http://rest-${proj}:3000/
    routes:
      - name: rest-v1-all-${proj}
        strip_path: true
        paths:
          - /project/${ref}/rest/v1/
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: false
      - name: request-transformer
        config:
          add:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
          replace:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
      - name: acl
        config:
          hide_groups_header: true
          allow:
            - admin-${proj}
            - anon-${proj}

  ## GraphQL routes for $proj
  - name: graphql-v1-${proj}
    url: http://rest-${proj}:3000/rpc/graphql
    routes:
      - name: graphql-v1-all-${proj}
        strip_path: true
        paths:
          - /project/${ref}/graphql/v1
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: false
      - name: request-transformer
        config:
          add:
            headers:
              - "Content-Profile: graphql_public"
              - "Authorization: \$LUA_AUTH_EXPR"
          replace:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
      - name: acl
        config:
          hide_groups_header: true
          allow:
            - admin-${proj}
            - anon-${proj}

  ## Realtime routes for $proj
  - name: realtime-v1-ws-${proj}
    url: http://realtime-${proj}.supabase-realtime:4000/socket
    protocol: ws
    routes:
      - name: realtime-v1-ws-${proj}
        strip_path: true
        paths:
          - /project/${ref}/realtime/v1/
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: false
      - name: request-transformer
        config:
          add:
            headers:
              - "x-api-key:\$LUA_RT_WS_EXPR"
          replace:
            querystring:
              - "apikey:\$LUA_RT_WS_EXPR"
      - name: acl
        config:
          hide_groups_header: true
          allow:
            - admin-${proj}
            - anon-${proj}
  # Realtime's tenant-admin API accepts any token signed with the project's
  # JWT secret, including the public anon key: blocked, as in the base config.
  - name: realtime-v1-rest-openapi-${proj}
    url: http://realtime-${proj}.supabase-realtime:4000/api/openapi
    protocol: http
    routes:
      - name: realtime-v1-rest-openapi-${proj}
        strip_path: true
        paths:
          - /project/${ref}/realtime/v1/api/openapi
    plugins:
      - name: request-termination
        config:
          status_code: 403
          message: "Access is forbidden."
  - name: realtime-v1-rest-tenants-${proj}
    url: http://realtime-${proj}.supabase-realtime:4000/api/tenants
    protocol: http
    routes:
      - name: realtime-v1-rest-tenants-${proj}
        strip_path: true
        paths:
          - /project/${ref}/realtime/v1/api/tenants
    plugins:
      - name: request-termination
        config:
          status_code: 403
          message: "Access is forbidden."
  - name: realtime-v1-rest-${proj}
    url: http://realtime-${proj}.supabase-realtime:4000/api
    protocol: http
    routes:
      - name: realtime-v1-rest-${proj}
        strip_path: true
        paths:
          - /project/${ref}/realtime/v1/api
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: false
      - name: request-transformer
        config:
          add:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
          replace:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
      - name: acl
        config:
          hide_groups_header: true
          allow:
            - admin-${proj}
            - anon-${proj}

  ## Storage routes for $proj
  - name: storage-v1-${proj}
    url: http://storage-${proj}:5000/
    routes:
      - name: storage-v1-all-${proj}
        strip_path: true
        paths:
          - /project/${ref}/storage/v1/
    plugins:
      - name: cors
      - name: request-transformer
        config:
          add:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
          replace:
            headers:
              - "Authorization: \$LUA_AUTH_EXPR"
      - name: post-function
        config:
          access:
            - |
              local auth = kong.request.get_header("authorization")
              if auth == nil or auth == "" or auth:find("^%s*$") then
                kong.service.request.clear_header("authorization")
              end

  ## Functions routes for $proj
  - name: functions-v1-${proj}
    url: http://functions-${proj}:9000/
    # Limit inactivity between reads, leaving 10s for the runtime's 150s idle timeout.
    read_timeout: 160000
    routes:
      - name: functions-v1-all-${proj}
        strip_path: true
        paths:
          - /project/${ref}/functions/v1/
    plugins:
      - name: cors
      # Projects have no sb_ keys to translate; just drop a client-supplied
      # sb-api-key so it can't pose as one Kong set (base config anti-spoof).
      - name: request-transformer
        config:
          remove:
            headers:
              - "sb-api-key"

  ## pg-meta routes for $proj
  - name: meta-${proj}
    url: http://meta-${proj}:8080/
    routes:
      - name: meta-all-${proj}
        strip_path: true
        paths:
          - /project/${ref}/pg/
    plugins:
      - name: key-auth
        config:
          hide_credentials: false
      - name: acl
        config:
          hide_groups_header: true
          allow:
            - admin-${proj}

  ## JWKS route for $proj
  - name: auth-v1-open-jwks-${proj}
    url: http://auth-${proj}:9999/.well-known/jwks.json
    routes:
      - name: auth-v1-open-jwks-${proj}
        strip_path: true
        paths:
          - /project/${ref}/auth/v1/.well-known/jwks.json
    plugins:
      - name: cors

  ## OAuth well-known for $proj
  - name: well-known-oauth-${proj}
    url: http://auth-${proj}:9999/.well-known/oauth-authorization-server
    routes:
      - name: well-known-oauth-${proj}
        strip_path: true
        paths:
          - /project/${ref}/.well-known/oauth-authorization-server
    plugins:
      - name: cors
EOF
        fi
    done

    # Write temp.yml to the kong-config volume (the entrypoint also reads here on
    # cold start). On reload, we additionally resolve placeholders inside the Kong
    # container — that's where SUPABASE_*_KEY, DASHBOARD_*, LUA_AUTH_EXPR, etc.
    # are all set — and pipe the result to /usr/local/kong/kong.yml, then call
    # `kong reload` (sub-second, no connection drop) instead of `docker restart`
    # (5-10s outage hitting every project).
    install_kong_config "$kong_tmp" "$kong_temp"

    local kong_ctr
    kong_ctr=$(kong_container)

    if [ -z "$kong_ctr" ]; then
        echo "Warning: Kong container not found, skipping reload"
        echo "Kong configuration written to $kong_temp"
        return 0
    fi

    # A recreated Kong (or Postgres) has dropped off the functions networks.
    cmd_connect_networks

    echo "Resolving placeholders and writing config to Kong..."
    # Pipe temp.yml through awk INSIDE the Kong container. ENVIRON in awk picks
    # up Kong's process environment, so all $VAR placeholders resolve correctly.
    # The awk is identical in spirit to kong-entrypoint.sh's substitution.
    #
    # The LUA_*_EXPR values are exported by kong-entrypoint.sh to Kong's own
    # process only — `docker exec` sessions don't see them, and nginx overwrites
    # PID 1's environ when it sets its process title — so derive them here the
    # same way. This block is copied from docker/volumes/api/kong-entrypoint.sh
    # (agent/configs/kong/kong-entrypoint.sh is a copy of it); keep it in sync,
    # or every rebuild-kong silently drops the opaque sb_ key translation.
    #
    # Key lines whose placeholder stays unresolved (the variable isn't in
    # Kong's environment) are dropped too: left in, the literal text
    # `$SUPABASE_SECRET_KEY` would itself be a valid service_role key.
    local kong_render_script
    read -r -d '' kong_render_script <<'EOS' || true
if [ -n "$SUPABASE_SECRET_KEY" ] && [ -n "$SUPABASE_PUBLISHABLE_KEY" ]; then
    export LUA_AUTH_EXPR="\$((headers.authorization ~= nil and headers.authorization:sub(1, 10) ~= 'Bearer sb_' and headers.authorization) or (headers.apikey == '$SUPABASE_SECRET_KEY' and 'Bearer $SERVICE_ROLE_KEY_ASYMMETRIC') or (headers.apikey == '$SUPABASE_PUBLISHABLE_KEY' and 'Bearer $ANON_KEY_ASYMMETRIC') or headers.apikey)"
    export LUA_RT_WS_EXPR="\$((query_params.apikey == '$SUPABASE_SECRET_KEY' and '$SERVICE_ROLE_KEY_ASYMMETRIC') or (query_params.apikey == '$SUPABASE_PUBLISHABLE_KEY' and '$ANON_KEY_ASYMMETRIC') or query_params.apikey)"
    export LUA_FUNCTIONS_EXPR="\$((headers.apikey == '$SUPABASE_SECRET_KEY' and '$SERVICE_ROLE_KEY_ASYMMETRIC') or (headers.apikey == '$SUPABASE_PUBLISHABLE_KEY' and '$ANON_KEY_ASYMMETRIC') or (headers.authorization == 'Bearer $SUPABASE_SECRET_KEY' and '$SERVICE_ROLE_KEY_ASYMMETRIC') or (headers.authorization == 'Bearer $SUPABASE_PUBLISHABLE_KEY' and '$ANON_KEY_ASYMMETRIC') or nil)"
else
    export LUA_AUTH_EXPR="\$((headers.authorization ~= nil and headers.authorization:sub(1, 10) ~= 'Bearer sb_' and headers.authorization) or headers.apikey)"
    export LUA_RT_WS_EXPR="\$(query_params.apikey)"
    export LUA_FUNCTIONS_EXPR="\$(nil)"
fi
awk '{
    line = $0
    out = ""
    while (match(line, /\$[A-Za-z_][A-Za-z_0-9]*/)) {
        varname = substr(line, RSTART + 1, RLENGTH - 1)
        if (varname in ENVIRON) {
            out = out substr(line, 1, RSTART - 1) ENVIRON[varname]
        } else {
            out = out substr(line, 1, RSTART + RLENGTH - 1)
        }
        line = substr(line, RSTART + RLENGTH)
    }
    print out line
}' > /usr/local/kong/kong.yml.new \
&& sed -i -e "/^[[:space:]]*- key:[[:space:]]*$/d" \
    -e '/^[[:space:]]*- key:[[:space:]]*\$/d' /usr/local/kong/kong.yml.new \
&& mv /usr/local/kong/kong.yml.new /usr/local/kong/kong.yml
EOS
    if ! docker exec -i "$kong_ctr" sh -c "$kong_render_script" < "$kong_tmp"; then
        echo "Warning: failed to write resolved config into Kong"
        return 1
    fi

    echo "Reloading Kong config..."
    docker exec "$kong_ctr" kong reload 2>/dev/null || {
        echo "Warning: kong reload failed, falling back to restart"
        docker restart "$kong_ctr" 2>/dev/null || echo "Warning: Kong restart also failed"
    }

    echo "Kong configuration updated."
}

# ─── Verify ──────────────────────────────────────────────────────────────────
#
# Check that running containers' JWT secrets match the project manifest.
# Catches drift caused by Coolify redeploying the main stack without
# restarting per-project containers through the agent (which loads the
# project .env). Returns 0 if all match, 1 if any mismatch.

cmd_verify() {
    local name="${1:-}"
    local errors=0

    local projects
    if [ -n "$name" ]; then
        projects="$name"
    else
        projects=$(list_projects)
    fi

    if [ -z "$projects" ]; then
        echo "No projects found."
        return 0
    fi

    for proj in $projects; do
        local project_dir="$PROJECTS_DIR/$proj"
        if [ ! -f "$project_dir/.env" ]; then
            echo "WARN: $proj — no .env file, skipping"
            continue
        fi

        local expected_jwt
        expected_jwt=$(grep "^PROJECT_JWT_SECRET=" "$project_dir/.env" | cut -d= -f2-)

        if [ -z "$expected_jwt" ]; then
            echo "WARN: $proj — PROJECT_JWT_SECRET not set in .env, skipping"
            continue
        fi

        # Check each container that uses the JWT secret.
        # Container names follow the pattern: supabase-<proj>-<service>
        # Realtime uses: realtime-<proj>.supabase-realtime
        local services="auth rest storage functions"
        local realtime_name="realtime-${proj}.supabase-realtime"

        for svc in $services; do
            local container="supabase-${proj}-${svc}"
            local running
            running=$(docker ps --filter "name=^${container}$" --format "{{.Names}}" 2>/dev/null)

            if [ -z "$running" ]; then
                echo "SKIP: $proj — $container not running"
                continue
            fi

            # Extract the JWT secret from the container's environment.
            # Different services use different env var names:
            #   auth:     GOTRUE_JWT_SECRET
            #   rest:     PGRST_JWT_SECRET
            #   storage:  AUTH_JWT_SECRET
            #   functions: JWT_SECRET
            local jwt_var
            case "$svc" in
                auth)      jwt_var="GOTRUE_JWT_SECRET" ;;
                rest)      jwt_var="PGRST_JWT_SECRET" ;;
                storage)   jwt_var="AUTH_JWT_SECRET" ;;
                functions) jwt_var="JWT_SECRET" ;;
            esac

            local actual_jwt
            actual_jwt=$(docker inspect "$container" --format "{{range .Config.Env}}{{println .}}{{end}}" 2>/dev/null \
                | grep "^${jwt_var}=" | cut -d= -f2-)

            if [ -z "$actual_jwt" ]; then
                echo "WARN: $proj — $container — $jwt_var not found in container env"
                errors=$((errors + 1))
                continue
            fi

            if [ "$actual_jwt" != "$expected_jwt" ]; then
                echo "MISMATCH: $proj — $container — $jwt_var"
                echo "  expected: $expected_jwt"
                echo "  actual:   $actual_jwt"
                errors=$((errors + 1))
            else
                echo "OK: $proj — $container — $jwt_var"
            fi
        done

        # Check realtime separately (different container name pattern)
        local rt_running
        rt_running=$(docker ps --filter "name=^${realtime_name}$" --format "{{.Names}}" 2>/dev/null)
        if [ -n "$rt_running" ]; then
            local actual_jwt
            actual_jwt=$(docker inspect "$realtime_name" --format "{{range .Config.Env}}{{println .}}{{end}}" 2>/dev/null \
                | grep "^API_JWT_SECRET=" | cut -d= -f2-)

            if [ -z "$actual_jwt" ]; then
                echo "WARN: $proj — $realtime_name — API_JWT_SECRET not found in container env"
                errors=$((errors + 1))
            elif [ "$actual_jwt" != "$expected_jwt" ]; then
                echo "MISMATCH: $proj — $realtime_name — API_JWT_SECRET"
                echo "  expected: $expected_jwt"
                echo "  actual:   $actual_jwt"
                errors=$((errors + 1))
            else
                echo "OK: $proj — $realtime_name — API_JWT_SECRET"
            fi
        else
            echo "SKIP: $proj — $realtime_name not running"
        fi
    done

    if [ "$errors" -gt 0 ]; then
        echo ""
        echo "FAIL: $errors mismatch(es) detected."
        echo "Fix: run './superbase2.sh up <project>' to restart containers with the correct .env"
        return 1
    fi

    echo ""
    echo "All JWT secrets match."
    return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  setup <name>          Create + start a project in one step"
    echo "  create <name>         Create a new project (DB + secrets only)"
    echo "  destroy <name> [--yes]  Destroy a project (--yes skips the confirmation prompt)"
    echo "  list                  List all projects"
    echo "  up [name]             Start project containers (all if no name)"
    echo "  down [name]           Stop project containers (all if no name)"
    echo "  restart <name>        Stop and start a project's containers (checks the main stack first)"
    echo "  status [name]         Show container status"
    echo "  client-config <name>  Print client SDK configuration"
    echo "  rebuild-kong          Regenerate Kong config and reload"
    echo "  reconcile [name...]   Recreate started projects' containers to match the main stack"
    echo "  rotate-keys <name>    Rotate JWT secret + anon/service_role keys + database password (restarts containers)"
    echo "  migrate-db-owner <name>  Give a pre-existing project its own database role (one-time backfill)"
    echo "  verify [name]        Check container JWT secrets match manifest"
    echo "  connect-networks      Re-attach Kong and Postgres to every project's functions network"
}

# State-changing commands run one at a time (see acquire_state_lock).
case "${1:-}" in
    setup|create|destroy|up|down|restart|rebuild-kong|rotate-keys|migrate-db-owner)
        acquire_state_lock
        ;;
esac

case "${1:-}" in
    setup)
        [ -z "${2:-}" ] && { echo "Error: project name required"; usage; exit 1; }
        cmd_setup "$2"
        ;;
    create)
        [ -z "${2:-}" ] && { echo "Error: project name required"; usage; exit 1; }
        cmd_create "$2"
        ;;
    destroy)
        [ -z "${2:-}" ] && { echo "Error: project name required"; usage; exit 1; }
        cmd_destroy "$2" "${3:-}"
        ;;
    list)
        cmd_list
        ;;
    up)
        cmd_up "${2:-}"
        ;;
    down)
        cmd_down "${2:-}"
        ;;
    restart)
        [ -z "${2:-}" ] && { echo "Error: project name required"; usage; exit 1; }
        cmd_restart "$2"
        ;;
    status)
        cmd_status "${2:-}"
        ;;
    client-config)
        [ -z "${2:-}" ] && { echo "Error: project name required"; usage; exit 1; }
        cmd_client_config "$2"
        ;;
    rebuild-kong)
        cmd_rebuild_kong
        ;;
    reconcile)
        _wait_for_main_stack
        acquire_state_lock
        cmd_reconcile "${@:2}"
        ;;
    rotate-keys)
        [ -z "${2:-}" ] && { echo "Error: project name required"; usage; exit 1; }
        cmd_rotate_keys "$2"
        ;;
    migrate-db-owner)
        [ -z "${2:-}" ] && { echo "Error: project name required"; usage; exit 1; }
        cmd_migrate_db_owner "$2"
        ;;
    verify)
        cmd_verify "${2:-}"
        ;;
    connect-networks)
        cmd_connect_networks
        ;;
    *)
        usage
        exit 1
        ;;
esac
