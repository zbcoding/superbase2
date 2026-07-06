import { NextApiRequest, NextApiResponse } from 'next'

import { fetchPost } from '@/data/fetchers'
import { constructHeaders } from '@/lib/api/apiHelpers'
import { apiWrapper } from '@/lib/api/apiWrapper'
import { requireAuth } from '@/lib/superbase2/auth'
import { getAuthEndpoint } from '@/lib/superbase2/auth-client'

export default async (req: NextApiRequest, res: NextApiResponse) => {
  if (!(await requireAuth(req, res))) return
  return apiWrapper(req, res, handler)
}

async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { method } = req

  switch (method) {
    case 'POST':
      return handlePost(req, res)
    default:
      res.setHeader('Allow', ['POST'])
      res.status(405).json({ data: null, error: { message: `Method ${method} Not Allowed` } })
  }
}

const handlePost = async (req: NextApiRequest, res: NextApiResponse) => {
  const endpoint = getAuthEndpoint(req)
  const headers = constructHeaders({
    'Content-Type': 'application/json',
    Accept: 'application/json',
    Authorization: `Bearer ${endpoint.serviceKey}`,
  })
  const url = `${endpoint.url}/otp`
  const payload = { phone: req.body.phone }

  const response = await fetchPost(url, payload, { headers })
  if (response.error) {
    const { code, message } = response.error
    return res.status(code).json({ message })
  } else {
    return res.status(200).json(response)
  }
}
