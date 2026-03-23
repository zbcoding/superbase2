/**
 * SuperBase² — authentication and CSRF protection for API routes.
 *
 * Defense-in-depth: Studio is behind Kong's basic-auth plugin, so in normal
 * deployment the user is already authenticated by the time requests reach
 * Next.js. However, if someone exposes port 3000 directly (or bypasses Kong),
 * these checks prevent unauthorized access.
 *
 * Auth: validates Basic auth header against DASHBOARD_USERNAME / DASHBOARD_PASSWORD env vars.
 * CSRF: on GET requests sets an httpOnly cookie; mutating requests must echo it back via header.
 */

import crypto from 'crypto'
import type { NextApiRequest, NextApiResponse } from 'next'

/**
 * Check authentication. Returns true if the request is authorized.
 * If unauthorized, sends 401 and returns false — caller should return immediately.
 *
 * When SUPERBASE2_AUTH=false (e.g. local dev), auth is skipped entirely.
 */
export function requireAuth(req: NextApiRequest, res: NextApiResponse): boolean {
  // Allow disabling auth for local development
  if (process.env.SUPERBASE2_AUTH === 'false') return true

  const expectedUser = process.env.DASHBOARD_USERNAME || 'supabase'
  const expectedPass = process.env.DASHBOARD_PASSWORD

  // If no password is configured, auth cannot be enforced — allow through
  // (relies on Kong for protection in this case).
  if (!expectedPass) return true

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

  // Constant-time comparison to prevent timing attacks.
  // Use byte length (UTF-8) for the pre-check, not JS string length, so that
  // multibyte characters don't cause timingSafeEqual to throw on length mismatch.
  const userBuf = Buffer.from(user)
  const expectedUserBuf = Buffer.from(expectedUser)
  const passBuf = Buffer.from(pass)
  const expectedPassBuf = Buffer.from(expectedPass)
  const userMatch =
    userBuf.length === expectedUserBuf.length &&
    crypto.timingSafeEqual(userBuf, expectedUserBuf)
  const passMatch =
    passBuf.length === expectedPassBuf.length &&
    crypto.timingSafeEqual(passBuf, expectedPassBuf)

  if (!userMatch || !passMatch) {
    res.status(401).json({ error: { message: 'Invalid credentials' } })
    return false
  }

  return true
}

/**
 * Validate CSRF token for mutating requests (POST, PATCH, DELETE, PUT).
 * GET/HEAD/OPTIONS are exempt — they set the CSRF cookie instead.
 *
 * Flow:
 * 1. On any request, if no sb2_csrf cookie exists, set one.
 * 2. For mutating requests, require X-SB2-CSRF header matching the cookie.
 *
 * Returns true if safe to proceed. Sends 403 and returns false on CSRF failure.
 */
export function checkCsrf(req: NextApiRequest, res: NextApiResponse): boolean {
  // Allow disabling CSRF for local dev or API-only usage
  if (process.env.SUPERBASE2_AUTH === 'false') return true

  const safeMethods = new Set(['GET', 'HEAD', 'OPTIONS'])
  const csrfCookie = parseCookie(req.headers.cookie || '', 'sb2_csrf')

  // Set CSRF cookie if not present
  if (!csrfCookie) {
    const token = crypto.randomBytes(32).toString('hex')
    // NOTE: intentionally NOT HttpOnly — the double-submit cookie pattern requires
    // client JS to read this cookie and echo it back in the X-SB2-CSRF header.
    // SameSite=Strict prevents cross-origin requests from carrying the cookie at all,
    // which is the primary CSRF defense. HttpOnly would make the header unreadable
    // by the browser and break all mutating requests from the /sb2 dashboard.
    const isHttps =
      process.env.NODE_ENV === 'production' ||
      req.headers['x-forwarded-proto'] === 'https'
    res.setHeader(
      'Set-Cookie',
      `sb2_csrf=${token}; Path=/; SameSite=Strict; Max-Age=86400${isHttps ? '; Secure' : ''}`
    )
    // For safe methods, proceed even without token (it's being set now)
    if (safeMethods.has(req.method || '')) return true
    // For mutating methods, reject — client must retry with the cookie
    res.status(403).json({ error: { message: 'CSRF token missing. Retry the request.' } })
    return false
  }

  // Safe methods are always allowed
  if (safeMethods.has(req.method || '')) return true

  // Mutating methods must include X-SB2-CSRF header matching the cookie.
  // Use constant-time comparison to prevent timing attacks on the token.
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
  // Escape regex metacharacters in the cookie name to prevent injection.
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = cookieHeader.match(new RegExp(`(?:^|;\\s*)${escapedName}=([^;]+)`))
  return match?.[1]
}
