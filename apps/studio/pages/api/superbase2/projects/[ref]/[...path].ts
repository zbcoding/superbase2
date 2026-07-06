import crypto from 'crypto'
import path from 'path'
import type { NextApiRequest, NextApiResponse } from 'next'

import { requireAuth, checkCsrf } from '@/lib/superbase2/auth'
import { getProject, isSuperBase2Enabled, isValidProjectRef } from '@/lib/superbase2/projects'
import type { MultiProject } from '@/lib/superbase2/projects'

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
  if (!(await requireAuth(req, res))) return
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
    console.log('[SB2 debug] catchall invalid ref rejected', { ref, subPath, method: req.method, url: req.url })
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  const project = getProject(ref)
  if (!project) {
    return res.status(404).json({ error: { message: 'Project not found' } })
  }

  // Proxy pg-meta requests to the per-project pg-meta container
  if (subPath === 'pg' || subPath.startsWith('pg/')) {
    return proxyPgMeta(req, res, project, subPath)
  }

  // SQL snippet item lookup. Snippets aren't persisted server-side in
  // multi-project self-hosted mode, so any specific id can't be found.
  // Return 404 with the message Studio expects so /sql/[id] renders the
  // "Unable to find snippet" admonition instead of an infinite spinner.
  if (subPath.startsWith('content/item/')) {
    if (req.method === 'GET' || req.method === 'DELETE') {
      return res.status(404).json({ code: 404, message: 'Content not found.' })
    }
    return res.status(200).json({ data: null })
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
      // SQL snippets / saved queries. Studio's content query spreads
      // `data.data` expecting an array of snippets + optional cursor.
      if (req.method === 'GET') {
        return res.status(200).json({ data: [], cursor: undefined })
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
      // Studio's useSQLSnippetFoldersQuery spreads `data.data` into each
      // page and expects `{ folders: [], contents: [] }`. Returning an
      // array here leaves `page.contents` undefined and crashes the SQL
      // editor inside `allSnippetsInView` flatMap/filter.
      return res.status(200).json({
        data: { folders: [], contents: [] },
        cursor: undefined,
      })

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
  // Lowercase the hostname: URL normalizes to lowercase, so the equality check
  // on line 155 would always fail for project names with uppercase letters.
  const metaHost = `meta-${project.name}`.toLowerCase()

  // Reject path traversal attempts — check both the raw path and URL-decoded
  // variants (%2e%2e, %2f%2f, etc.) that could bypass a plain string check.
  const decodedMetaPath = (() => {
    try { return decodeURIComponent(metaPath) } catch { return metaPath }
  })()
  const normalizedPath = path.posix.normalize(decodedMetaPath)
  if (
    metaPath.includes('..') ||
    metaPath.includes('//') ||
    decodedMetaPath.includes('..') ||
    normalizedPath.startsWith('..')
  ) {
    return res.status(400).json({ error: { message: 'Invalid path' } })
  }

  // Construct URL safely using URL class to prevent protocol/host injection.
  // Only forward query params that aren't Next.js dynamic route params.
  const metaUrl = new URL(`http://${metaHost}:8080/${metaPath}`)
  if (metaUrl.hostname !== metaHost) {
    return res.status(400).json({ error: { message: 'Invalid proxy target' } })
  }
  for (const [key, value] of Object.entries(req.query)) {
    if (key === 'ref' || key === 'path') continue
    if (typeof value === 'string') {
      metaUrl.searchParams.set(key, value)
    } else if (Array.isArray(value)) {
      // Forward repeated query params (e.g. ?foo=a&foo=b) as multiple values
      for (const v of value) {
        metaUrl.searchParams.append(key, v)
      }
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

    const proxyTimeoutMs = parseInt(process.env.SUPERBASE2_PROXY_TIMEOUT_MS || '15000', 10)
    const fetchOpts: RequestInit = {
      method: req.method,
      headers: proxyHeaders,
      signal: AbortSignal.timeout(proxyTimeoutMs),
    }

    if (req.method !== 'GET' && req.method !== 'HEAD' && req.body) {
      const contentType = (req.headers['content-type'] as string) || ''
      // Only JSON-stringify when the client sent JSON — Next.js has already parsed it
      // into req.body. For other content types pass the raw body through unchanged.
      fetchOpts.body = contentType.includes('application/json')
        ? JSON.stringify(req.body)
        : (req.body as BodyInit)
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
    console.error(`pg-meta proxy error for project '${project.name}':`, err)
    // Distinguish timeout from connection refused so callers can act accordingly.
    const isTimeout = err instanceof Error && err.name === 'TimeoutError'
    if (isTimeout) {
      return res.status(504).json({
        error: { message: 'pg-meta request timed out. The container may be overloaded.' },
      })
    }
    return res.status(503).json({
      error: { message: 'pg-meta is not reachable. Ensure per-project containers are running.' },
    })
  }
}
