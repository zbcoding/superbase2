import { NextApiRequest, NextApiResponse } from 'next'

import { fetchGet } from '@/data/fetchers'
import { constructHeaders } from '@/lib/api/apiHelpers'
import apiWrapper from '@/lib/api/apiWrapper'
import { withConnectionHeader } from '@/lib/api/self-hosted/util'
import { PG_META_URL } from '@/lib/constants'
import { guardSb2Project } from '@/lib/superbase2/auth'

export default async (req: NextApiRequest, res: NextApiResponse) => {
  if (!(await guardSb2Project(req, res))) return
  return apiWrapper(req, res, handler, { withAuth: true })
}

async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { method } = req

  switch (method) {
    case 'GET':
      return handleGetAll(req, res)
    default:
      res.setHeader('Allow', ['GET'])
      res.status(405).json({ error: { message: `Method ${method} Not Allowed` } })
  }
}

const handleGetAll = async (req: NextApiRequest, res: NextApiResponse) => {
  const headers = withConnectionHeader(req, constructHeaders(req.headers))
  const response = await fetchGet(`${PG_META_URL}/extensions`, { headers })

  if (response.error) {
    const { code, message } = response.error
    return res.status(code).json({ message })
  } else {
    return res.status(200).json(response)
  }
}
