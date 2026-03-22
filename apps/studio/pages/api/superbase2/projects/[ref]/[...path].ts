import crypto from 'crypto'
import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth, checkCsrf } from 'lib/superbase2/auth'
import { getProject, isSuperBase2Enabled, isValidProjectRef } from 'lib/superbase2/projects'
import type { MultiProject } from 'lib/superbase2/projects'

/**
 * Catch-all handler for project sub-routes not explicitly handled by
 * SuperBase². For pg-meta routes, proxies to the per-project pg-meta
 * container. For other routes, returns sensible empty/default responses
 * so Studio pages don't crash.
 *
 * Specific sub-routes (databases, settings, config/*) have their own
 * dedicated handlers that take priority over this catch-all.
 */
export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!requireAuth(req, res)) return
  if (!checkCsrf(req, res)) return

  const ref = req.query.ref as string
  const pathSegments = req.query.path as string[]
  const subPath = pathSegments.join('/')

  // Catch-all routes rewritten by middleware for org sub-routes and config
  // that don't need project context — return sensible defaults.
  if (ref === '_org-catchall' || ref === '_config-catchall') {
    return handleGenericCatchall(req, res, subPath)
  }

  if (!isValidProjectRef(ref)) {
    return res.status(400).json({ error: { message: 'Invalid project ref format' } })
  }

  const project = getProject(ref)
  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  // Proxy pg-meta requests to the per-project pg-meta container
  if (subPath === 'pg' || subPath.startsWith('pg/')) {
    return proxyPgMeta(req, res, project, subPath)
  }

  // Return sensible defaults for known sub-routes that Studio may call
  switch (subPath) {
    case 'api/rest':
    case 'api/graphql':
      // API endpoint info — return empty schema info
      return res.status(200).json({})

    case 'billing/addons':
      return res.status(200).json({
        selected_addons: [],
        available_addons: [],
      })

    case 'content':
      // SQL snippets / saved queries
      if (req.method === 'GET') {
        return res.status(200).json({ data: [] })
      }
      if (req.method === 'POST') {
        // Return the submitted content back so Studio thinks it was saved.
        // In multi-project self-hosted mode, snippets aren't persisted server-side.
        const body = req.body || {}
        return res.status(201).json({
          data: { id: crypto.randomUUID(), ...body },
        })
      }
      return res.status(200).json({ data: null })

    case 'content/count':
      return res.status(200).json({ data: 0 })

    case 'content/folders':
      return res.status(200).json({ data: [] })

    case 'run-lints':
      return res.status(200).json([])

    case 'infra-monitoring':
      return res.status(200).json({ data: [] })

    case 'api-keys/temporary':
      return res.status(200).json({ data: null })

    default:
      // For any other sub-route, return an empty object for GET,
      // 200 for mutations — prevents Studio from showing error toasts
      if (req.method === 'GET') {
        return res.status(200).json({})
      }
      return res.status(200).json({ data: null })
  }
}

/**
 * Handle generic catch-all routes for org sub-routes (billing, members, etc.)
 * and config routes that the middleware rewrites to avoid 500s from stock handlers.
 */
function handleGenericCatchall(req: NextApiRequest, res: NextApiResponse, subPath: string) {
  // Return safe defaults for known patterns
  if (subPath.includes('billing')) {
    return res.status(200).json({ plan: { id: 'enterprise', name: 'Enterprise' } })
  }
  if (subPath.includes('members')) {
    return res.status(200).json([
      { id: 1, username: 'admin', primary_email: 'admin@localhost', role_name: 'Owner' },
    ])
  }
  if (req.method === 'GET') {
    return res.status(200).json({})
  }
  return res.status(200).json({ data: null })
}

/**
 * Proxy requests to the per-project pg-meta container.
 *
 * Per-project pg-meta containers are started by `./superbase2.sh up <name>`
 * and are accessible on the Docker network as `meta-<name>:8080`.
 */
async function proxyPgMeta(
  req: NextApiRequest,
  res: NextApiResponse,
  project: MultiProject,
  subPath: string
) {
  const metaPath = subPath.replace(/^pg\/?/, '')
  const metaHost = `meta-${project.name}`

  // Reject path traversal attempts
  if (metaPath.includes('..') || metaPath.includes('//')) {
    return res.status(400).json({ error: { message: 'Invalid path' } })
  }

  // Construct URL safely using URL class to prevent protocol/host injection.
  // Only forward query params that aren't Next.js dynamic route params.
  const metaUrl = new URL(`http://${metaHost}:8080/${metaPath}`)
  if (metaUrl.hostname !== metaHost) {
    return res.status(400).json({ error: { message: 'Invalid proxy target' } })
  }
  for (const [key, value] of Object.entries(req.query)) {
    if (key !== 'ref' && key !== 'path' && typeof value === 'string') {
      metaUrl.searchParams.set(key, value)
    }
  }

  try {
    // Forward relevant headers from the original request
    const proxyHeaders: Record<string, string> = {
      'Content-Type': (req.headers['content-type'] as string) || 'application/json',
    }
    if (req.headers.authorization) {
      proxyHeaders['Authorization'] = req.headers.authorization as string
    }
    if (req.headers['x-connection-encrypted']) {
      proxyHeaders['x-connection-encrypted'] = req.headers['x-connection-encrypted'] as string
    }

    const fetchOpts: RequestInit = {
      method: req.method,
      headers: proxyHeaders,
      signal: AbortSignal.timeout(15_000),
    }

    if (req.method !== 'GET' && req.method !== 'HEAD' && req.body) {
      fetchOpts.body = JSON.stringify(req.body)
    }

    const proxyRes = await fetch(metaUrl.toString(), fetchOpts)
    const contentType = proxyRes.headers.get('content-type') || ''

    if (contentType.includes('application/json')) {
      const data = await proxyRes.json()
      return res.status(proxyRes.status).json(data)
    } else {
      const text = await proxyRes.text()
      return res.status(proxyRes.status).send(text)
    }
  } catch (err: unknown) {
    // Container not running or unreachable
    console.error(`pg-meta proxy error for project '${project.name}':`, err)
    return res.status(503).json({
      error: {
        message: 'pg-meta is not reachable. Ensure per-project containers are running.',
      },
    })
  }
}
