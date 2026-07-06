/**
 * SuperBase² — client for the sb2-agent sidecar.
 *
 * The agent holds the Docker socket and runs `superbase2.sh` on the host.
 * Studio has no socket, so all "start / stop / restart project stack"
 * operations go through this module.
 *
 * Only reachable on the internal compose network; authenticated with a
 * shared bearer token (SB2_AGENT_TOKEN) injected into both containers.
 */

export interface AgentResult {
  ok: boolean
  exit_code: number
  stdout: string
  stderr: string
}

export interface AgentRestartResult {
  ok: boolean
  down: AgentResult
  up: AgentResult
}

export type LifecycleAction = 'up' | 'down' | 'restart' | 'status' | 'rotate-keys'

export function isAgentConfigured(): boolean {
  return Boolean(process.env.SB2_AGENT_URL && process.env.SB2_AGENT_TOKEN)
}

/**
 * Default per-action timeouts. `up` can take several minutes on first boot
 * because docker has to pull images; `restart` is bounded by `down` + `up`.
 * `down`/`status` should always be fast.
 */
const DEFAULT_TIMEOUTS: Record<LifecycleAction, number> = {
  up: 600_000,
  restart: 600_000,
  down: 60_000,
  status: 15_000,
  // rotate-keys runs sync_manifest + rebuild-kong + down + up; cap matches up.
  'rotate-keys': 600_000,
}

/**
 * Invoke a lifecycle action on a project via the agent.
 * Throws on network/config errors. Returns the agent's JSON body for
 * script-level errors (non-zero exit) — callers decide whether to 500.
 */
export async function callAgent(
  action: LifecycleAction,
  projectName: string,
  { timeoutMs }: { timeoutMs?: number } = {}
): Promise<AgentResult | AgentRestartResult> {
  const effectiveTimeout = timeoutMs ?? DEFAULT_TIMEOUTS[action]
  const base = process.env.SB2_AGENT_URL
  const token = process.env.SB2_AGENT_TOKEN
  if (!base || !token) {
    throw new AgentUnavailableError('SB2 agent is not configured')
  }

  const method = action === 'status' ? 'GET' : 'POST'
  const url = `${base.replace(/\/$/, '')}/projects/${encodeURIComponent(projectName)}/${action}`

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), effectiveTimeout)

  try {
    const res = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/json',
      },
      signal: controller.signal,
    })

    const text = await res.text()
    let body: unknown
    try { body = text ? JSON.parse(text) : {} } catch { body = { stdout: '', stderr: text } }

    // Any parseable body is fine to return — the route maps ok:false to 500.
    return body as AgentResult | AgentRestartResult
  } catch (err) {
    if (err instanceof AgentUnavailableError) throw err
    if ((err as { name?: string }).name === 'AbortError') {
      throw new AgentUnavailableError(`SB2 agent timed out after ${effectiveTimeout}ms`)
    }
    throw new AgentUnavailableError(
      `SB2 agent request failed: ${err instanceof Error ? err.message : String(err)}`
    )
  } finally {
    clearTimeout(timer)
  }
}

export class AgentUnavailableError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AgentUnavailableError'
  }
}
