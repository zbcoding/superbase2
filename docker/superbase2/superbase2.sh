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

# Source the main .env for shared config. Only present when the script runs
# on the host — in the sb2-agent container the shared creds come in through
# the container environment (set in the compose file), so we skip this.
if [ -f "$DOCKER_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$DOCKER_DIR/.env"
    set +a
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Resolve the shared Postgres container name. On a stock standalone install
# this is the literal `supabase-db`, but Coolify names compose services
# `<service>-<app-uuid>-<deploy-id>` (e.g. `db-nwcirqsw…-052516224648`).
# We discover it from the `com.docker.compose.service=db` label so the script
# works in both layouts. Result is cached for the life of the process.
#
# Override with SB2_DB_CONTAINER if you have a non-standard naming scheme.
_DB_CONTAINER_CACHE=""
db_container() {
    if [ -n "$_DB_CONTAINER_CACHE" ]; then
        echo "$_DB_CONTAINER_CACHE"
        return
    fi
    if [ -n "${SB2_DB_CONTAINER:-}" ]; then
        _DB_CONTAINER_CACHE="$SB2_DB_CONTAINER"
        echo "$_DB_CONTAINER_CACHE"
        return
    fi
    # When invoked from inside the sb2-agent container we can read our own
    # compose project label from /etc/hostname → docker inspect, then scope
    # the lookup so we never match a `db` service belonging to a different
    # stack on the same host. On a host-side run /etc/hostname is the host's
    # hostname (not a container id) and the inspect fails harmlessly,
    # leaving us with the broader unscoped lookup.
    local own_project=""
    if [ -r /etc/hostname ]; then
        local own_id
        own_id=$(tr -d '[:space:]' < /etc/hostname 2>/dev/null || true)
        if [ -n "$own_id" ]; then
            own_project=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$own_id" 2>/dev/null || true)
        fi
    fi

    local found=""
    if [ -n "$own_project" ]; then
        found=$(docker ps \
            --filter "label=com.docker.compose.service=db" \
            --filter "label=com.docker.compose.project=$own_project" \
            --format '{{.Names}}' 2>/dev/null | head -n 1)
    fi
    if [ -z "$found" ]; then
        found=$(docker ps --filter "label=com.docker.compose.service=db" \
                          --format '{{.Names}}' 2>/dev/null | head -n 1)
    fi
    if [ -z "$found" ]; then
        # Fallback: literal name used by the standalone (non-Coolify) layout.
        found="supabase-db"
    fi
    _DB_CONTAINER_CACHE="$found"
    echo "$_DB_CONTAINER_CACHE"
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
# A disabled service also takes its companion `<svc>-init-<name>` block with
# it (the init seeder service references the disabled service's volume), so
# we don't leave an orphan referencing an undeclared volume.
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
    trap 'rm -f "$tmp_file" "${tmp_file}.new"' EXIT
    cp "$compose_file" "$tmp_file"

    for svc in $disabled; do
        # The service key in the compose file is "<svc>-<name>:"
        local svc_key="${svc}-${name}"
        local init_key="${svc}-init-${name}"
        awk \
            -v svc_line="  ${svc_key}:" \
            -v init_line="  ${init_key}:" '
        BEGIN { skip=0; in_services=0 }
        # Enter / leave the services: section based on top-level keys.
        /^services:[[:space:]]*$/ { in_services=1; skip=0; print; next }
        /^[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*$/ { in_services=0; skip=0 }
        # Only strip blocks inside the services: section.
        in_services && ($0 == svc_line || $0 == init_line) { skip=1; next }
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

    # Load existing manifest entries keyed by project name using jq
    local existing_json='{"projects":[]}'
    if [ -f "$PROJECTS_MANIFEST" ] && [ -s "$PROJECTS_MANIFEST" ]; then
        existing_json=$(jq '.' "$PROJECTS_MANIFEST" 2>/dev/null || echo '{"projects":[]}')
    fi

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

    # Merge: disk projects first, then manifest-only entries
    jq -n --argjson disk "$disk_json" --argjson manifest "$manifest_only" --argjson disabled "$disabled_map" \
        '{projects: (($disk | map(if $disabled[.name] then . + {disabled_services: $disabled[.name]} else . end)) + $manifest)}' \
        > "$PROJECTS_MANIFEST"
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

    # Validate project name: only alphanumeric; 2-48 chars.
    # No underscores — Docker DNS does not support them in service hostnames (RFC 1123),
    # which would break per-project container resolution (e.g. meta-<name>).
    # No hyphens — reserved for future use and avoided for DB name safety.
    if [[ ! "$name" =~ ^[a-zA-Z0-9]+$ ]]; then
        echo "Error: Invalid project name '$name'."
        echo "Project names may only contain letters and numbers (no underscores or hyphens)."
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

    # Write project .env
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
API_EXTERNAL_URL=${API_EXTERNAL_URL:-http://localhost:8000}
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
MAILER_URLPATHS_CONFIRMATION=${MAILER_URLPATHS_CONFIRMATION:-/auth/v1/verify}
MAILER_URLPATHS_INVITE=${MAILER_URLPATHS_INVITE:-/auth/v1/verify}
MAILER_URLPATHS_RECOVERY=${MAILER_URLPATHS_RECOVERY:-/auth/v1/verify}
MAILER_URLPATHS_EMAIL_CHANGE=${MAILER_URLPATHS_EMAIL_CHANGE:-/auth/v1/verify}

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
EOSQL
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
    docker exec -i "$db_ctr" psql -U supabase_admin -d "$db_name" <<EOSQL
-- Set JWT config
ALTER DATABASE "$db_name" SET "app.settings.jwt_secret" TO '$safe_jwt_secret';
ALTER DATABASE "$db_name" SET "app.settings.jwt_exp" TO '$jwt_exp';

-- Create realtime schema
CREATE SCHEMA IF NOT EXISTS _realtime;
ALTER SCHEMA _realtime OWNER TO postgres;

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
EOSQL

    echo "Database '$db_name' initialized."
}

cmd_destroy() {
    local name="$1"

    if ! project_exists "$name"; then
        echo "Error: Project '$name' does not exist."
        exit 1
    fi

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

    local project_dir="$PROJECTS_DIR/$name"

    # Load project env
    set -a
    source "$project_dir/.env"
    set +a

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

cmd_up() {
    local name="${1:-}"

    if [ -z "$name" ]; then
        # Start all projects — generate any missing disk state first, then rebuild
        # Kong once and start all containers.
        for proj in $(list_projects); do
            _ensure_disk_state "$proj"
        done
        # Rebuild Kong once for all projects
        cmd_rebuild_kong
        for proj in $(list_projects); do
            _start_project "$proj"
        done
        return
    fi

    _ensure_disk_state "$name"
    cmd_rebuild_kong
    _start_project "$name"
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

    # Always update SUPABASE_NETWORK_NAME in the .env if the runtime
    # environment has a different value (e.g. agent resolved a Coolify
    # UUID-prefixed network that wasn't known when the project was created).
    if [ -f "$project_dir/.env" ] && [ -n "${SUPABASE_NETWORK_NAME:-}" ]; then
        local current_net
        current_net=$(grep "^SUPABASE_NETWORK_NAME=" "$project_dir/.env" | cut -d= -f2-)
        if [ "$current_net" != "$SUPABASE_NETWORK_NAME" ]; then
            sed -i "s|^SUPABASE_NETWORK_NAME=.*|SUPABASE_NETWORK_NAME=$SUPABASE_NETWORK_NAME|" "$project_dir/.env"
            echo "Updated SUPABASE_NETWORK_NAME: $current_net -> $SUPABASE_NETWORK_NAME"
        fi
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
    docker compose -f "$project_dir/docker-compose.yml" \
        --env-file "$project_dir/.env" \
        --project-name "supabase-${name}" \
        up -d

    # Fix realtime tenant: the realtime image seeds a tenant named "realtime-dev"
    # regardless of SEED_SELF_HOST_EXTERNAL_ID. Rename it to match the expected
    # "realtime-{name}" so the healthcheck passes.
    _fix_realtime_tenant "$name"

    echo "Project '$name' started."
}

# Rename the default "realtime-dev" tenant to "realtime-{name}" in the project DB.
# The realtime container seeds "realtime-dev" on first start and ignores
# SEED_SELF_HOST_EXTERNAL_ID, so we patch the tenant row after startup.
# We can't wait for "healthy" because the healthcheck itself depends on the
# tenant having the correct name, so we wait for the container to be running
# and then poll for the tenant row to appear in _realtime.tenants.
_fix_realtime_tenant() {
    local name="$1"
    local rt_ctr="realtime-${name}.supabase-realtime"
    local db_ctr
    db_ctr=$(db_container)

    # Read project DB name from .env
    local project_db
    project_db=$(grep "^PROJECT_DB=" "$PROJECTS_DIR/$name/.env" 2>/dev/null | cut -d= -f2-)
    [ -z "$project_db" ] && return 0

    # If the realtime container doesn't exist (disabled service), skip silently
    if ! docker inspect "$rt_ctr" --format '{{.Id}}' &>/dev/null; then
        return 0
    fi

    # Wait for the realtime container to be running (max 30s)
    local waited=0
    while [ $waited -lt 30 ]; do
        local running
        running=$(docker inspect "$rt_ctr" --format '{{.State.Running}}' 2>/dev/null || echo "false")
        if [ "$running" = "true" ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # Give realtime a few seconds to seed the tenant after the process starts
    sleep 3

    # Poll for the tenant row to appear (max 30s)
    local expected_id="realtime-${name}"
    waited=0
    while [ $waited -lt 30 ]; do
        local tenant_count
        tenant_count=$(docker exec "$db_ctr" psql -U supabase_admin -d "$project_db" -tAc \
            "SELECT count(*) FROM _realtime.tenants WHERE name='realtime-dev';" 2>/dev/null || echo "0")
        if [ "$tenant_count" -gt 0 ] 2>/dev/null; then
            docker exec "$db_ctr" psql -U supabase_admin -d "$project_db" -tAc \
                "UPDATE _realtime.tenants SET external_id='$expected_id', name='$expected_id' WHERE name='realtime-dev';" \
                2>/dev/null || true
            echo "Realtime tenant renamed: realtime-dev -> $expected_id"
            return 0
        fi
        # Also check if the tenant already has the correct name (idempotent)
        local correct_count
        correct_count=$(docker exec "$db_ctr" psql -U supabase_admin -d "$project_db" -tAc \
            "SELECT count(*) FROM _realtime.tenants WHERE name='$expected_id';" 2>/dev/null || echo "0")
        if [ "$correct_count" -gt 0 ] 2>/dev/null; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # Timed out — not fatal, the container will just show unhealthy
    echo "WARN: Could not fix realtime tenant for '$name' (timed out waiting for seed)"
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

    # Write .env
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
API_EXTERNAL_URL=${API_EXTERNAL_URL:-http://localhost:8000}
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
MAILER_URLPATHS_CONFIRMATION=${MAILER_URLPATHS_CONFIRMATION:-/auth/v1/verify}
MAILER_URLPATHS_INVITE=${MAILER_URLPATHS_INVITE:-/auth/v1/verify}
MAILER_URLPATHS_RECOVERY=${MAILER_URLPATHS_RECOVERY:-/auth/v1/verify}
MAILER_URLPATHS_EMAIL_CHANGE=${MAILER_URLPATHS_EMAIL_CHANGE:-/auth/v1/verify}

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
    set -a
    source "$project_dir/.env"
    set +a

    local public_url="${SUPABASE_PUBLIC_URL:-http://localhost:8000}"

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
        cmd_down "$name"
        cmd_up "$name"
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

            acls_block="${acls_block}
  - consumer: anon-${proj}
    group: anon
  - consumer: service_role-${proj}
    group: admin"
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
            - admin
            - anon

  ## REST routes for $proj
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
            - admin
            - anon

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
            - admin
            - anon

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
            - admin
            - anon
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
            - admin
            - anon

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
    read_timeout: 150000
    routes:
      - name: functions-v1-all-${proj}
        strip_path: true
        paths:
          - /project/${ref}/functions/v1/
    plugins:
      - name: cors

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
            - admin

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
    mv "$kong_tmp" "$kong_temp"
    chmod 644 "$kong_temp"

    local kong_ctr
    kong_ctr=$(docker ps --filter 'label=com.docker.compose.service=kong' --format '{{.Names}}' | head -1)

    if [ -z "$kong_ctr" ]; then
        echo "Warning: Kong container not found, skipping reload"
        echo "Kong configuration written to $kong_temp"
        return 0
    fi

    echo "Resolving placeholders and writing config to Kong..."
    # Pipe temp.yml through awk INSIDE the Kong container. ENVIRON in awk picks
    # up Kong's process environment, so all $VAR placeholders resolve correctly.
    # The awk is identical in spirit to kong-entrypoint.sh's substitution.
    if ! cat "$kong_temp" | docker exec -i "$kong_ctr" sh -c '
        export LUA_AUTH_EXPR="\$((headers.authorization ~= nil and headers.authorization:sub(1, 10) ~= '"'"'Bearer sb_'"'"' and headers.authorization) or headers.apikey)"
        export LUA_RT_WS_EXPR="\$(query_params.apikey)"
        awk '"'"'{
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
        }'"'"' > /usr/local/kong/kong.yml.new \
        && sed -i "/^[[:space:]]*- key:[[:space:]]*$/d" /usr/local/kong/kong.yml.new \
        && mv /usr/local/kong/kong.yml.new /usr/local/kong/kong.yml
    '; then
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
    echo "  destroy <name>        Destroy a project"
    echo "  list                  List all projects"
    echo "  up [name]             Start project containers (all if no name)"
    echo "  down [name]           Stop project containers (all if no name)"
    echo "  status [name]         Show container status"
    echo "  client-config <name>  Print client SDK configuration"
    echo "  rebuild-kong          Regenerate Kong config and reload"
    echo "  rotate-keys <name>    Rotate JWT secret + anon/service_role keys + database password (restarts containers)"
    echo "  migrate-db-owner <name>  Give a pre-existing project its own database role (one-time backfill)"
    echo "  verify [name]        Check container JWT secrets match manifest"
}

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
        cmd_destroy "$2"
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
    *)
        usage
        exit 1
        ;;
esac
