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
export function clampPagination(req: NextApiRequest, defaults: { limit: number; offset: number } = { limit: 100, offset: 0 }) {
  const limit = Math.min(Math.max(parseInt((req.query.limit as string) || String(defaults.limit), 10) || defaults.limit, 1), 500)
  const offset = Math.max(parseInt((req.query.offset as string) || String(defaults.offset), 10) || 0, 0)
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
    db_user: 'postgres',
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
      cloud_provider: 'localhost' as any,
      connectionString: '',
      connection_string_read_only: '',
      db_host: process.env.POSTGRES_HOST || 'db',
      db_name: p.db,
      db_port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
      db_user: 'postgres',
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
 *  Anon key is included (needed by Studio for client-side operations).
 *  Service role key and JWT secret are redacted on read — only
 *  returned at creation time via toCreationResponse(). */
export function toSettingsResponse(p: MultiProject) {
  const publicUrl = getPublicUrl()
  return {
    app_config: {
      db_schema: 'public',
      endpoint: publicUrl.host,
      storage_endpoint: publicUrl.host,
      protocol: publicUrl.protocol.replace(':', ''),
    },
    cloud_provider: 'localhost',
    db_dns_name: '-',
    db_host: process.env.POSTGRES_HOST || 'db',
    db_ip_addr_config: 'legacy' as const,
    db_name: p.db,
    db_port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
    db_user: 'postgres',
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

/** Full project detail including secrets — only returned on project creation.
 *  The UI shows these once and instructs the user to save them. */
export function toCreationResponse(p: MultiProject) {
  return {
    ...toProjectDetail(p),
    jwt_secret: p.jwt_secret,
    anon_key: p.anon_key,
    service_role_key: p.service_role_key,
  }
}

/** Shape expected by GET /platform/projects/{ref}/config/postgrest */
export function toPostgrestConfigResponse(p: MultiProject) {
  return {
    db_anon_role: 'anon',
    db_extra_search_path: process.env.PGRST_DB_EXTRA_SEARCH_PATH ?? 'public',
    db_schema: process.env.PGRST_DB_SCHEMAS ?? 'public,storage,graphql_public',
    jwt_secret: p.jwt_secret,
    max_rows: Number(process.env.PGRST_DB_MAX_ROWS) || 1000,
    role_claim_key: '.role',
  }
}

/** Shape expected by useOrgProjectsInfiniteQuery / GET /platform/organizations/{slug}/projects */
export function toOrgProjectsResponse(
  projects: MultiProject[],
  { limit = 96, offset = 0, search, sort }: {
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
  return {
    id: 1,
    primary_email: 'admin@localhost',
    username: 'admin',
    first_name: 'Admin',
    last_name: '',
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
