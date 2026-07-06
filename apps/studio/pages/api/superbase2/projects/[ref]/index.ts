import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth, checkCsrf } from '@/lib/superbase2/auth'
import {
  AgentUnavailableError,
  callAgent,
  isAgentConfigured,
  type AgentResult,
} from '@/lib/superbase2/agent-client'
import { dropProjectDatabase } from '@/lib/superbase2/db'
import {
  getProject,
  isSuperBase2Enabled,
  isValidProjectRef,
  removeProject,
} from '@/lib/superbase2/projects'
import { toProjectDetail } from '@/lib/superbase2/response-helpers'

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!(await requireAuth(req, res))) return
  if (!checkCsrf(req, res)) return

  const ref = req.query.ref as string
  if (!isValidProjectRef(ref)) {
    console.log('[SB2 debug] invalid ref rejected', { ref, method: req.method, url: req.url })
    // 404 (not 400) so Studio's RouteValidationWrapper silently redirects to
    // DEFAULT_HOME instead of toasting "You do not have access to this project".
    // Catches legacy /project/default bookmarks from pre-SB2 self-hosted installs.
    return res.status(404).json({ error: { message: 'Project not found' } })
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

function handleGet(_req: NextApiRequest, res: NextApiResponse, ref: string) {
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

async function handleDelete(_req: NextApiRequest, res: NextApiResponse, ref: string) {
  const project = getProject(ref)

  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const warnings: string[] = []

  // Best-effort: stop per-project containers via the agent before dropping the
  // DB, so auto-restarting services can't reconnect mid-drop. If the agent is
  // unavailable, fall through with a warning — the caller already confirmed
  // deletion intent, so we shouldn't block on agent health.
  if (isAgentConfigured()) {
    try {
      const result = (await callAgent('down', project.name, { timeoutMs: 60_000 })) as AgentResult
      if (!result.ok) {
        const detail = (result.stderr || result.stdout || '').trim().slice(0, 300)
        warnings.push(
          `sb2-agent reported 'down' failed (exit ${result.exit_code})${detail ? `: ${detail}` : ''}. Containers may still be running; the DB drop below may fail if they reconnect.`
        )
      }
    } catch (err) {
      warnings.push(
        `Could not stop containers via sb2-agent (${
          err instanceof AgentUnavailableError ? err.message : 'unknown error'
        }). If the drop fails, SSH in and run ./superbase2.sh down ${project.name} first.`
      )
    }
  } else {
    warnings.push(
      'sb2-agent not configured — per-project containers were not stopped. SSH in and run ./superbase2.sh down <name> if the drop fails.'
    )
  }

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
