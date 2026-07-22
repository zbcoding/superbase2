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

// Clean up pool on process shutdown to avoid lingering connections.
// Use global to survive Next.js hot-reload module re-evaluation — a plain
// module-level `let` resets to false each time the module is re-required.
const _g = global as typeof global & { _sb2SignalsRegistered?: boolean }
if (!_g._sb2SignalsRegistered) {
  _g._sb2SignalsRegistered = true
  for (const signal of ['SIGTERM', 'SIGINT'] as const) {
    process.on(signal, () => {
      if (_adminPool) {
        _adminPool.end().catch(() => {})
        _adminPool = null
      }
    })
  }
}

function getAdminPool(): Pool {
  if (!process.env.POSTGRES_PASSWORD) {
    throw new Error('[SuperBase²] POSTGRES_PASSWORD environment variable is required')
  }
  if (!_adminPool) {
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

/**
 * Test Postgres connectivity. Call before project creation to fail fast
 * with a clear error instead of a confusing pool timeout.
 */
export async function checkPostgresConnection(): Promise<void> {
  const pool = getAdminPool()
  const client = await pool.connect()
  try {
    await client.query('SELECT 1')
  } finally {
    client.release()
  }
}

// Validation constants — keep in sync with isValidProjectName() and superbase2.sh
export const MAX_PROJECT_NAME_LENGTH = 48
export const MAX_DB_NAME_LENGTH = 63 // Postgres identifier limit
// project_ prefix (8 chars) + MAX_PROJECT_NAME_LENGTH (48) = 56, well under 63

/** Passwords are generated as hex (see generateProjectSecrets), so they are safe
 *  to interpolate into DDL and need no escaping in a connection string. */
export function isValidDbPassword(password: string): boolean {
  return /^[a-f0-9]{32,128}$/.test(password)
}

/**
 * Create (or repair) the project's own login role.
 *
 * Deliberately holds no cluster-level memberships. anon/authenticated/service_role
 * have CONNECT on every project database, so membership would let one project's
 * credential open every other project's — and pg_read_all_data (which upstream
 * grants `postgres`) would let it read the main `postgres` database. Read access
 * to the service-managed schemas is granted per-database instead, below.
 */
export async function createProjectRole(roleName: string, password: string): Promise<void> {
  if (!/^[a-zA-Z0-9_]+$/.test(roleName) || roleName.length > MAX_DB_NAME_LENGTH) {
    throw new Error(`Invalid role name: '${roleName}'`)
  }
  if (!isValidDbPassword(password)) {
    throw new Error('Invalid database password: must be 32-128 lowercase hex characters')
  }

  const pool = getAdminPool()
  try {
    await pool.query(`CREATE ROLE "${roleName}" LOGIN INHERIT BYPASSRLS PASSWORD '${password}'`)
  } catch (err: any) {
    // Role already exists — reset its password instead. This is also the
    // rotation path, so it must stay idempotent.
    if (err.code !== '42710') throw err
    await pool.query(`ALTER ROLE "${roleName}" WITH LOGIN INHERIT BYPASSRLS PASSWORD '${password}'`)
  }
  // No CREATEROLE / CREATEDB / REPLICATION: upstream's `postgres` role has them,
  // but roles and databases are cluster-global and a project must not reach
  // outside its own database.
  await pool.query(`ALTER ROLE "${roleName}" SET search_path TO "$user", public, extensions`)
}

export async function createProjectDatabase(
  dbName: string,
  jwtSecret: string,
  dbPassword: string,
  jwtExp: string = '3600'
): Promise<void> {
  // Validate the database name strictly — reject anything unexpected
  // rather than silently transforming it (which can cause collisions).
  if (!/^[a-zA-Z0-9_]+$/.test(dbName) || dbName.length < 2 || dbName.length > MAX_DB_NAME_LENGTH) {
    throw new Error(
      `Invalid database name: '${dbName}'. Only letters, numbers, and underscores are allowed (2-${MAX_DB_NAME_LENGTH} chars).`
    )
  }
  const safeName = dbName

  if (!/^\d+$/.test(jwtExp)) {
    throw new Error(`Invalid JWT expiry: must be numeric, got '${jwtExp}'`)
  }

  const pool = getAdminPool()

  // The project's own login role — same name as the database. It owns the
  // database, so the connection string we hand out authenticates as a role
  // that can CREATE in public and ALTER/DROP its own tables. Creating the
  // database without an explicit OWNER makes supabase_admin the owner and
  // leaves the connecting role unable to create anything.
  await createProjectRole(safeName, dbPassword)

  try {
    // Can't use parameterized queries for DDL. safeName is validated above and
    // the role name is identical to it.
    await pool.query(`CREATE DATABASE "${safeName}" OWNER "${safeName}"`)
  } catch (err: any) {
    // Database already exists — take ownership so re-provisioning repairs it.
    if (err.code !== '42P04') throw err
    await pool.query(`ALTER DATABASE "${safeName}" OWNER TO "${safeName}"`)
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
      // Use dollar-quoting for DDL string literals — base64 alphabet ([A-Za-z0-9+/=])
      // cannot contain '$', so the $sb2$ delimiter can never appear in the value.
      // This prevents injection even if the regex check above were somehow bypassed.
      await client.query(
        `ALTER DATABASE "${safeName}" SET "app.settings.jwt_secret" TO $sb2$${jwtSecret}$sb2$`
      )
      // jwtExp is already validated as numeric-only above, so interpolation is safe.
      await client.query(`ALTER DATABASE "${safeName}" SET "app.settings.jwt_exp" TO '${jwtExp}'`)

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

        -- PGRST_DB_SCHEMAS lists graphql_public, and PostgREST fails to start if
        -- a listed schema is missing. superbase2.sh creates it; this path did
        -- not, so UI-created projects diverged from CLI-created ones.
        CREATE SCHEMA IF NOT EXISTS graphql_public;
        GRANT USAGE ON SCHEMA graphql_public TO anon, authenticated, service_role;

        -- public is owned by pg_database_owner, which resolves to the project
        -- role now that it owns the database. Reassert it: a database created
        -- by an earlier sb2 version can have public owned by supabase_admin
        -- directly, and then database ownership alone does not grant CREATE.
        ALTER SCHEMA public OWNER TO pg_database_owner;

        -- Public schema grants
        GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

        -- The grants above only cover objects created by supabase_admin (the
        -- role running this). Tables the user creates over DATABASE_URL, or
        -- that pg-meta creates for the table editor, are owned by the project
        -- role — without these, PostgREST cannot see any of them.
        ALTER DEFAULT PRIVILEGES FOR ROLE "${safeName}" IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES FOR ROLE "${safeName}" IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES FOR ROLE "${safeName}" IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

        -- Read access to the service-managed schemas, so the SQL editor and
        -- pg-meta (both connect as the project role) can browse auth.users and
        -- storage.objects. Scoped to this database rather than granted via
        -- pg_read_all_data, which would also expose the main postgres database.
        -- The tables do not exist yet — GoTrue and Storage create them on their
        -- first run — so the default-privilege grants are what actually apply.
        GRANT USAGE ON SCHEMA auth, storage TO "${safeName}";
        ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT SELECT ON TABLES TO "${safeName}";
        ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT SELECT ON TABLES TO "${safeName}";

        -- Confine this project's credential to this project's database.
        -- PUBLIC holds CONNECT by default, which would make the per-project
        -- password meaningless for isolation.
        REVOKE CONNECT ON DATABASE "${safeName}" FROM PUBLIC;

        -- Service roles need CONNECT privilege on non-default databases.
        -- Without this, PostgREST (authenticator) and Storage (supabase_storage_admin) fail to connect.
        GRANT ALL ON DATABASE "${safeName}" TO supabase_storage_admin;
        GRANT ALL ON DATABASE "${safeName}" TO supabase_auth_admin;
        GRANT ALL ON DATABASE "${safeName}" TO postgres;
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
        -- The project role is not a member of those roles, so it needs its own
        -- grant — without it uuid_generate_v4() and friends are unresolvable
        -- over DATABASE_URL even though they are on the search_path.
        GRANT USAGE ON SCHEMA extensions TO "${safeName}";
        GRANT USAGE ON SCHEMA graphql_public TO "${safeName}";
      `)
    } finally {
      client.release()
    }
  } finally {
    await projectPool.end()
  }
}

/** Validate that a project name is safe for use in identifiers and file paths.
 *  Only alphanumeric characters allowed — no hyphens, no underscores.
 *  Underscores are excluded because Docker DNS does not support them in hostnames
 *  (RFC 1123), which would break per-project container resolution (e.g. meta-<name>).
 *  Keep in sync with superbase2.sh cmd_create validation. */
export function isValidProjectName(name: string): boolean {
  return /^[a-zA-Z0-9]+$/.test(name) && name.length >= 2 && name.length <= MAX_PROJECT_NAME_LENGTH
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
  // Roles are cluster-global, so dropping the database leaves the login role
  // behind. Nothing outside this database can be owned by it (it was never
  // granted CONNECT anywhere else), so a plain DROP ROLE is enough.
  try {
    await pool.query(`DROP ROLE IF EXISTS "${safeName}"`)
  } catch (err) {
    // Pre-migration projects have no role, and a role still owning objects
    // elsewhere is not worth failing the delete over.
    console.error(`[SuperBase²] could not drop role '${safeName}':`, err)
  }
}
