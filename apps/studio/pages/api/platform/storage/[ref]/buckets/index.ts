import { NextApiRequest, NextApiResponse } from 'next'

import apiWrapper from '@/lib/api/apiWrapper'
import { requireAuth } from '@/lib/superbase2/auth'
import { getStorageClient } from '@/lib/superbase2/storage-client'

export default async (req: NextApiRequest, res: NextApiResponse) => {
  if (!(await requireAuth(req, res))) return
  return apiWrapper(req, res, handler)
}

async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { method } = req

  switch (method) {
    case 'GET':
      return handleGet(req, res)
    case 'POST':
      return handlePost(req, res)

    default:
      res.setHeader('Allow', ['GET', 'POST'])
      res.status(405).json({ data: null, error: { message: `Method ${method} Not Allowed` } })
  }
}

const handleGet = async (req: NextApiRequest, res: NextApiResponse) => {
  const { limit, offset, search, sortColumn, sortOrder } = parseStoragePaginationParams(req)
  const supabase = getStorageClient(req)

  const { data, error } = await supabase.storage.listBuckets({
    ...(limit ? { limit } : {}),
    ...(offset ? { offset } : {}),
    ...(search ? { search } : {}),
    ...(sortColumn ? { sortColumn } : {}),
    ...(sortOrder ? { sortOrder } : {}),
  })
  if (error) {
    console.error('[SB2] listBuckets failed for ref', req.query.ref, error)
    return res.status(500).json({
      error: {
        message: error.message || 'Internal Server Error',
        name: (error as any).name,
        status: (error as any).status,
      },
    })
  }

  return res.status(200).json(data)
}

const handlePost = async (req: NextApiRequest, res: NextApiResponse) => {
  const {
    id,
    public: isPublicBucket,
    allowed_mime_types: allowedMimeTypes,
    file_size_limit: fileSizeLimit,
  } = req.body
  const supabase = getStorageClient(req)

  const { data, error } = await supabase.storage.createBucket(id, {
    public: isPublicBucket,
    allowedMimeTypes,
    fileSizeLimit,
  })
  if (error) {
    return res.status(400).json({ error: { message: error.message } })
  }

  return res.status(200).json(data)
}

const parseStoragePaginationParams = (req: NextApiRequest) => {
  const {
    limit: queryLimit,
    offset: queryOffset,
    search: querySearch,
    sortColumn: querySortColumn,
    sortOrder: querySortOrder,
  } = req.query

  const limit = parseAsInt(queryLimit)
  const offset = parseAsInt(queryOffset)
  const search = parseAsString(querySearch)
  const sortColumn = parseAsStringEnum(querySortColumn, ['id', 'created_at', 'name'])
  const sortOrder = parseAsStringEnum(querySortOrder, ['asc', 'desc'])

  return { limit, offset, search, sortColumn, sortOrder }
}

const parseAsInt = (value: string | string[] | undefined): number | undefined =>
  value ? (Array.isArray(value) ? parseInt(value[0], 10) : parseInt(value, 10)) : undefined

const parseAsString = (value: string | string[] | undefined): string | undefined =>
  value ? (Array.isArray(value) ? value[0] : value) : undefined

const parseAsStringEnum = <T extends string>(
  value: string | string[] | undefined,
  validValues: T[]
): T | undefined => {
  const strValue = value ? (Array.isArray(value) ? value[0] : value) : undefined
  return strValue && validValues.includes(strValue as T) ? (strValue as T) : undefined
}
