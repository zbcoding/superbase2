import type { NextApiRequest, NextApiResponse } from 'next'

import { checkCsrf, requireAuth } from '@/lib/superbase2/auth'
import { getProject, isSuperBase2Enabled, isValidProjectRef } from '@/lib/superbase2/projects'
import { toPostgrestConfigResponse } from '@/lib/superbase2/response-helpers'

/**
 * GET /api/superbase2/projects/{ref}/config
 *
 * Returns a minimal config object. The existing self-hosted handler at
 * /api/platform/projects/[ref]/config/index.ts returns hardcoded values;
 * we do the same but with per-project JWT secret.
 */
export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!(await requireAuth(req, res))) return

  const { method } = req

  switch (method) {
    case 'GET':
      return handleGet(req, res)
    case 'PATCH':
      if (!checkCsrf(req, res)) return
      return res.status(200).json({})
    default:
      res.setHeader('Allow', ['GET', 'PATCH'])
      return res.status(405).json({ error: { message: `Method ${method} Not Allowed` } })
  }
}

function handleGet(req: NextApiRequest, res: NextApiResponse) {
  const ref = req.query.ref as string
  if (!isValidProjectRef(ref)) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const project = getProject(ref)
  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  return res.status(200).json(toPostgrestConfigResponse(project))
}
