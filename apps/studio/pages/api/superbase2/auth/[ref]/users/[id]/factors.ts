import { NextApiRequest, NextApiResponse } from 'next'

import apiWrapper from '@/lib/api/apiWrapper'
import { guardSb2Project } from '@/lib/superbase2/auth'
import { getAuthClient } from '@/lib/superbase2/auth-client'

export default async (req: NextApiRequest, res: NextApiResponse) => {
  if (!(await guardSb2Project(req, res))) return
  return apiWrapper(req, res, handler)
}

async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { method } = req

  switch (method) {
    case 'DELETE':
      return handleDelete(req, res)
    default:
      res.setHeader('Allow', ['DELETE'])
      res.status(405).json({ data: null, error: { message: `Method ${method} Not Allowed` } })
  }
}

const handleDelete = async (req: NextApiRequest, res: NextApiResponse) => {
  const { id } = req.query
  const supabase = getAuthClient(req)

  const { data: factors, error } = await supabase.auth.admin.mfa.listFactors({
    userId: id as string,
  })
  if (error) {
    return res.status(400).json({ error: { message: error.message } })
  }

  for (const factor of factors?.factors ?? []) {
    const { error: deleteError } = await supabase.auth.admin.mfa.deleteFactor({
      id: factor.id,
      userId: id as string,
    })
    if (deleteError) {
      return res.status(400).json({ error: { message: deleteError.message } })
    }
  }

  return res.status(200).json({ data: null, error: null })
}
