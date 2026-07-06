import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth, checkCsrf } from '@/lib/superbase2/auth'
import {
  AgentUnavailableError,
  callAgent,
  isAgentConfigured,
  type LifecycleAction,
} from '@/lib/superbase2/agent-client'
import { getProject, isSuperBase2Enabled, isValidProjectRef } from '@/lib/superbase2/projects'

const ALLOWED_ACTIONS: LifecycleAction[] = ['up', 'down', 'restart']

/**
 * Start / stop / restart a project's container stack via the sb2-agent.
 *
 * The agent runs `superbase2.sh <action> <name>` on the host. Studio has no
 * Docker socket, so this route is the only way to drive lifecycle from the UI
 * (the old path required SSHing to the server).
 */
export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!(await requireAuth(req, res))) return
  if (!checkCsrf(req, res)) return

  if (req.method !== 'POST') {
    res.setHeader('Allow', ['POST'])
    return res.status(405).json({ error: { message: `Method ${req.method} Not Allowed` } })
  }

  const ref = req.query.ref as string
  if (!isValidProjectRef(ref)) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const project = getProject(ref)
  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const action = req.body?.action as LifecycleAction | undefined
  if (!action || !ALLOWED_ACTIONS.includes(action)) {
    return res.status(400).json({
      error: { message: `Invalid action. Must be one of: ${ALLOWED_ACTIONS.join(', ')}` },
    })
  }

  if (!isAgentConfigured()) {
    return res.status(503).json({
      error: {
        message:
          'sb2-agent is not configured on this server. Set SB2_AGENT_URL and ' +
          'SB2_AGENT_TOKEN and redeploy Studio to enable lifecycle controls.',
      },
    })
  }

  try {
    const result = await callAgent(action, project.name)
    const ok = Boolean((result as { ok?: boolean }).ok)
    return res.status(ok ? 200 : 500).json({ action, ...result })
  } catch (err) {
    if (err instanceof AgentUnavailableError) {
      return res.status(503).json({ error: { message: err.message } })
    }
    console.error('[SuperBase²] agent call failed:', err)
    return res.status(500).json({
      error: { message: 'Failed to reach SB2 agent' },
    })
  }
}
