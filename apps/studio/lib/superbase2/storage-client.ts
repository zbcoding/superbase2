import { createClient, SupabaseClient } from '@supabase/supabase-js'
import type { NextApiRequest } from 'next'

import { getProject, isSuperBase2Enabled, isValidProjectRef } from './projects'

/**
 * Resolve a supabase-js client for a `/platform/storage/[ref]/...` request.
 *
 * In SuperBase² mode, the ref on the URL identifies a per-project stack with
 * its own storage container and its own service_role JWT (signed under its
 * own JWT_SECRET). The main stack's SUPABASE_SERVICE_KEY is not valid there,
 * which is why the stock handlers — which always use the main-stack env —
 * return 500 when called with a per-project ref.
 *
 * This helper resolves the ref against the SB2 manifest and returns a client
 * targeting that project via the main Kong's per-project route
 * (`/project/<ref>/storage/v1`, added by superbase2.sh rebuild-kong).
 *
 * Falls back to the main-stack client when SB2 is disabled or the ref does
 * not correspond to a known SB2 project, which preserves upstream behavior.
 */
export function getStorageClient(req: NextApiRequest): SupabaseClient {
  const client = getSuperbase2StorageClient(req)
  if (client) return client

  return createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_KEY!)
}

export function getSuperbase2StorageClient(req: NextApiRequest): SupabaseClient | undefined {
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
