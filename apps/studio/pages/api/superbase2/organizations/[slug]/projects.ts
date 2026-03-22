import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth } from 'lib/superbase2/auth'
import { isSuperBase2Enabled, listProjects } from 'lib/superbase2/projects'
import { clampPagination, toOrgProjectsResponse } from 'lib/superbase2/response-helpers'

export default function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!requireAuth(req, res)) return

  if (req.method !== 'GET') {
    res.setHeader('Allow', ['GET'])
    return res.status(405).json({ error: { message: `Method ${req.method} Not Allowed` } })
  }

  const projects = listProjects()

  const { limit, offset } = clampPagination(req, { limit: 96, offset: 0 })
  const sort = (req.query.sort as string) || 'name_asc'
  const search = req.query.search as string | undefined

  return res.status(200).json(toOrgProjectsResponse(projects, { limit, offset, sort, search }))
}
