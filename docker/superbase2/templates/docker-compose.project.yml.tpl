# Auto-generated docker-compose for project: {{PROJECT_NAME}}
# This file is managed by SuperBase² (superbase2.sh) — do not edit manually.

services:

  auth-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-auth
    image: supabase/gotrue:v2.186.0
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

      GOTRUE_SMTP_ADMIN_EMAIL: ${SMTP_ADMIN_EMAIL}
      GOTRUE_SMTP_HOST: ${SMTP_HOST}
      GOTRUE_SMTP_PORT: ${SMTP_PORT}
      GOTRUE_SMTP_USER: ${SMTP_USER}
      GOTRUE_SMTP_PASS: ${SMTP_PASS}
      GOTRUE_SMTP_SENDER_NAME: ${SMTP_SENDER_NAME}
      GOTRUE_MAILER_URLPATHS_INVITE: ${MAILER_URLPATHS_INVITE}
      GOTRUE_MAILER_URLPATHS_CONFIRMATION: ${MAILER_URLPATHS_CONFIRMATION}
      GOTRUE_MAILER_URLPATHS_RECOVERY: ${MAILER_URLPATHS_RECOVERY}
      GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE: ${MAILER_URLPATHS_EMAIL_CHANGE}

      GOTRUE_EXTERNAL_PHONE_ENABLED: ${ENABLE_PHONE_SIGNUP}
      GOTRUE_SMS_AUTOCONFIRM: ${ENABLE_PHONE_AUTOCONFIRM}

  rest-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-rest
    image: postgrest/postgrest:v14.5
    restart: unless-stopped
    networks:
      - supabase_default
    environment:
      PGRST_DB_URI: postgres://authenticator:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/{{PROJECT_DB}}
      PGRST_DB_SCHEMAS: ${PGRST_DB_SCHEMAS}
      PGRST_DB_MAX_ROWS: ${PGRST_DB_MAX_ROWS}
      PGRST_DB_EXTRA_SEARCH_PATH: ${PGRST_DB_EXTRA_SEARCH_PATH}
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
    image: supabase/realtime:v2.76.5
    restart: unless-stopped
    networks:
      - supabase_default
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -sSfL --head -o /dev/null -H \"Authorization: Bearer ${PROJECT_ANON_KEY}\" http://localhost:4000/api/tenants/realtime-{{PROJECT_NAME}}/health"
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
      DB_NAME: {{PROJECT_DB}}
      DB_AFTER_CONNECT_QUERY: 'SET search_path TO _realtime'
      DB_ENC_KEY: supabaserealtime
      API_JWT_SECRET: ${PROJECT_JWT_SECRET}
      SECRET_KEY_BASE: ${PROJECT_SECRET_KEY_BASE}
      ERL_AFLAGS: -proto_dist inet_tcp
      DNS_NODES: "''"
      RLIMIT_NOFILE: "10000"
      APP_NAME: realtime
      SEED_SELF_HOST: "true"
      RUN_JANITOR: "true"
      DISABLE_HEALTHCHECK_LOGGING: "true"

  storage-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-storage
    image: supabase/storage-api:v1.37.8
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
          "http://localhost:5000/status"
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
      GLOBAL_S3_BUCKET: ${GLOBAL_S3_BUCKET}
      FILE_STORAGE_BACKEND_PATH: /var/lib/storage
      TENANT_ID: ${STORAGE_TENANT_ID}
      REGION: ${REGION}
      ENABLE_IMAGE_TRANSFORMATION: "true"
      IMGPROXY_URL: http://supabase-imgproxy:5001
      S3_PROTOCOL_ACCESS_KEY_ID: ${PROJECT_S3_ACCESS_KEY_ID}
      S3_PROTOCOL_ACCESS_KEY_SECRET: ${PROJECT_S3_ACCESS_KEY_SECRET}
    volumes:
      - ./volumes/storage-{{PROJECT_NAME}}:/var/lib/storage:z

  meta-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-meta
    image: supabase/postgres-meta:v0.95.2
    restart: unless-stopped
    networks:
      - supabase_default
    environment:
      PG_META_PORT: 8080
      PG_META_DB_HOST: ${POSTGRES_HOST}
      PG_META_DB_PORT: ${POSTGRES_PORT}
      PG_META_DB_NAME: {{PROJECT_DB}}
      PG_META_DB_USER: supabase_admin
      PG_META_DB_PASSWORD: ${POSTGRES_PASSWORD}
      CRYPTO_KEY: ${PROJECT_PG_META_CRYPTO_KEY}

  functions-{{PROJECT_NAME}}:
    container_name: supabase-{{PROJECT_NAME}}-functions
    image: supabase/edge-runtime:v1.70.3
    restart: unless-stopped
    networks:
      - supabase_default
    volumes:
      - ./volumes/functions:/home/deno/functions:Z
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
