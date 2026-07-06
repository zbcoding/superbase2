import { createClient, SupabaseClient } from '@supabase/supabase-js'
import type { NextApiRequest } from 'next'

import { getProject, isSuperBase2Enabled, isValidProjectRef } from './projects'

/**
 * Resolve a supabase-js client for `/platform/auth/[ref]/...` admin requests.
 *
 * In SuperBase² mode each project has its own GoTrue container with its own
 * JWT_SECRET, reachable through the main Kong's per-project route
 * (`/project/<ref>/auth/v1/...`). The stock handlers always create a client
 * against the main-stack `SUPABASE_URL` + `SUPABASE_SERVICE_KEY`, which writes
 * users into the shared `postgres` DB instead of the per-project DB.
 */
export function getAuthClient(req: NextApiRequest): SupabaseClient {
  const client = getSuperbase2AuthClient(req)
  if (client) return client

  return createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_KEY!)
}

export function getSuperbase2AuthClient(req: NextApiRequest): SupabaseClient | undefined {
  const ref = typeof req.query.ref === 'string' ? req.query.ref : undefined

  if (isSuperBase2Enabled() && ref && isValidProjectRef(ref)) {
    const project = getProject(ref)
    if (project) {
      const kongUrl = process.env.SUPABASE_URL || 'http://kong:8000'
      return createClient(`${kongUrl}/project/${ref}`, project.service_role_key)
    }
  }

  return undefined
}

/**
 * Resolve the per-project GoTrue base URL + service-role key for raw
 * fetch-based handlers (invite/magiclink/otp/recover) that don't go through
 * supabase-js.
 */
export function getAuthEndpoint(req: NextApiRequest): { url: string; serviceKey: string } {
  const endpoint = getSuperbase2AuthEndpoint(req)
  if (endpoint) return endpoint

  return {
    url: `${process.env.SUPABASE_URL}/auth/v1`,
    serviceKey: process.env.SUPABASE_SERVICE_KEY!,
  }
}

export function getSuperbase2AuthEndpoint(req: NextApiRequest): { url: string; serviceKey: string } | undefined {
  const ref = typeof req.query.ref === 'string' ? req.query.ref : undefined

  if (isSuperBase2Enabled() && ref && isValidProjectRef(ref)) {
    const project = getProject(ref)
    if (project) {
      const kongUrl = process.env.SUPABASE_URL || 'http://kong:8000'
      return {
        url: `${kongUrl}/project/${ref}/auth/v1`,
        serviceKey: project.service_role_key,
      }
    }
  }

  return undefined
}
