import type { NextApiRequest, NextApiResponse } from 'next'

/**
 * SuperBase² — unauthenticated health check endpoint.
 *
 * Used by Docker/Coolify healthchecks. Must not require auth so that
 * the healthcheck passes regardless of DASHBOARD_PASSWORD configuration.
 */
export default function handler(_req: NextApiRequest, res: NextApiResponse) {
  res.status(200).json({ ok: true })
}
