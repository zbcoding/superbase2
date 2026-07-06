import { NextApiRequest, NextApiResponse } from 'next'

import apiWrapper from '@/lib/api/apiWrapper'
import { guardSb2Project } from '@/lib/superbase2/auth'
import { getStorageClient } from '@/lib/superbase2/storage-client'

export default async (req: NextApiRequest, res: NextApiResponse) => {
  if (!(await guardSb2Project(req, res))) return
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
  const { id } = req.query
  const { from, to } = req.body
  const supabase = getStorageClient(req)

  const { data, error } = await supabase.storage.from(id as string).move(from, to)
  if (error) {
    return res.status(400).json({ error: { message: error.message } })
  }

  return res.status(200).json(data)
}
