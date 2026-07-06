#!/bin/sh
#
# Generate secrets and legacy symmetric JWT API keys for self-hosted Supabase.
#
# Generates: JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY, and other secrets
# needed for a fresh installation.
#
# Usage:
#   sh generate-keys.sh              # Interactive: prints keys, prompts to update .env
#   sh generate-keys.sh --update-env # Prints keys and writes them to .env
#   sh generate-keys.sh --coolify    # Output only required Coolify env vars (paste into panel)
#   sh generate-keys.sh | tee keys   # Non-interactive: prints keys only
#
# Portions of this code are derived from Inder Singh's setup.sh shell script.
# Copyright 2025 Inder Singh. Licensed under Apache License 2.0.
# Original source: https://github.com/singh-inder/supabase-automated-self-host/blob/main/setup.sh
#

set -e

gen_hex() {
    openssl rand -hex "$1"
}

gen_base64() {
    openssl rand -base64 "$1"
}

base64_url_encode() {
    openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

gen_token() {
    payload=$1
    payload_base64=$(printf %s "$payload" | base64_url_encode)
    header_base64=$(printf %s "$header" | base64_url_encode)
    signed_content="${header_base64}.${payload_base64}"
    signature=$(printf %s "$signed_content" | openssl dgst -binary -sha256 -hmac "$jwt_secret" | base64_url_encode)
    printf '%s' "${signed_content}.${signature}"
}

if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is required but not found."
    exit 1
fi

jwt_secret="$(gen_base64 30)"

# Used in gen_token()
header='{"alg":"HS256","typ":"JWT"}'
iat=$(date +%s)
exp=$((iat + 5 * 3600 * 24 * 365)) # 5 years

# Normalizes JSON formatting so that the token matches https://www.jwt.io/ results
anon_payload="{\"role\":\"anon\",\"iss\":\"supabase\",\"iat\":$iat,\"exp\":$exp}"
service_role_payload="{\"role\":\"service_role\",\"iss\":\"supabase\",\"iat\":$iat,\"exp\":$exp}"

#echo "anon_payload=$anon_payload"
#echo "service_role_payload=$service_role_payload"

anon_key=$(gen_token "$anon_payload")
service_role_key=$(gen_token "$service_role_payload")

secret_key_base=$(gen_base64 48)
realtime_db_enc_key=$(gen_hex 8)
vault_enc_key=$(gen_hex 16)
db_enc_key=$(gen_hex 8) # Realtime tenant encryption (AES-128 — exactly 16 chars)
pg_meta_crypto_key=$(gen_base64 24)

logflare_public_access_token=$(gen_base64 24)
logflare_private_access_token=$(gen_base64 24)

s3_protocol_access_key_id=$(gen_hex 16)
s3_protocol_access_key_secret=$(gen_hex 32)

minio_root_password=$(gen_hex 16)

postgres_password=$(gen_hex 16)
dashboard_password=$(gen_hex 16)
sb2_agent_token=$(gen_hex 32)

# ── Coolify mode: output ALL vars referenced in docker-compose.coolify.yml ──
if [ "$1" = "--coolify" ]; then
    echo "# ── Paste into Coolify's environment variables panel ──"
    echo "# Generated on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "#"
    echo "# Every \${VARIABLE} in docker-compose.coolify.yml is listed below."
    echo "# Blank values use the default from the compose file."
    echo "# Only SUPABASE_PUBLIC_URL and the secrets section are required."
    echo ""
    echo "# ── URLs (set to your domain) ──"
    echo "SUPABASE_PUBLIC_URL=https://supabase.yourdomain.com"
    echo "SITE_URL=http://localhost:3000"
    echo "ADDITIONAL_REDIRECT_URLS="
    echo ""
    echo "# ── Secrets (auto-generated) ──"
    echo "POSTGRES_DB=postgres"
    echo "POSTGRES_HOST=db"
    echo "POSTGRES_PORT=5432"
    echo "POSTGRES_PASSWORD=${postgres_password}"
    echo "JWT_SECRET=${jwt_secret}"
    echo "ANON_KEY=${anon_key}"
    echo "SERVICE_ROLE_KEY=${service_role_key}"
    echo "DASHBOARD_PASSWORD=${dashboard_password}"
    echo "SECRET_KEY_BASE=${secret_key_base}"
    echo "VAULT_ENC_KEY=${vault_enc_key}"
    echo "DB_ENC_KEY=${db_enc_key}"
    echo "PG_META_CRYPTO_KEY=${pg_meta_crypto_key}"
    echo "LOGFLARE_PUBLIC_ACCESS_TOKEN=${logflare_public_access_token}"
    echo "LOGFLARE_PRIVATE_ACCESS_TOKEN=${logflare_private_access_token}"
    echo "S3_PROTOCOL_ACCESS_KEY_ID=${s3_protocol_access_key_id}"
    echo "S3_PROTOCOL_ACCESS_KEY_SECRET=${s3_protocol_access_key_secret}"
    echo "SB2_AGENT_TOKEN=${sb2_agent_token}"
    echo ""
    echo "# ── Studio ──"
    echo "DASHBOARD_USERNAME=supabase"
    echo "STUDIO_DEFAULT_ORGANIZATION="
    echo "STUDIO_DEFAULT_PROJECT="
    echo "OPENAI_API_KEY="
    echo ""
    echo "# ── SuperBase² multi-project mode ──"
    echo "# Enables the per-project container/database management API under"
    echo "# /api/superbase2/*. Defaults to true — set to false to run as a"
    echo "# plain single-project self-hosted Supabase."
    echo "# Note: the client-side check is read from NEXT_PUBLIC_SUPERBASE2_ENABLED"
    echo "# and inlined at BUILD TIME. To toggle it off in a deployed image you"
    echo "# must ALSO rebuild with: --build-arg NEXT_PUBLIC_SUPERBASE2_ENABLED=false"
    echo "SUPERBASE2_ENABLED=true"
    echo ""
    echo "# ── Auth ──"
    echo "JWT_EXPIRY=3600"
    echo "DISABLE_SIGNUP=false"
    echo "ENABLE_EMAIL_SIGNUP=true"
    echo "ENABLE_EMAIL_AUTOCONFIRM=false"
    echo "ENABLE_ANONYMOUS_USERS=false"
    echo "ENABLE_PHONE_SIGNUP=true"
    echo "ENABLE_PHONE_AUTOCONFIRM=true"
    echo ""
    echo "# ── SMTP (leave blank to use compose defaults: supabase-mail:2500) ──"
    echo "# Uncomment and set these only if you have a real SMTP server."
    echo "#SMTP_ADMIN_EMAIL=admin@example.com"
    echo "#SMTP_HOST=supabase-mail"
    echo "#SMTP_PORT=2500"
    echo "#SMTP_USER=fake_mail_user"
    echo "#SMTP_PASS=fake_mail_password"
    echo "#SMTP_SENDER_NAME=fake_sender"
    echo "#MAILER_URLPATHS_INVITE=/auth/v1/verify"
    echo "#MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify"
    echo "#MAILER_URLPATHS_RECOVERY=/auth/v1/verify"
    echo "#MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify"
    echo ""
    echo "# ── API / PostgREST ──"
    echo "PGRST_DB_SCHEMAS="
    echo "PGRST_DB_MAX_ROWS="
    echo "PGRST_DB_EXTRA_SEARCH_PATH="
    echo ""
    echo "# ── Storage ──"
    echo "GLOBAL_S3_BUCKET="
    echo "STORAGE_TENANT_ID="
    echo "REGION="
    echo "IMGPROXY_AUTO_WEBP="
    echo ""
    echo "# ── Functions ──"
    echo "FUNCTIONS_VERIFY_JWT="
    echo ""
    echo "# ── Pooler ──"
    echo "POOLER_TENANT_ID="
    echo "POOLER_DEFAULT_POOL_SIZE="
    echo "POOLER_MAX_CLIENT_CONN="
    echo "POOLER_DB_POOL_SIZE="
    exit 0
fi

# ── Default mode: print all keys ──
echo ""
echo "JWT_SECRET=${jwt_secret}"
echo ""
echo "ANON_KEY=${anon_key}"
echo "SERVICE_ROLE_KEY=${service_role_key}"
echo ""
echo "SECRET_KEY_BASE=${secret_key_base}"
echo "REALTIME_DB_ENC_KEY=${realtime_db_enc_key}"
echo "VAULT_ENC_KEY=${vault_enc_key}"
echo "PG_META_CRYPTO_KEY=${pg_meta_crypto_key}"
echo "LOGFLARE_PUBLIC_ACCESS_TOKEN=${logflare_public_access_token}"
echo "LOGFLARE_PRIVATE_ACCESS_TOKEN=${logflare_private_access_token}"
echo "S3_PROTOCOL_ACCESS_KEY_ID=${s3_protocol_access_key_id}"
echo "S3_PROTOCOL_ACCESS_KEY_SECRET=${s3_protocol_access_key_secret}"
echo "MINIO_ROOT_PASSWORD=${minio_root_password}"
echo "SB2_AGENT_TOKEN=${sb2_agent_token}"
echo ""
echo "POSTGRES_PASSWORD=${postgres_password}"
echo "DASHBOARD_PASSWORD=${dashboard_password}"
echo ""

if [ "$1" = "--update-env" ]; then
    update_env=true
elif test -t 0; then
    printf "Update .env file? (y/N) "
    read -r REPLY
    case "$REPLY" in
        [Yy]) update_env=true ;;
        *) update_env=false ;;
    esac
else
    echo "Running non-interactively. Pass --update-env to write to .env."
    update_env=false
fi

if [ "$update_env" != "true" ]; then
    exit 0
fi

echo "Updating .env..."

sed \
    -i.old \
    -e "s|^JWT_SECRET=.*$|JWT_SECRET=${jwt_secret}|" \
    -e "s|^ANON_KEY=.*$|ANON_KEY=${anon_key}|" \
    -e "s|^SERVICE_ROLE_KEY=.*$|SERVICE_ROLE_KEY=${service_role_key}|" \
    -e "s|^SECRET_KEY_BASE=.*$|SECRET_KEY_BASE=${secret_key_base}|" \
    -e "s|^REALTIME_DB_ENC_KEY=.*$|REALTIME_DB_ENC_KEY=${realtime_db_enc_key}|" \
    -e "s|^VAULT_ENC_KEY=.*$|VAULT_ENC_KEY=${vault_enc_key}|" \
    -e "s|^PG_META_CRYPTO_KEY=.*$|PG_META_CRYPTO_KEY=${pg_meta_crypto_key}|" \
    -e "s|^LOGFLARE_PUBLIC_ACCESS_TOKEN=.*$|LOGFLARE_PUBLIC_ACCESS_TOKEN=${logflare_public_access_token}|" \
    -e "s|^LOGFLARE_PRIVATE_ACCESS_TOKEN=.*$|LOGFLARE_PRIVATE_ACCESS_TOKEN=${logflare_private_access_token}|" \
    -e "s|^S3_PROTOCOL_ACCESS_KEY_ID=.*$|S3_PROTOCOL_ACCESS_KEY_ID=${s3_protocol_access_key_id}|" \
    -e "s|^S3_PROTOCOL_ACCESS_KEY_SECRET=.*$|S3_PROTOCOL_ACCESS_KEY_SECRET=${s3_protocol_access_key_secret}|" \
    -e "s|^MINIO_ROOT_PASSWORD=.*$|MINIO_ROOT_PASSWORD=${minio_root_password}|" \
    -e "s|^POSTGRES_PASSWORD=.*$|POSTGRES_PASSWORD=${postgres_password}|" \
    -e "s|^DASHBOARD_PASSWORD=.*$|DASHBOARD_PASSWORD=${dashboard_password}|" \
    -e "s|^SB2_AGENT_TOKEN=.*$|SB2_AGENT_TOKEN=${sb2_agent_token}|" \
    .env

# SB2_AGENT_TOKEN is newly required. Older .env files won't have the line,
# so the sed replacement above is a no-op for upgraders — append it in that case.
if ! grep -q "^SB2_AGENT_TOKEN=" .env; then
    echo "SB2_AGENT_TOKEN=${sb2_agent_token}" >> .env
    echo "Appended SB2_AGENT_TOKEN to existing .env"
fi
