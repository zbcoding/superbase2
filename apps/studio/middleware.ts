import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'
import { DEFAULT_ORG_SLUG } from 'lib/superbase2/response-helpers'

/**
 * SuperBase² — multi-project middleware for self-hosted Supabase.
 *
 * When SUPERBASE2_ENABLED=true, this middleware intercepts the
 * platform API calls and rewrites them to the SuperBase² handlers.
 *
 * This is the ONLY integration point with the existing Studio codebase.
 * Because middleware.ts is a new file (Studio doesn't have one), it
 * won't conflict when pulling upstream Supabase updates.
 *
 * If Supabase adds their own middleware.ts in the future, you'd merge
 * this logic into theirs — but that's a one-time, straightforward merge.
 */

// API paths to intercept and their SuperBase² replacements.
// Order matters: more specific patterns must come before general ones.
const API_REWRITES: [RegExp, string][] = [
  // Project sub-routes (settings, databases, config, etc.)
  // Must come BEFORE the single-project match to avoid being swallowed.
  // The (.+) requires at least one char after the slash to avoid matching
  // a bare trailing slash (which should hit the project detail handler).
  [
    /^\/api\/platform\/projects\/([^/]+)\/(.+)$/,
    '/api/superbase2/projects/$1/$2',
  ],
  // Projects list + create
  [/^\/api\/platform\/projects\/?$/, '/api/superbase2/projects'],
  // Project detail by ref
  [/^\/api\/platform\/projects\/([^/]+)\/?$/, '/api/superbase2/projects/$1'],
  // Org projects list (sidebar switcher)
  [
    /^\/api\/platform\/organizations\/([^/]+)\/projects\/?$/,
    '/api/superbase2/organizations/$1/projects',
  ],
  // Org sub-routes (billing, members, etc.) — catch-all so Studio pages
  // don't fall through to stock self-hosted handlers that return single-project data.
  // Must come AFTER the specific /projects match above.
  [
    /^\/api\/platform\/organizations\/([^/]+)\/(.+)$/,
    '/api/superbase2/projects/_org-catchall',
  ],
  // Organizations list
  [/^\/api\/platform\/organizations\/?$/, '/api/superbase2/organizations'],
  // Single org detail
  [/^\/api\/platform\/organizations\/([^/]+)\/?$/, '/api/superbase2/organizations'],
  // Profile (embeds projects)
  [/^\/api\/platform\/profile\/?$/, '/api/superbase2/profile'],
  // Config routes (gotrue, etc.)
  [/^\/api\/platform\/config\/(.+)$/, '/api/superbase2/projects/_config-catchall'],
]

export function middleware(request: NextRequest) {
  try {
    // Default to enabled — disable explicitly with SUPERBASE2_ENABLED=false
    if (process.env.SUPERBASE2_ENABLED === 'false') {
      return NextResponse.next()
    }

    const { pathname } = request.nextUrl

    // Rewrite matching API routes to SuperBase² handlers
    for (const [pattern, replacement] of API_REWRITES) {
      if (pattern.test(pathname)) {
        const newPath = pathname.replace(pattern, replacement)
        const url = request.nextUrl.clone()
        url.pathname = newPath
        return NextResponse.rewrite(url)
      }
    }

    // Redirect root to /projects when SuperBase² is enabled
    // (overrides the default redirect to /project/default)
    if (pathname === '/') {
      const url = request.nextUrl.clone()
      url.pathname = `/org/${DEFAULT_ORG_SLUG}`
      return NextResponse.redirect(url)
    }

    return NextResponse.next()
  } catch (err) {
    console.error('[SuperBase²] Middleware error:', err)
    // Fail open to stock Supabase behavior
    return NextResponse.next()
  }
}

export const config = {
  matcher: [
    // Only run on API platform routes, root, and SuperBase² pages
    '/',
    '/api/platform/:path*',
    '/sb2/:path*',
  ],
}
