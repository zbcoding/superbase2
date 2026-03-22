import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth, checkCsrf } from 'lib/superbase2/auth'
import { dropProjectDatabase } from 'lib/superbase2/db'
import {
  getProject,
  isSuperBase2Enabled,
  isValidProjectRef,
  removeProject,
} from 'lib/superbase2/projects'
import { toProjectDetail } from 'lib/superbase2/response-helpers'

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!requireAuth(req, res)) return
  if (!checkCsrf(req, res)) return

  const ref = req.query.ref as string
  if (!isValidProjectRef(ref)) {
    return res.status(400).json({ error: { message: 'Invalid project ref format' } })
  }

  switch (req.method) {
    case 'GET':
      return handleGet(req, res, ref)
    case 'PATCH':
      return handlePatch(req, res, ref)
    case 'DELETE':
      return handleDelete(req, res, ref)
    default:
      res.setHeader('Allow', ['GET', 'PATCH', 'DELETE'])
      return res.status(405).json({ error: { message: `Method ${req.method} Not Allowed` } })
  }
}

function handleGet(req: NextApiRequest, res: NextApiResponse, ref: string) {
  const project = getProject(ref)

  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  return res.status(200).json(toProjectDetail(project))
}

async function handlePatch(req: NextApiRequest, res: NextApiResponse, ref: string) {
  const project = getProject(ref)

  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const { name } = req.body || {}

  // Renaming is not supported in SuperBase² because per-project containers
  // (auth-<name>, rest-<name>, meta-<name>, etc.) are addressed by name on the
  // Docker network. A manifest rename without restarting containers would break
  // the pg-meta proxy and Kong routing immediately. The database name
  // (project_<name>) also can't be changed while clients are connected.
  if (name && typeof name === 'string' && name !== project.name) {
    return res.status(400).json({
      error: {
        message:
          'Project renaming is not supported in SuperBase². Per-project containers ' +
          'are addressed by name on the Docker network. To rename, destroy and recreate the project.',
      },
    })
  }

  // No rename requested — return current state
  return res.status(200).json(toProjectDetail(project))
}

async function handleDelete(req: NextApiRequest, res: NextApiResponse, ref: string) {
  const project = getProject(ref)

  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const warnings: string[] = []
  warnings.push(
    "Stop per-project containers BEFORE deleting to avoid race conditions with auto-restarting services."
  )

  try {
    await dropProjectDatabase(project.db)
  } catch (err: unknown) {
    console.error('Failed to drop database:', err)
    return res.status(500).json({
      error: {
        message: 'Failed to drop database. Per-project containers may still be running and reconnecting. Stop them first, then retry.',
      },
    })
  }

  try {
    await removeProject(ref)
  } catch (err: unknown) {
    console.error('Database dropped but failed to remove manifest entry:', err)
    warnings.push(
      'Database dropped but failed to remove manifest entry. The project may still appear in the UI until the manifest is manually cleaned up.'
    )
  }

  return res.status(200).json({
    message: 'Project deleted',
    warnings,
  })
}
