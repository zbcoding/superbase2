/**
 * SuperBase² — authentication and CSRF protection for API routes.
 *
 * Two independent layers:
 *
 *  1. CSRF protection (checkCsrf) is ALWAYS active for mutating requests,
 *     regardless of SUPERBASE2_AUTH. It accepts a request when the Origin
 *     matches the configured public URL (covers the stock Studio UI, which
 *     can't send a custom token) OR a valid double-submit token is present
 *     (covers the sb2 dashboard page). A forged cross-site POST has neither,
 *     so it is rejected. This is the primary defense behind Kong basic-auth,
 *     which the browser replays automatically and therefore does NOT stop CSRF.
 *
 *  2. HTTP basic-auth (requireAuth) is defense-in-depth for when port 3000 is
 *     exposed directly (bypassing Kong). Active when SUPERBASE2_AUTH=true.
 *     NOTE: for this to work behind Kong, the dashboard route's basic-auth
 *     plugin must use `hide_credentials: false` so the Authorization header
 *     reaches Studio (see templates/kong-base.yml.tpl).
 */

import crypto from 'crypto'
import type { NextApiRequest, NextApiResponse } from 'next'

import { getProject, isSuperBase2Enabled, isValidProjectRef } from './projects'

function basicAuthEnabled(): boolean {
  return process.env.SUPERBASE2_AUTH === 'true'
}

/**
 * Check authentication. Returns true if the request is authorized.
 * If unauthorized, sends 401 and returns false — caller should return immediately.
 */
export async function requireAuth(
  req: NextApiRequest,
  res: NextApiResponse
): Promise<boolean> {
  if (basicAuthEnabled()) {
    return verifyBasicAuth(req, res)
  }
  return true
}

/**
 * Combined guard for sb2 API routes: basic-auth (when enabled) + CSRF.
 * Returns true if the request may proceed. On rejection it has already
 * written the response, so callers must return immediately.
 */
export async function guardSb2(
  req: NextApiRequest,
  res: NextApiResponse
): Promise<boolean> {
  if (!(await requireAuth(req, res))) return false
  if (!checkCsrf(req, res)) return false
  return true
}

export async function guardSb2Project(
  req: NextApiRequest,
  res: NextApiResponse
): Promise<boolean> {
  if (!(await guardSb2(req, res))) return false
  if (!isSuperBase2Enabled()) {
    res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
    return false
  }

  const ref = typeof req.query.ref === 'string' ? req.query.ref : undefined
  if (!ref || !isValidProjectRef(ref) || !getProject(ref)) {
    res.status(404).json({ error: { message: 'Project not found' } })
    return false
  }

  return true
}

// ── Basic auth verification ──────────────────────────────────────────────────

function verifyBasicAuth(req: NextApiRequest, res: NextApiResponse): boolean {
  const expectedUser = process.env.DASHBOARD_USERNAME || 'supabase'
  const expectedPass = process.env.DASHBOARD_PASSWORD

  // Fail closed: if basic-auth is enabled but no password is configured,
  // reject rather than silently allowing every request through.
  if (!expectedPass) {
    res.status(500).json({
      error: { message: 'SUPERBASE2_AUTH is enabled but DASHBOARD_PASSWORD is not set' },
    })
    return false
  }

  const authHeader = req.headers.authorization
  if (!authHeader || !authHeader.startsWith('Basic ')) {
    res.setHeader('WWW-Authenticate', 'Basic realm="SuperBase²"')
    res.status(401).json({ error: { message: 'Authentication required' } })
    return false
  }

  const decoded = Buffer.from(authHeader.slice(6), 'base64').toString('utf-8')
  const colonIndex = decoded.indexOf(':')
  if (colonIndex === -1) {
    res.status(401).json({ error: { message: 'Invalid credentials' } })
    return false
  }

  const user = decoded.slice(0, colonIndex)
  const pass = decoded.slice(colonIndex + 1)

  // Compare SHA-256 digests so both operands are fixed-length: this avoids the
  // length side-channel that a raw length check before timingSafeEqual leaks.
  const userMatch = crypto.timingSafeEqual(sha256(user), sha256(expectedUser))
  const passMatch = crypto.timingSafeEqual(sha256(pass), sha256(expectedPass))

  if (!userMatch || !passMatch) {
    res.status(401).json({ error: { message: 'Invalid credentials' } })
    return false
  }

  return true
}

function sha256(value: string): Buffer {
  return crypto.createHash('sha256').update(value).digest()
}

// ── CSRF protection ──────────────────────────────────────────────────────────

/**
 * CSRF protection for mutating requests (POST, PATCH, DELETE, PUT).
 *
 * Always active. A mutating request is accepted when EITHER:
 *   - its Origin (or Referer) matches the configured public URL — covers the
 *     stock Studio UI, which cannot send a custom header; or
 *   - it carries a valid double-submit token — covers the sb2 dashboard page.
 *
 * A forged cross-site request has a foreign Origin and no token, so it is
 * rejected. Safe methods always pass and seed the token cookie.
 */
export function checkCsrf(req: NextApiRequest, res: NextApiResponse): boolean {
  const safeMethods = new Set(['GET', 'HEAD', 'OPTIONS'])

  // Same-origin requests are not CSRF: a cross-site attacker cannot set the
  // Origin header to our public URL. This is what lets the stock Studio UI
  // (which doesn't send the sb2 token) mutate storage/auth/pg-meta safely.
  if (!safeMethods.has(req.method || '') && isSameOrigin(req)) {
    return true
  }

  const csrfCookie = parseCookie(req.headers.cookie || '', 'sb2_csrf')

  if (!csrfCookie) {
    const token = crypto.randomBytes(32).toString('hex')
    const isHttps =
      process.env.NODE_ENV === 'production' ||
      req.headers['x-forwarded-proto'] === 'https'
    res.setHeader(
      'Set-Cookie',
      `sb2_csrf=${token}; Path=/; SameSite=Strict; Max-Age=86400${isHttps ? '; Secure' : ''}`
    )
    if (safeMethods.has(req.method || '')) return true
    res.status(403).json({ error: { message: 'CSRF token missing. Retry the request.' } })
    return false
  }

  if (safeMethods.has(req.method || '')) return true

  const csrfHeader = req.headers['x-sb2-csrf'] as string | undefined
  const headerBuf = Buffer.from(csrfHeader || '')
  const cookieBuf = Buffer.from(csrfCookie)
  const csrfMatch =
    headerBuf.length === cookieBuf.length && crypto.timingSafeEqual(headerBuf, cookieBuf)
  if (!csrfHeader || !csrfMatch) {
    res.status(403).json({ error: { message: 'CSRF token mismatch' } })
    return false
  }

  return true
}

function parseCookie(cookieHeader: string, name: string): string | undefined {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = cookieHeader.match(new RegExp(`(?:^|;\\s*)${escapedName}=([^;]+)`))
  return match?.[1]
}

/**
 * True when the request's Origin (or Referer fallback) matches an allowed
 * origin derived from SUPABASE_PUBLIC_URL / API_EXTERNAL_URL.
 *
 * Comparing against the configured public URL (not req.headers.host) is
 * deliberate: behind Kong the upstream Host is the internal `studio:3000`,
 * so a host-based comparison would never match. When no public URL is
 * configured (e.g. bare local dev) there is nothing to compare against, so
 * this returns false and the request must fall back to the token check.
 */
function isSameOrigin(req: NextApiRequest): boolean {
  const allowed = new Set<string>()
  for (const envUrl of [process.env.SUPABASE_PUBLIC_URL, process.env.API_EXTERNAL_URL]) {
    if (!envUrl) continue
    try {
      allowed.add(new URL(envUrl).origin)
    } catch {
      // Malformed env URL — ignore
    }
  }
  if (allowed.size === 0) return false

  const source = (req.headers.origin as string | undefined) || (req.headers.referer as string | undefined)
  if (!source) return false
  try {
    return allowed.has(new URL(source).origin)
  } catch {
    return false
  }
}
