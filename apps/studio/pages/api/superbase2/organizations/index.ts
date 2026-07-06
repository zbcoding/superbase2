import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth } from '@/lib/superbase2/auth'
import { isSuperBase2Enabled } from '@/lib/superbase2/projects'
import { toOrganizationsResponse } from '@/lib/superbase2/response-helpers'

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!(await requireAuth(req, res))) return

  if (req.method !== 'GET') {
    res.setHeader('Allow', ['GET'])
    return res.status(405).json({ error: { message: `Method ${req.method} Not Allowed` } })
  }

  return res.status(200).json(toOrganizationsResponse())
}
