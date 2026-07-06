import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth, checkCsrf } from '@/lib/superbase2/auth'
import {
  getProject,
  isSuperBase2Enabled,
  isValidProjectRef,
  updateDisabledServices,
  OPTIONAL_SERVICES,
} from '@/lib/superbase2/projects'
import type { OptionalService } from '@/lib/superbase2/projects'

/**
 * GET  /api/superbase2/projects/{ref}/services — list service status
 * PATCH /api/superbase2/projects/{ref}/services — toggle services on/off
 *
 * Per-project services like realtime, storage, and edge functions can be
 * disabled to save resources. Auth, PostgREST, and pg-meta are always required.
 *
 * After toggling, the user must run `./superbase2.sh down <name> && ./superbase2.sh up <name>`
 * to apply changes (the compose file is regenerated from the manifest on `up`).
 */
export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!(await requireAuth(req, res))) return
  if (!checkCsrf(req, res)) return

  const ref = req.query.ref as string
  if (!isValidProjectRef(ref)) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  switch (req.method) {
    case 'GET':
      return handleGet(req, res, ref)
    case 'PATCH':
      return handlePatch(req, res, ref)
    default:
      res.setHeader('Allow', ['GET', 'PATCH'])
      return res.status(405).json({ error: { message: `Method ${req.method} Not Allowed` } })
  }
}

function handleGet(_req: NextApiRequest, res: NextApiResponse, ref: string) {
  const project = getProject(ref)
  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const disabled = new Set(project.disabled_services || [])
  return res.status(200).json({
    services: OPTIONAL_SERVICES.map((svc) => ({
      name: svc,
      enabled: !disabled.has(svc),
      description: SERVICE_DESCRIPTIONS[svc],
    })),
    required: ['auth', 'rest', 'meta'],
  })
}

async function handlePatch(req: NextApiRequest, res: NextApiResponse, ref: string) {
  const project = getProject(ref)
  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const { disabled_services } = req.body || {}
  if (!Array.isArray(disabled_services)) {
    return res.status(400).json({ error: { message: 'disabled_services must be an array' } })
  }

  // Validate all entries are valid optional services
  const valid = new Set<string>(OPTIONAL_SERVICES)
  const invalid = disabled_services.filter((s: string) => !valid.has(s))
  if (invalid.length > 0) {
    return res.status(400).json({
      error: { message: `Invalid services: ${invalid.join(', ')}. Allowed: ${OPTIONAL_SERVICES.join(', ')}` },
    })
  }

  const updated = await updateDisabledServices(ref, disabled_services as OptionalService[])
  if (!updated) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  return res.status(200).json({
    message: 'Service configuration updated. Restart containers to apply: ./superbase2.sh down <name> && ./superbase2.sh up <name>',
    disabled_services,
  })
}

const SERVICE_DESCRIPTIONS: Record<OptionalService, string> = {
  realtime: 'WebSocket subscriptions and Postgres Changes. Disable if you only use REST/RPC — saves significant memory per project.',
  storage: 'S3-compatible file storage with image transformations. Disable if you use external storage (S3, R2, Cloudflare).',
  functions: 'Deno-based serverless edge functions. Disable if you deploy functions elsewhere (Vercel, Cloudflare Workers, AWS Lambda).',
}
