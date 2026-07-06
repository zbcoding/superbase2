import { NextApiRequest, NextApiResponse } from 'next'

import apiWrapper from '@/lib/api/apiWrapper'
import { requireAuth } from '@/lib/superbase2/auth'
import { getAuthClient } from '@/lib/superbase2/auth-client'

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
  const supabase = getAuthClient(req)
  const { data, error } = await supabase.auth.admin.createUser(req.body)

  if (error) return res.status(400).json({ error: { message: error.message } })
  return res.status(200).json(data.user)
}
