# Auto-generated docker-compose for project: {{PROJECT_NAME}}
# This file is managed by SuperBase² (superbase2.sh) — do not edit manually.

services:

  auth-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-auth
    image: supabase/gotrue:${GOTRUE_VERSION:-v2.186.0}
    restart: unless-stopped
    networks:
      - supabase_default
    healthcheck:
      test:
        [
          "CMD",
          "wget",
          "--no-verbose",
          "--tries=1",
          "--spider",
          "http://localhost:9999/health"
        ]
      timeout: 5s
      interval: 5s
      retries: 3
    environment:
      GOTRUE_API_HOST: 0.0.0.0
      GOTRUE_API_PORT: 9999
      API_EXTERNAL_URL: ${API_EXTERNAL_URL}

      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://supabase_auth_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/{{PROJECT_DB}}

      GOTRUE_SITE_URL: ${SITE_URL}
      GOTRUE_URI_ALLOW_LIST: ${ADDITIONAL_REDIRECT_URLS}
      GOTRUE_DISABLE_SIGNUP: ${DISABLE_SIGNUP}

      GOTRUE_JWT_ADMIN_ROLES: service_role
      GOTRUE_JWT_AUD: authenticated
      GOTRUE_JWT_DEFAULT_GROUP_NAME: authenticated
      GOTRUE_JWT_EXP: ${JWT_EXPIRY}
      GOTRUE_JWT_SECRET: ${PROJECT_JWT_SECRET}

      GOTRUE_EXTERNAL_EMAIL_ENABLED: ${ENABLE_EMAIL_SIGNUP}
      GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED: ${ENABLE_ANONYMOUS_USERS}
      GOTRUE_MAILER_AUTOCONFIRM: ${ENABLE_EMAIL_AUTOCONFIRM}

      # `:-default` (not `-default`) so empty values from the calling shell
      # don't override the .env. Coolify exports SMTP_* as empty strings,
      # and shell-env beats --env-file in Compose interpolation — empty
      # SMTP_PORT crashes GoTrue (cannot parse "" as int).
      GOTRUE_SMTP_ADMIN_EMAIL: ${SMTP_ADMIN_EMAIL:-admin@example.com}
      GOTRUE_SMTP_HOST: ${SMTP_HOST:-supabase-mail}
      GOTRUE_SMTP_PORT: ${SMTP_PORT:-2500}
      GOTRUE_SMTP_USER: ${SMTP_USER:-fake_mail_user}
      GOTRUE_SMTP_PASS: ${SMTP_PASS:-fake_mail_password}
      GOTRUE_SMTP_SENDER_NAME: ${SMTP_SENDER_NAME:-fake_sender}
      GOTRUE_MAILER_URLPATHS_INVITE: ${MAILER_URLPATHS_INVITE}
      GOTRUE_MAILER_URLPATHS_CONFIRMATION: ${MAILER_URLPATHS_CONFIRMATION}
      GOTRUE_MAILER_URLPATHS_RECOVERY: ${MAILER_URLPATHS_RECOVERY}
      GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE: ${MAILER_URLPATHS_EMAIL_CHANGE}

      GOTRUE_EXTERNAL_PHONE_ENABLED: ${ENABLE_PHONE_SIGNUP}
      GOTRUE_SMS_AUTOCONFIRM: ${ENABLE_PHONE_AUTOCONFIRM}

  rest-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-rest
    image: postgrest/postgrest:${POSTGREST_VERSION:-v14.5}
    restart: unless-stopped
    networks:
      - supabase_default
    environment:
      PGRST_DB_URI: postgres://authenticator:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/{{PROJECT_DB}}
      PGRST_DB_SCHEMAS: ${PGRST_DB_SCHEMAS:-public,storage,graphql_public}
      PGRST_DB_MAX_ROWS: ${PGRST_DB_MAX_ROWS:-1000}
      PGRST_DB_EXTRA_SEARCH_PATH: ${PGRST_DB_EXTRA_SEARCH_PATH:-public}
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: ${PROJECT_JWT_SECRET}
      PGRST_DB_USE_LEGACY_GUCS: "false"
      PGRST_APP_SETTINGS_JWT_SECRET: ${PROJECT_JWT_SECRET}
      PGRST_APP_SETTINGS_JWT_EXP: ${JWT_EXPIRY}
    command:
      [
        "postgrest"
      ]

  realtime-{{PROJECT_NAME}}:
    # Container name includes tenant ID — Realtime parses subdomain for tenant
    container_name: realtime-{{PROJECT_NAME}}.supabase-realtime
    image: supabase/realtime:${REALTIME_VERSION:-v2.76.5}
    restart: unless-stopped
    networks:
      - supabase_default
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -sSfL --head -o /dev/null -H \"Authorization: Bearer ${PROJECT_ANON_KEY}\" http://realtime-{{PROJECT_NAME}}:4000/api/tenants/realtime-{{PROJECT_NAME}}/health"
        ]
      timeout: 5s
      interval: 30s
      retries: 3
      start_period: 10s
    environment:
      PORT: 4000
      DB_HOST: ${POSTGRES_HOST}
      DB_PORT: ${POSTGRES_PORT}
      DB_USER: supabase_admin
      DB_PASSWORD: ${POSTGRES_PASSWORD}
      DB_NAME: "{{PROJECT_DB}}"
      DB_AFTER_CONNECT_QUERY: 'SET search_path TO _realtime'
      DB_ENC_KEY: ${PROJECT_DB_ENC_KEY}
      API_JWT_SECRET: ${PROJECT_JWT_SECRET}
      SECRET_KEY_BASE: ${PROJECT_SECRET_KEY_BASE}
      ERL_AFLAGS: -proto_dist inet_tcp
      DNS_NODES: "''"
      RLIMIT_NOFILE: "10000"
      APP_NAME: realtime
      SEED_SELF_HOST: "true"
      SEED_SELF_HOST_EXTERNAL_ID: "realtime-{{PROJECT_NAME}}"
      RUN_JANITOR: "true"
      DISABLE_HEALTHCHECK_LOGGING: "true"

  storage-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-storage
    image: supabase/storage-api:${STORAGE_VERSION:-v1.37.8}
    restart: unless-stopped
    networks:
      - supabase_default
    healthcheck:
      test:
        [
          "CMD",
          "wget",
          "--no-verbose",
          "--tries=1",
          "--spider",
          "http://storage-{{PROJECT_NAME}}:5000/status"
        ]
      timeout: 5s
      interval: 5s
      retries: 3
    environment:
      ANON_KEY: ${PROJECT_ANON_KEY}
      SERVICE_KEY: ${PROJECT_SERVICE_ROLE_KEY}
      POSTGREST_URL: http://rest-{{PROJECT_NAME}}:3000
      AUTH_JWT_SECRET: ${PROJECT_JWT_SECRET}
      DATABASE_URL: postgres://supabase_storage_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/{{PROJECT_DB}}
      REQUEST_ALLOW_X_FORWARDED_PATH: "true"
      FILE_SIZE_LIMIT: 52428800
      STORAGE_BACKEND: file
      GLOBAL_S3_BUCKET: ${GLOBAL_S3_BUCKET:-stub}
      FILE_STORAGE_BACKEND_PATH: /var/lib/storage
      TENANT_ID: ${STORAGE_TENANT_ID:-{{PROJECT_NAME}}}
      REGION: ${REGION:-local}
      ENABLE_IMAGE_TRANSFORMATION: "true"
      IMGPROXY_URL: http://supabase-imgproxy:5001
      S3_PROTOCOL_ACCESS_KEY_ID: ${PROJECT_S3_ACCESS_KEY_ID}
      S3_PROTOCOL_ACCESS_KEY_SECRET: ${PROJECT_S3_ACCESS_KEY_SECRET}
    volumes:
      - storage-{{PROJECT_NAME}}:/var/lib/storage

  meta-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-meta
    image: supabase/postgres-meta:${POSTGRES_META_VERSION:-v0.95.2}
    restart: unless-stopped
    networks:
      - supabase_default
    environment:
      PG_META_PORT: 8080
      PG_META_DB_HOST: ${POSTGRES_HOST}
      PG_META_DB_PORT: ${POSTGRES_PORT}
      PG_META_DB_NAME: "{{PROJECT_DB}}"
      PG_META_DB_USER: supabase_admin
      PG_META_DB_PASSWORD: ${POSTGRES_PASSWORD}
      CRYPTO_KEY: ${PROJECT_PG_META_CRYPTO_KEY}

  functions-init-{{PROJECT_NAME}}:
    image: alpine:3.19
    restart: "no"
    volumes:
      - functions-{{PROJECT_NAME}}:/functions
    entrypoint: /bin/sh
    command:
      - -c
      - |
        mkdir -p /functions/main
        if [ ! -f /functions/main/index.ts ]; then
          cat > /functions/main/index.ts <<'EOFUNC'
        import { serve } from "https://deno.land/std/http/server.ts"
        serve(() => new Response("ok"))
        EOFUNC
          echo "[functions-init] seeded stub main/index.ts"
        fi

  functions-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-functions
    image: supabase/edge-runtime:${EDGE_RUNTIME_VERSION:-v1.70.3}
    restart: unless-stopped
    networks:
      - supabase_default
    depends_on:
      functions-init-{{PROJECT_NAME}}:
        condition: service_completed_successfully
    volumes:
      - functions-{{PROJECT_NAME}}:/home/deno/functions
    environment:
      JWT_SECRET: ${PROJECT_JWT_SECRET}
      SUPABASE_URL: http://supabase-kong:8000
      SUPABASE_PUBLIC_URL: ${SUPABASE_PUBLIC_URL}
      SUPABASE_ANON_KEY: ${PROJECT_ANON_KEY}
      SUPABASE_SERVICE_ROLE_KEY: ${PROJECT_SERVICE_ROLE_KEY}
      SUPABASE_DB_URL: postgresql://postgres:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/{{PROJECT_DB}}
      VERIFY_JWT: "${FUNCTIONS_VERIFY_JWT}"
    command:
      [
        "start",
        "--main-service",
        "/home/deno/functions/main"
      ]

networks:
  supabase_default:
    external: true
    name: ${SUPABASE_NETWORK_NAME:-supabase_default}

volumes:
  storage-{{PROJECT_NAME}}:
  functions-{{PROJECT_NAME}}:
