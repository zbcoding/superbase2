#!/bin/bash
#
# SuperBase² — multi-project orchestration for self-hosted Supabase
#
# Shares heavy containers (Postgres, Kong, Studio, imgproxy, analytics, vector)
# and spins up lightweight per-project containers (GoTrue, PostgREST, Realtime,
# Storage, Edge Functions, postgres-meta).
#
# Usage:
#   ./superbase2.sh create <name>         Create a new project
#   ./superbase2.sh destroy <name>        Destroy a project (removes containers + data)
#   ./superbase2.sh list                  List all projects
#   ./superbase2.sh up [name]             Start project containers (all if no name)
#   ./superbase2.sh down [name]           Stop project containers (all if no name)
#   ./superbase2.sh status [name]         Show container status
#   ./superbase2.sh client-config <name>  Print client SDK config
#   ./superbase2.sh rebuild-kong          Regenerate Kong config and reload
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_DIR="$SCRIPT_DIR/projects"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
PROJECTS_MANIFEST="$SCRIPT_DIR/projects.json"

# Ensure the manifest file exists (prevents Docker from bind-mounting a directory)
[ -f "$PROJECTS_MANIFEST" ] || echo '{ "projects": [] }' > "$PROJECTS_MANIFEST"

# Require jq for JSON manipulation
if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' is required but not installed."
    echo "  Install it with:  apt-get install jq  /  brew install jq  /  apk add jq"
    exit 1
fi

# Source the main .env for shared config
if [ -f "$DOCKER_DIR/.env" ]; then
    set -a
    source "$DOCKER_DIR/.env"
    set +a
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

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
    cp "$compose_file" "$tmp_file"

    for svc in $disabled; do
        # The service key in the compose file is "<svc>-<name>:"
        local svc_key="${svc}-${name}"
        awk -v svc="  ${svc_key}:" '
        BEGIN { skip=0 }
        $0 == svc || index($0, svc) == 1 { skip=1; next }
        skip && /^  [a-zA-Z]/ { skip=0 }
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
        local secret_key_base pg_meta_crypto_key s3_access_key_id s3_access_key_secret
        name=$(basename "$d")
        [ -f "$d/.env" ] || continue
        disk_projects["$name"]=1
        ref=$(grep "^PROJECT_REF=" "$d/.env" | cut -d= -f2)
        db=$(grep "^PROJECT_DB=" "$d/.env" | cut -d= -f2)
        jwt_secret=$(grep "^PROJECT_JWT_SECRET=" "$d/.env" | cut -d= -f2)
        anon_key=$(grep "^PROJECT_ANON_KEY=" "$d/.env" | cut -d= -f2)
        service_role_key=$(grep "^PROJECT_SERVICE_ROLE_KEY=" "$d/.env" | cut -d= -f2)
        created_at=$(grep "^# Generated:" "$d/.env" | sed 's/# Generated: //')
        [ -z "$created_at" ] && created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        # Secondary secrets — must be synced to manifest so disk state reconstruction works
        secret_key_base=$(grep "^PROJECT_SECRET_KEY_BASE=" "$d/.env" | cut -d= -f2)
        pg_meta_crypto_key=$(grep "^PROJECT_PG_META_CRYPTO_KEY=" "$d/.env" | cut -d= -f2)
        s3_access_key_id=$(grep "^PROJECT_S3_ACCESS_KEY_ID=" "$d/.env" | cut -d= -f2)
        s3_access_key_secret=$(grep "^PROJECT_S3_ACCESS_KEY_SECRET=" "$d/.env" | cut -d= -f2)

        disk_json=$(echo "$disk_json" | jq \
            --arg ref "$ref" \
            --arg name "$name" \
            --arg db "$db" \
            --arg jwt "$jwt_secret" \
            --arg anon "$anon_key" \
            --arg srk "$service_role_key" \
            --arg ca "$created_at" \
            --arg skb "$secret_key_base" \
            --arg pmck "$pg_meta_crypto_key" \
            --arg s3id "$s3_access_key_id" \
            --arg s3sec "$s3_access_key_secret" \
            '. + [{ref: $ref, name: $name, db: $db, jwt_secret: $jwt, anon_key: $anon, service_role_key: $srk, status: "ACTIVE_HEALTHY", created_at: $ca, secret_key_base: $skb, pg_meta_crypto_key: $pmck, s3_access_key_id: $s3id, s3_access_key_secret: $s3sec}]')
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

    # Merge: disk projects first, then manifest-only entries
    jq -n --argjson disk "$disk_json" --argjson manifest "$manifest_only" \
        '{projects: ($disk + $manifest)}' > "$PROJECTS_MANIFEST"
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
    mkdir -p "$project_dir/volumes/storage-${name}"
    mkdir -p "$project_dir/volumes/functions/main"

    # Copy the shared edge functions entrypoint so the container can start.
    if [ -f "$DOCKER_DIR/volumes/functions/main/index.ts" ]; then
        cp "$DOCKER_DIR/volumes/functions/main/index.ts" "$project_dir/volumes/functions/main/index.ts"
    else
        cat > "$project_dir/volumes/functions/main/index.ts" <<'EOFUNC'
import { serve } from "https://deno.land/std/http/server.ts"
serve(() => new Response("ok"))
EOFUNC
    fi

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
    local pg_meta_crypto_key
    pg_meta_crypto_key=$(gen_base64 24)
    local s3_access_key_id
    s3_access_key_id=$(gen_hex 16)
    local s3_access_key_secret
    s3_access_key_secret=$(gen_hex 32)
    local db_name="project_${name}"

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
PROJECT_PG_META_CRYPTO_KEY=$pg_meta_crypto_key
PROJECT_S3_ACCESS_KEY_ID=$s3_access_key_id
PROJECT_S3_ACCESS_KEY_SECRET=$s3_access_key_secret

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
REGION=${REGION:-stub}
STORAGE_TENANT_ID=$project_ref
IMGPROXY_ENABLE_WEBP_DETECTION=${IMGPROXY_ENABLE_WEBP_DETECTION:-true}

# Functions
FUNCTIONS_VERIFY_JWT=${FUNCTIONS_VERIFY_JWT:-false}

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
    _init_project_db "$name" "$db_name" "$jwt_secret" "${JWT_EXPIRY:-3600}"

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

_init_project_db() {
    local name="$1"
    local db_name="$2"
    local jwt_secret="$3"
    local jwt_exp="$4"

    # Create the database — check for "already exists" explicitly
    if ! docker exec supabase-db psql -U postgres -c "CREATE DATABASE \"$db_name\";" 2>&1; then
        if docker exec supabase-db psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name';" | grep -q 1; then
            echo "Database '$db_name' already exists — continuing."
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
    docker exec supabase-db psql -U postgres -d "$db_name" <<EOSQL
-- Set JWT config
ALTER DATABASE "$db_name" SET "app.settings.jwt_secret" TO '$safe_jwt_secret';
ALTER DATABASE "$db_name" SET "app.settings.jwt_exp" TO '$jwt_exp';

-- Create realtime schema
CREATE SCHEMA IF NOT EXISTS _realtime;
ALTER SCHEMA _realtime OWNER TO postgres;

-- Create storage schema (if needed by storage service)
CREATE SCHEMA IF NOT EXISTS storage;
GRANT ALL ON SCHEMA storage TO postgres;
GRANT ALL ON SCHEMA storage TO supabase_storage_admin;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;

-- Create auth schema
CREATE SCHEMA IF NOT EXISTS auth;
GRANT ALL ON SCHEMA auth TO supabase_auth_admin;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

-- Grant schema usage
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

-- Service roles need CONNECT privilege on non-default databases.
-- Without this, PostgREST (authenticator) and Storage (supabase_storage_admin) fail to connect.
GRANT ALL ON DATABASE "$db_name" TO supabase_storage_admin;
GRANT ALL ON DATABASE "$db_name" TO supabase_auth_admin;
GRANT CONNECT ON DATABASE "$db_name" TO authenticator;
GRANT CONNECT ON DATABASE "$db_name" TO anon;
GRANT CONNECT ON DATABASE "$db_name" TO authenticated;
GRANT CONNECT ON DATABASE "$db_name" TO service_role;

-- Create extensions schema and extensions
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgjwt WITH SCHEMA extensions;

-- Add extensions schema to the default search_path so functions like
-- uuid_generate_v4() work without schema-qualifying them.
ALTER DATABASE "$db_name" SET search_path TO "\$user", public, extensions;

-- Grant usage so all roles can access extension functions
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
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

    # Drop the database
    echo "Dropping database: $PROJECT_DB"
    if ! docker exec supabase-db psql -U postgres -c "DROP DATABASE IF EXISTS \"$PROJECT_DB\";" 2>&1; then
        echo "Warning: Failed to drop database '$PROJECT_DB'. It may need manual cleanup."
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
            ref=$(grep "^PROJECT_REF=" "$project_dir/.env" | cut -d= -f2)
            db=$(grep "^PROJECT_DB=" "$project_dir/.env" | cut -d= -f2)

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
        # Start all projects
        for proj in $(list_projects); do
            cmd_up "$proj"
        done
        return
    fi

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

    # Always regenerate the compose file from template before starting.
    # This ensures service toggles (disabled_services in manifest) take effect
    # without needing a separate "regenerate" step — just `down` then `up`.
    if [ -f "$project_dir/.env" ] && [ -f "$TEMPLATES_DIR/docker-compose.project.yml.tpl" ]; then
        local ref db
        ref=$(grep "^PROJECT_REF=" "$project_dir/.env" | cut -d= -f2)
        db=$(grep "^PROJECT_DB=" "$project_dir/.env" | cut -d= -f2)
        sed \
            -e "s|{{PROJECT_NAME}}|$name|g" \
            -e "s|{{PROJECT_REF}}|$ref|g" \
            -e "s|{{PROJECT_DB}}|$db|g" \
            "$TEMPLATES_DIR/docker-compose.project.yml.tpl" \
            > "$project_dir/docker-compose.yml"
        filter_disabled_services "$project_dir/docker-compose.yml" "$name"
    fi

    echo "Starting project: $name"
    docker compose -f "$project_dir/docker-compose.yml" \
        --env-file "$project_dir/.env" \
        --project-name "supabase-${name}" \
        up -d

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
    mkdir -p "$project_dir/volumes/storage-${name}"
    mkdir -p "$project_dir/volumes/functions/main"

    # Copy the shared edge functions entrypoint so the container can start.
    if [ -f "$DOCKER_DIR/volumes/functions/main/index.ts" ]; then
        cp "$DOCKER_DIR/volumes/functions/main/index.ts" "$project_dir/volumes/functions/main/index.ts"
    else
        cat > "$project_dir/volumes/functions/main/index.ts" <<'EOFUNC'
import { serve } from "https://deno.land/std/http/server.ts"
serve(() => new Response("ok"))
EOFUNC
    fi

    # Read secondary secrets from manifest if available, otherwise generate new ones.
    # API-created projects store these in the manifest; losing them breaks running services.
    local secret_key_base pg_meta_crypto_key s3_access_key_id s3_access_key_secret
    secret_key_base=$(echo "$manifest_json" | jq -r '.secret_key_base // empty')
    pg_meta_crypto_key=$(echo "$manifest_json" | jq -r '.pg_meta_crypto_key // empty')
    s3_access_key_id=$(echo "$manifest_json" | jq -r '.s3_access_key_id // empty')
    s3_access_key_secret=$(echo "$manifest_json" | jq -r '.s3_access_key_secret // empty')
    [ -z "$secret_key_base" ] && secret_key_base=$(gen_base64 48)
    [ -z "$pg_meta_crypto_key" ] && pg_meta_crypto_key=$(gen_base64 24)
    [ -z "$s3_access_key_id" ] && s3_access_key_id=$(gen_hex 16)
    [ -z "$s3_access_key_secret" ] && s3_access_key_secret=$(gen_hex 32)

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
PROJECT_PG_META_CRYPTO_KEY=$pg_meta_crypto_key
PROJECT_S3_ACCESS_KEY_ID=$s3_access_key_id
PROJECT_S3_ACCESS_KEY_SECRET=$s3_access_key_secret

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
REGION=${REGION:-stub}
STORAGE_TENANT_ID=$ref
IMGPROXY_ENABLE_WEBP_DETECTION=${IMGPROXY_ENABLE_WEBP_DETECTION:-true}

# Functions
FUNCTIONS_VERIFY_JWT=${FUNCTIONS_VERIFY_JWT:-false}

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

    # Rebuild Kong routes for this project
    cmd_rebuild_kong

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
    echo ""
    echo "Direct database connection:"
    echo "  postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${POSTGRES_PORT}/${PROJECT_DB}"
    echo ""
}

cmd_rebuild_kong() {
    echo "Rebuilding Kong configuration..."

    local kong_yml="$DOCKER_DIR/volumes/api/kong.yml"
    local kong_backup="$DOCKER_DIR/volumes/api/kong.yml.bak"
    # Build into a temp file for atomic replacement — if interrupted
    # mid-build, the original kong.yml stays intact.
    local kong_tmp
    kong_tmp=$(mktemp)

    # Backup original
    if [ ! -f "$kong_backup" ]; then
        cp "$kong_yml" "$kong_backup"
    fi

    # Start with the template (base kong config)
    cp "$TEMPLATES_DIR/kong-base.yml.tpl" "$kong_tmp"

    # Build per-project consumers, ACLs, and service routes.
    # Consumers and ACLs are injected at marker positions in the template
    # so Kong can authenticate per-project API keys.
    local consumers_block=""
    local acls_block=""

    for proj in $(list_projects); do
        local project_dir="$PROJECTS_DIR/$proj"
        if [ -f "$project_dir/.env" ]; then
            local ref anon_key service_role_key
            ref=$(grep "^PROJECT_REF=" "$project_dir/.env" | cut -d= -f2)
            anon_key=$(grep "^PROJECT_ANON_KEY=" "$project_dir/.env" | cut -d= -f2)
            service_role_key=$(grep "^PROJECT_SERVICE_ROLE_KEY=" "$project_dir/.env" | cut -d= -f2)

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
            ref=$(grep "^PROJECT_REF=" "$project_dir/.env" | cut -d= -f2)

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

    # Atomic replacement — only overwrites kong.yml once the full config is built
    mv "$kong_tmp" "$kong_yml"

    # Try to reload Kong if it's running
    if docker ps --format '{{.Names}}' | grep -q "^supabase-kong$"; then
        echo "Reloading Kong..."
        docker exec supabase-kong kong reload 2>/dev/null || echo "Warning: Kong reload failed. Restart Kong manually."
    fi

    echo "Kong configuration updated."
}

# ─── Main ────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  create <name>         Create a new project"
    echo "  destroy <name>        Destroy a project"
    echo "  list                  List all projects"
    echo "  up [name]             Start project containers (all if no name)"
    echo "  down [name]           Stop project containers (all if no name)"
    echo "  status [name]         Show container status"
    echo "  client-config <name>  Print client SDK configuration"
    echo "  rebuild-kong          Regenerate Kong config and reload"
}

case "${1:-}" in
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
    *)
        usage
        exit 1
        ;;
esac
