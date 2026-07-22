/**
 * Helpers that transform MultiProject records into the response shapes
 * that Studio's existing React Query hooks expect.
 *
 * We match the exact shapes from the Supabase Cloud API so the existing
 * UI components work without modification.
 */

import type { NextApiRequest } from 'next'

import type { MultiProject } from './projects'

function getPublicUrl(): URL {
  return new URL(process.env.SUPABASE_PUBLIC_URL || 'http://localhost:8000')
}

function getDbVersion(): string {
  return process.env.POSTGRES_MAJOR_VERSION || '15'
}

/** Clamp pagination params to safe ranges. */
export function clampPagination(
  req: NextApiRequest,
  defaults: { limit: number; offset: number } = { limit: 100, offset: 0 }
) {
  // Next.js can parse repeated query params as string[], pick the first element.
  const limitStr = Array.isArray(req.query.limit) ? req.query.limit[0] : req.query.limit
  const offsetStr = Array.isArray(req.query.offset) ? req.query.offset[0] : req.query.offset
  // Use ?? instead of || so that an explicit limit=0 is clamped to 1 rather than
  // falling back to the default (parseInt("0") is 0, which is falsy with ||).
  const parsedLimit = parseInt(limitStr ?? String(defaults.limit), 10)
  const limit = Math.min(
    Math.max(Number.isFinite(parsedLimit) ? parsedLimit : defaults.limit, 1),
    500
  )
  const offset = Math.max(parseInt(offsetStr || String(defaults.offset), 10) || 0, 0)
  return { limit, offset }
}

export const DEFAULT_ORG_SLUG = 'default-org-slug'

function getOrg() {
  return {
    id: 1,
    name: process.env.DEFAULT_ORGANIZATION_NAME || 'Default Organization',
    slug: DEFAULT_ORG_SLUG,
    billing_email: 'billing@localhost',
    plan: { id: 'enterprise', name: 'Enterprise' },
  }
}

/** Shape expected by useProjectDetailQuery / GET /platform/projects/{ref} */
export function toProjectDetail(p: MultiProject) {
  const publicUrl = getPublicUrl()
  return {
    id: hashCode(p.ref),
    ref: p.ref,
    name: p.name,
    organization_id: getOrg().id,
    cloud_provider: 'localhost',
    status: p.status || 'ACTIVE_HEALTHY',
    region: 'local',
    inserted_at: p.created_at,
    updated_at: p.created_at,
    connectionString: '',
    restUrl: `${publicUrl.origin}/project/${p.ref}/rest/v1/`,
    db_host: process.env.POSTGRES_HOST || 'db',
    db_name: p.db,
    db_port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
    db_user: toDbUser(p),
    dbVersion: getDbVersion(),
    is_branch_enabled: false,
    is_physical_backups_enabled: false,
    subscription_id: '',
    databases: [
      {
        identifier: p.ref,
        host: process.env.POSTGRES_HOST || 'db',
        version: getDbVersion(),
        infra_compute_size: 'nano',
        status: 'ACTIVE_HEALTHY',
      },
    ],
  }
}

/** Shape expected by GET /platform/projects/{ref}/databases */
export function toDatabasesResponse(p: MultiProject) {
  const publicUrl = getPublicUrl()
  return [
    {
      cloud_provider: 'localhost' as string,
      connectionString: '',
      connection_string_read_only: '',
      db_host: process.env.POSTGRES_HOST || 'db',
      db_name: p.db,
      db_port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
      db_user: toDbUser(p),
      identifier: p.ref,
      inserted_at: p.created_at || '',
      region: 'local',
      restUrl: `${publicUrl.origin}/project/${p.ref}/rest/v1/`,
      size: '',
      status: 'ACTIVE_HEALTHY',
    },
  ]
}

/** Shape expected by GET /platform/projects/{ref}/settings.
 *  Includes jwt_secret and service_role_key — Studio needs these to configure
 *  PostgREST and display API settings. Only call from authenticated API routes. */
export function toSettingsResponse(p: MultiProject) {
  const publicUrl = getPublicUrl()
  // SB2 routes per-project traffic through Kong as `/project/<ref>/...`.
  // Embed the prefix in the endpoint so browser SDKs (storage uploads,
  // realtime, etc.) build URLs against the per-project route, not the
  // bare main-stack origin.
  const projectHost = `${publicUrl.host}/project/${p.ref}`
  return {
    app_config: {
      db_schema: 'public',
      endpoint: projectHost,
      storage_endpoint: projectHost,
      protocol: publicUrl.protocol.replace(':', ''),
    },
    cloud_provider: 'localhost',
    db_dns_name: '-',
    db_host: process.env.POSTGRES_HOST || 'db',
    db_ip_addr_config: 'legacy' as const,
    db_name: p.db,
    db_port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
    db_user: toDbUser(p),
    inserted_at: p.created_at || '',
    jwt_secret: p.jwt_secret,
    name: p.name,
    ref: p.ref,
    region: 'local',
    service_api_keys: [
      {
        api_key: p.service_role_key,
        name: 'service_role key',
        tags: 'service_role',
      },
      {
        api_key: p.anon_key,
        name: 'anon key',
        tags: 'anon',
      },
    ],
    ssl_enforced: false,
    status: p.status || 'ACTIVE_HEALTHY',
  }
}

/**
 * Direct Postgres connection string for the project.
 *
 * Authenticates as the project's own login role (named after the database),
 * which owns the database — so this credential can CREATE in `public` and
 * ALTER/DROP the project's own tables, and cannot open any other project's
 * database. Rotating it is `superbase2.sh rotate-keys`.
 *
 * Projects created before per-project roles existed have no `db_password` and
 * fall back to the old shared-superuser placeholder until
 * `superbase2.sh migrate-db-owner <name>` has been run for them.
 *
 * POSTGRES_HOST is the Docker service name (`db`), so this address resolves only
 * from containers on the Supabase network — edge functions, or an app deployed
 * alongside the stack. The db service publishes no host port by default, so a
 * client outside Docker cannot use this string as-is; it needs a published port
 * or a pooler in front, and then the host swapped for the server's address.
 */
export function toDbUrlTemplate(p: MultiProject) {
  const host = process.env.POSTGRES_HOST || 'db'
  const port = process.env.POSTGRES_PORT || '5432'
  if (!p.db_password) {
    return `postgresql://postgres:[POSTGRES_PASSWORD]@${host}:${port}/${p.db}`
  }
  return `postgresql://${p.db}:${p.db_password}@${host}:${port}/${p.db}`
}

/** The role a client authenticates as over toDbUrlTemplate(). */
export function toDbUser(p: MultiProject) {
  return p.db_password ? p.db : 'postgres'
}

/** Full project detail including secrets — only returned on project creation.
 *  The UI shows these once and instructs the user to save them. */
export function toCreationResponse(p: MultiProject) {
  return {
    ...toProjectDetail(p),
    jwt_secret: p.jwt_secret,
    anon_key: p.anon_key,
    service_role_key: p.service_role_key,
    db_url: toDbUrlTemplate(p),
  }
}

/** Shape expected by GET /platform/projects/{ref}/config/postgrest */
export function toPostgrestConfigResponse(p: MultiProject) {
  return {
    db_anon_role: 'anon',
    db_extra_search_path: process.env.PGRST_DB_EXTRA_SEARCH_PATH ?? 'public',
    db_schema: process.env.PGRST_DB_SCHEMAS ?? 'public,storage,graphql_public',
    jwt_secret: p.jwt_secret,
    max_rows:
      process.env.PGRST_DB_MAX_ROWS !== undefined
        ? parseInt(process.env.PGRST_DB_MAX_ROWS, 10) || 1000
        : 1000,
    role_claim_key: '.role',
  }
}

/** Shape expected by useOrgProjectsInfiniteQuery / GET /platform/organizations/{slug}/projects */
export function toOrgProjectsResponse(
  projects: MultiProject[],
  {
    limit = 96,
    offset = 0,
    search,
    sort,
  }: {
    limit?: number
    offset?: number
    search?: string
    sort?: string
  } = {}
) {
  let filtered = [...projects]

  if (search) {
    const q = search.toLowerCase()
    filtered = filtered.filter(
      (p) => p.name.toLowerCase().includes(q) || p.ref.toLowerCase().includes(q)
    )
  }

  if (sort) {
    filtered.sort((a, b) => {
      switch (sort) {
        case 'name_asc':
          return a.name.localeCompare(b.name)
        case 'name_desc':
          return b.name.localeCompare(a.name)
        case 'created_asc':
          return a.created_at.localeCompare(b.created_at)
        case 'created_desc':
          return b.created_at.localeCompare(a.created_at)
        default:
          return 0
      }
    })
  }

  const page = filtered.slice(offset, offset + limit)

  return {
    projects: page.map((p) => ({
      id: hashCode(p.ref),
      ref: p.ref,
      name: p.name,
      organization_id: getOrg().id,
      cloud_provider: 'localhost',
      status: p.status || 'ACTIVE_HEALTHY',
      region: 'local',
      inserted_at: p.created_at,
      databases: [
        {
          identifier: p.ref,
          host: process.env.POSTGRES_HOST || 'db',
          version: getDbVersion(),
          infra_compute_size: 'nano',
          status: 'ACTIVE_HEALTHY',
        },
      ],
    })),
    pagination: {
      count: filtered.length,
      limit,
      offset,
    },
  }
}

/** Shape expected by useProjectsInfiniteQuery / GET /platform/projects (Version 2) */
export function toProjectsListResponse(
  projects: MultiProject[],
  opts: { limit?: number; offset?: number; search?: string; sort?: string } = {}
) {
  // Same shape as org projects — the UI uses the same pagination structure
  return toOrgProjectsResponse(projects, opts)
}

/** Shape expected by GET /platform/profile */
export function toProfileResponse(projects: MultiProject[]) {
  const email = 'admin@localhost'
  const username = 'admin'

  return {
    id: '1',
    primary_email: email,
    username,
    first_name: username,
    last_name: '',
    disabled_features: [],
    organizations: [
      {
        ...getOrg(),
        projects: projects.map((p) => ({
          ...toProjectDetail(p),
          connectionString: '',
        })),
      },
    ],
  }
}

/** Shape expected by GET /platform/organizations */
export function toOrganizationsResponse() {
  return [getOrg()]
}

// Stable numeric ID from a string ref — uses FNV-1a for better distribution
function hashCode(s: string): number {
  let hash = 0x811c9dc5 // FNV offset basis
  for (let i = 0; i < s.length; i++) {
    hash ^= s.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193) // FNV prime
  }
  return Math.abs(hash)
}
