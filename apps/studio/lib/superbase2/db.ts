/**
 * SuperBase² — database provisioning.
 *
 * Creates a new Postgres database with the required schemas and
 * role grants that Supabase services expect.
 *
 * We use the 'pg' npm package directly here instead of going through
 * Supabase's existing pg-meta service or modifying their code. This is
 * intentional: SuperBase² files live in their own directories so upstream
 * Supabase updates never cause merge conflicts. The only upstream change
 * is an additive "pg" line in package.json which auto-merges cleanly.
 */

import { Pool } from 'pg'

// Module-level pool reused across calls. Lazily created on first use.
let _adminPool: Pool | null = null

// Clean up pool on process shutdown to avoid lingering connections
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    if (_adminPool) {
      _adminPool.end().catch(() => {})
      _adminPool = null
    }
  })
}

function getAdminPool(): Pool {
  if (!_adminPool) {
    if (!process.env.POSTGRES_PASSWORD) {
      throw new Error('POSTGRES_PASSWORD environment variable is required for SuperBase²')
    }
    _adminPool = new Pool({
      host: process.env.POSTGRES_HOST || 'db',
      port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
      user: 'supabase_admin',
      password: process.env.POSTGRES_PASSWORD,
      database: 'postgres',
      max: 3,
      idleTimeoutMillis: 30_000,
    })
  }
  return _adminPool
}

// Validation constants — keep in sync with isValidProjectName() and superbase2.sh
export const MAX_PROJECT_NAME_LENGTH = 48
export const MAX_DB_NAME_LENGTH = 63 // Postgres identifier limit
// project_ prefix (8 chars) + MAX_PROJECT_NAME_LENGTH (48) = 56, well under 63

export async function createProjectDatabase(
  dbName: string,
  jwtSecret: string,
  jwtExp: string = '3600'
): Promise<void> {
  // Validate the database name strictly — reject anything unexpected
  // rather than silently transforming it (which can cause collisions).
  if (!/^[a-zA-Z0-9_]+$/.test(dbName) || dbName.length < 2 || dbName.length > MAX_DB_NAME_LENGTH) {
    throw new Error(`Invalid database name: '${dbName}'. Only letters, numbers, and underscores are allowed (2-${MAX_DB_NAME_LENGTH} chars).`)
  }
  const safeName = dbName

  if (!/^\d+$/.test(jwtExp)) {
    throw new Error(`Invalid JWT expiry: must be numeric, got '${jwtExp}'`)
  }

  const pool = getAdminPool()

  try {
    // Create database (can't use parameterized queries for DDL)
    await pool.query(`CREATE DATABASE "${safeName}"`)
  } catch (err: any) {
    // Database already exists — acceptable
    if (err.code !== '42P04') throw err
  }

  // Connect to the new database to set up schemas.
  // This is a short-lived pool for the target DB — can't reuse the admin pool
  // since it's connected to the 'postgres' database.
  const projectPool = new Pool({
    host: process.env.POSTGRES_HOST || 'db',
    port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
    user: 'supabase_admin',
    password: process.env.POSTGRES_PASSWORD,
    database: safeName,
    max: 2,
    idleTimeoutMillis: 5000,
  })

  try {
    const client = await projectPool.connect()
    try {
      // Use direct ALTER DATABASE SET TO — simpler and doesn't depend on
      // session state like the set_config + FROM CURRENT approach.
      // DDL statements don't support $1 parameters, so we validate strictly
      // before interpolation: jwtSecret must be base64 (the only format we
      // generate), and jwtExp is already validated as numeric-only above.
      if (!/^[A-Za-z0-9+/=]+$/.test(jwtSecret)) {
        throw new Error('Invalid JWT secret: must be base64-encoded')
      }
      const safeJwtSecret = jwtSecret.replace(/'/g, "''")
      await client.query(
        `ALTER DATABASE "${safeName}" SET "app.settings.jwt_secret" TO '${safeJwtSecret}'`
      )
      await client.query(
        `ALTER DATABASE "${safeName}" SET "app.settings.jwt_exp" TO '${jwtExp}'`
      )

      await client.query(`
        -- Realtime schema
        CREATE SCHEMA IF NOT EXISTS _realtime;
        ALTER SCHEMA _realtime OWNER TO postgres;

        -- Storage schema
        CREATE SCHEMA IF NOT EXISTS storage;
        GRANT ALL ON SCHEMA storage TO postgres;
        GRANT ALL ON SCHEMA storage TO supabase_storage_admin;
        GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;

        -- Auth schema
        CREATE SCHEMA IF NOT EXISTS auth;
        GRANT ALL ON SCHEMA auth TO supabase_auth_admin;
        GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

        -- Public schema grants
        GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

        -- Service roles need CONNECT privilege on non-default databases.
        -- Without this, PostgREST (authenticator) and Storage (supabase_storage_admin) fail to connect.
        GRANT ALL ON DATABASE "${safeName}" TO supabase_storage_admin;
        GRANT ALL ON DATABASE "${safeName}" TO supabase_auth_admin;
        GRANT CONNECT ON DATABASE "${safeName}" TO authenticator;
        GRANT CONNECT ON DATABASE "${safeName}" TO anon;
        GRANT CONNECT ON DATABASE "${safeName}" TO authenticated;
        GRANT CONNECT ON DATABASE "${safeName}" TO service_role;
      `)

      // Ensure extensions schema exists before creating extensions
      await client.query(`CREATE SCHEMA IF NOT EXISTS extensions`)

      // Extensions — these may or may not exist depending on the Postgres image
      const extensions = ['uuid-ossp', 'pgcrypto', 'pgjwt']
      for (const ext of extensions) {
        try {
          await client.query(`CREATE EXTENSION IF NOT EXISTS "${ext}" WITH SCHEMA extensions`)
        } catch {
          // Extension not available — non-fatal
        }
      }

      // Add extensions schema to the default search_path so functions like
      // uuid_generate_v4() work without schema-qualifying them.
      await client.query(`
        ALTER DATABASE "${safeName}" SET search_path TO "$user", public, extensions;
        GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
      `)
    } finally {
      client.release()
    }
  } finally {
    await projectPool.end()
  }
}

/** Validate that a project name is safe for use in identifiers and file paths.
 *  Only alphanumeric + underscores allowed — no hyphens.
 *  This must match createProjectDatabase/dropProjectDatabase validation
 *  to prevent collisions (e.g. "my-app" and "my_app" → same DB name).
 *  Keep in sync with superbase2.sh cmd_create validation. */
export function isValidProjectName(name: string): boolean {
  return /^[a-zA-Z0-9_]+$/.test(name) && name.length >= 2 && name.length <= MAX_PROJECT_NAME_LENGTH
}

export async function dropProjectDatabase(dbName: string): Promise<void> {
  if (!/^[a-zA-Z0-9_]+$/.test(dbName) || dbName.length < 2 || dbName.length > MAX_DB_NAME_LENGTH) {
    throw new Error(`Invalid database name: '${dbName}'.`)
  }
  const safeName = dbName
  const pool = getAdminPool()
  // Terminate existing connections — use parameterized query for the WHERE value
  await pool.query(
    `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()`,
    [safeName]
  )
  await pool.query(`DROP DATABASE IF EXISTS "${safeName}"`)
}
