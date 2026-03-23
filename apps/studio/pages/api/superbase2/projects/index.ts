import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth, checkCsrf } from 'lib/superbase2/auth'
import { createProjectDatabase, isValidProjectName } from 'lib/superbase2/db'
import { addProjectIfNotExists, generateProjectSecrets, isSuperBase2Enabled, listProjects, removeProject } from 'lib/superbase2/projects'
import {
  clampPagination,
  toCreationResponse,
  toProjectDetail,
  toProjectsListResponse,
} from 'lib/superbase2/response-helpers'

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!requireAuth(req, res)) return
  if (!checkCsrf(req, res)) return

  switch (req.method) {
    case 'GET':
      return handleGet(req, res)
    case 'POST':
      return handleCreate(req, res)
    default:
      res.setHeader('Allow', ['GET', 'POST'])
      return res.status(405).json({ error: { message: `Method ${req.method} Not Allowed` } })
  }
}

function handleGet(req: NextApiRequest, res: NextApiResponse) {
  const projects = listProjects()

  // Version 2 header = paginated response (used by command palette / project switcher).
  // Next.js lowercases all HTTP headers in req.headers.
  const version = req.headers['version']
  if (version === '2') {
    const { limit, offset } = clampPagination(req)
    const sort = (req.query.sort as string) || 'name_asc'
    const search = req.query.search as string | undefined

    return res.status(200).json(toProjectsListResponse(projects, { limit, offset, sort, search }))
  }

  // Version 1 (legacy) = flat array
  return res.status(200).json(projects.map(toProjectDetail))
}

async function handleCreate(req: NextApiRequest, res: NextApiResponse) {
  try {
    const { name } = req.body

    if (!name || typeof name !== 'string') {
      return res.status(400).json({ error: { message: 'Project name is required' } })
    }

    if (!isValidProjectName(name)) {
      return res.status(400).json({
        error: {
          message:
            'Invalid project name. Only letters and numbers are allowed (2-48 chars). No underscores or hyphens.',
        },
      })
    }

    // Generate secrets and project ref
    const project = generateProjectSecrets(name)

    // Atomic check-and-add under lock to prevent duplicates.
    // Must happen BEFORE creating the DB to avoid orphaned databases.
    const added = await addProjectIfNotExists(project)
    if (!added) {
      return res.status(409).json({ error: { message: `Project '${name}' already exists` } })
    }

    // Create database with schemas
    try {
      await createProjectDatabase(
        project.db,
        project.jwt_secret,
        process.env.JWT_EXPIRY || '3600'
      )
    } catch (dbErr) {
      // Roll back the manifest entry if DB creation fails
      try { await removeProject(project.ref) } catch { /* don't mask the original error */ }
      throw dbErr
    }

    // Return full details including secrets — this is the only time they're shown
    return res.status(201).json(toCreationResponse(project))
  } catch (err: unknown) {
    console.error('Failed to create project:', err)
    return res.status(500).json({ error: { message: 'Failed to create project' } })
  }
}
