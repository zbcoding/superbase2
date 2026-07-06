#!/bin/sh
#
# SuperBase² — rotate init-only secrets on a running deployment.
#
# Most secrets in .env are LOCKED AFTER FIRST BOOT — changing them in the
# env alone desyncs the live DB/services from the config. This script does
# the rotation correctly: updates the DB, updates .env, restarts services.
#
# Usage:
#   sh rotate-secrets.sh postgres-password [new-password]
#   sh rotate-secrets.sh jwt-secret
#   sh rotate-secrets.sh dashboard-password [new-password]
#   sh rotate-secrets.sh status
#
# Run from the docker/ directory (one level above superbase2/).
#
# Safe to run: postgres-password, dashboard-password.
# Destructive (reads guidance and exits): jwt-secret, vault-enc-key,
# secret-key-base, pg-meta-crypto-key.

set -e

ENV_FILE="${ENV_FILE:-.env}"
DB_CONTAINER="${DB_CONTAINER:-supabase-db}"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: $ENV_FILE not found. Run this from the docker/ directory." >&2
    exit 1
fi

gen_hex() { openssl rand -hex "$1"; }

# Read a var from .env without sourcing it (avoids side effects).
get_env() {
    grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- | sed 's/^"//;s/"$//'
}

# In-place replace a var in .env (POSIX-safe, keeps a .bak).
set_env() {
    key=$1
    val=$2
    # Escape | for sed
    esc=$(printf '%s' "$val" | sed 's/[|\\&]/\\&/g')
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*$|${key}=${esc}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

require_db_running() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; then
        echo "Error: $DB_CONTAINER is not running. Start the stack first." >&2
        exit 1
    fi
}

cmd_status() {
    echo "Init-only vars currently set in $ENV_FILE:"
    for v in POSTGRES_PASSWORD JWT_SECRET VAULT_ENC_KEY SECRET_KEY_BASE PG_META_CRYPTO_KEY; do
        val=$(get_env "$v")
        if [ -n "$val" ]; then
            printf "  %-22s %s…(%d chars)\n" "$v" "$(printf '%s' "$val" | cut -c1-6)" "$(printf '%s' "$val" | wc -c | tr -d ' ')"
        else
            printf "  %-22s (unset)\n" "$v"
        fi
    done
}

cmd_postgres_password() {
    require_db_running
    new=${1:-}
    [ -z "$new" ] && new=$(gen_hex 16)

    echo "Rotating POSTGRES_PASSWORD…"
    echo "  New value will be written to $ENV_FILE (backup at ${ENV_FILE}.bak)"
    printf "Continue? (y/N) "
    read -r reply
    case "$reply" in [Yy]*) ;; *) echo "Aborted."; exit 1 ;; esac

    # Update all roles that were set to POSTGRES_PASSWORD at init.
    # Uses the current password from .env to connect.
    old=$(get_env POSTGRES_PASSWORD)
    if [ -z "$old" ]; then
        echo "Error: cannot read current POSTGRES_PASSWORD from $ENV_FILE" >&2
        exit 1
    fi

    docker exec -e PGPASSWORD="$old" "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
ALTER USER postgres                  WITH PASSWORD '${new}';
ALTER USER authenticator             WITH PASSWORD '${new}';
ALTER USER pgbouncer                 WITH PASSWORD '${new}';
ALTER USER supabase_auth_admin       WITH PASSWORD '${new}';
ALTER USER supabase_functions_admin  WITH PASSWORD '${new}';
ALTER USER supabase_storage_admin    WITH PASSWORD '${new}';
ALTER USER supabase_admin            WITH PASSWORD '${new}';
SQL

    set_env POSTGRES_PASSWORD "$new"
    echo "Postgres roles updated. Restarting dependent services…"
    docker compose restart auth rest realtime storage meta functions analytics supavisor studio || true
    echo "Done. New POSTGRES_PASSWORD: $new"
}

cmd_dashboard_password() {
    new=${1:-}
    [ -z "$new" ] && new=$(gen_hex 16)
    set_env DASHBOARD_PASSWORD "$new"
    docker compose restart kong || true
    echo "Done. New DASHBOARD_PASSWORD: $new"
}

cmd_jwt_secret() {
    cat <<'MSG'
Rotating JWT_SECRET is a multi-step operation this script does not automate,
because it invalidates all existing ANON_KEY / SERVICE_ROLE_KEY / user
sessions and requires coordinated updates to both the DB and every service.

Correct procedure:
  1. sh utils/generate-keys.sh                  # new JWT_SECRET + ANON/SERVICE keys
  2. Paste new JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY into your env
  3. Update the Postgres GUC to match:
       docker exec supabase-db psql -U postgres -c \
         "ALTER DATABASE postgres SET \"app.settings.jwt_secret\" TO '<new-secret>';"
  4. docker compose down && docker compose up -d
  5. Reissue API keys to any external clients — old JWTs will be rejected.

All existing user auth sessions will be invalidated. Plan a maintenance window.
MSG
    exit 2
}

cmd_encryption_key() {
    name=$1
    cat <<MSG
$name encrypts persisted data inside the stack. Rotating it in-place
is NOT supported — the old ciphertext becomes unreadable.

If you truly need to rotate:
  1. pg_dump the affected data (plaintext views only)
  2. Wipe the encrypted tables owned by the service that uses this key:
       VAULT_ENC_KEY / SECRET_KEY_BASE  → supavisor + realtime internal schemas
       PG_META_CRYPTO_KEY               → postgres-meta saved connections
  3. Set the new value in .env
  4. docker compose up -d
  5. Re-enter any saved connections / tenant configs from the dump.

If you only need a new value because the old one leaked, and no encrypted
data has been stored yet, a simple .env replace + restart is fine.
MSG
    exit 2
}

case "${1:-}" in
    postgres-password)   shift; cmd_postgres_password "$@" ;;
    dashboard-password)  shift; cmd_dashboard_password "$@" ;;
    jwt-secret)          cmd_jwt_secret ;;
    vault-enc-key)       cmd_encryption_key VAULT_ENC_KEY ;;
    secret-key-base)     cmd_encryption_key SECRET_KEY_BASE ;;
    pg-meta-crypto-key)  cmd_encryption_key PG_META_CRYPTO_KEY ;;
    status|"")           cmd_status ;;
    *) echo "Unknown command: $1" >&2; exit 1 ;;
esac
