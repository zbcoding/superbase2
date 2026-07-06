import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth } from '@/lib/superbase2/auth'
import { getProject, isSuperBase2Enabled, isValidProjectRef } from '@/lib/superbase2/projects'
import { toDatabasesResponse } from '@/lib/superbase2/response-helpers'

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!(await requireAuth(req, res))) return

  if (req.method !== 'GET') {
    res.setHeader('Allow', ['GET'])
    return res.status(405).json({ error: { message: `Method ${req.method} Not Allowed` } })
  }

  const ref = req.query.ref as string
  if (!isValidProjectRef(ref)) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const project = getProject(ref)
  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  return res.status(200).json(toDatabasesResponse(project))
}
