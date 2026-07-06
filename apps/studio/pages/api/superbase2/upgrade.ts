import type { NextApiRequest, NextApiResponse } from 'next'
import fs from 'fs'
import path from 'path'
import { requireAuth } from '@/lib/superbase2/auth'
import { isSuperBase2Enabled } from '@/lib/superbase2/projects'

/**
 * SuperBase² upgrade check endpoint.
 *
 * GET  /api/superbase2/upgrade — check for upstream Supabase updates
 *
 * Parses the compose file at runtime to discover current image tags,
 * then checks Docker Hub for newer versions.
 */

interface ImageStatus {
  service: string
  current: string | null
  latest: string | null
  updateAvailable: boolean
  error?: string
}

const COMPOSE_PATH =
  process.env.SUPERBASE2_COMPOSE_FILE || '/etc/superbase2/docker-compose.yml'

// Services to skip when checking for updates (not real Supabase services)
const SKIP_SERVICES = new Set(['superbase2-init'])

/**
 * Parse service→image mappings from a docker-compose YAML file.
 * Uses a simple line-by-line parser to avoid requiring a YAML library.
 *
 * Handles both spaces (2-space indent) and tabs. Tracks the `services:`
 * block to avoid matching non-service keys.
 */
function parseComposeImages(composePath: string): Record<string, string> {
  let content: string
  try {
    content = fs.readFileSync(composePath, 'utf-8')
  } catch {
    return {}
  }

  const images: Record<string, string> = {}
  let currentService: string | null = null
  let inServices = false
  // Detected indent string for service names (e.g. "  " or "    " or "\t").
  // Derived from the first service line so both 2-space (standalone compose)
  // and 4-space (Coolify-generated compose) files parse correctly.
  let serviceIndent: string | null = null

  for (const line of content.split('\n')) {
    // Detect top-level 'services:' key (no indent) — allow trailing comments
    if (/^services:\s*(#.*)?$/.test(line)) {
      inServices = true
      serviceIndent = null
      continue
    }

    // Another top-level key ends the services block
    if (inServices && /^\S/.test(line) && !line.startsWith('#')) {
      inServices = false
      currentService = null
      serviceIndent = null
      continue
    }

    if (!inServices) continue

    // Service definition: exactly one indent level + name + colon (no value).
    // Auto-detect the indent width from the first service line so 2-space
    // (standalone compose) and 4-space (Coolify-generated) files both work.
    if (serviceIndent === null) {
      const firstSvc = line.match(/^( +|\t)([a-zA-Z0-9_-]+):\s*(#.*)?$/)
      if (firstSvc) serviceIndent = firstSvc[1]
    }
    if (serviceIndent !== null && line.startsWith(serviceIndent)) {
      // Remainder after stripping exactly serviceIndent must be "name:" with no value
      const remainder = line.slice(serviceIndent.length)
      const svcMatch = remainder.match(/^([a-zA-Z0-9_-]+):\s*(#.*)?$/)
      if (svcMatch) {
        currentService = svcMatch[1]
        continue
      }
    }

    // Image line under a service: deeper indent + "image:"
    // Strip inline comments before extracting the image value
    const imgMatch = line.match(/^[ \t]+image:\s*(.+?)(\s+#.*)?$/)
    if (imgMatch && currentService) {
      if (!SKIP_SERVICES.has(currentService)) {
        images[currentService] = imgMatch[1].trim()
      }
      // Reset regardless of skip — prevents stale currentService
      currentService = null
    }
  }

  return images
}

/**
 * Compare two semver-like version strings (e.g. "v2.186.0", "1.37.8").
 * Returns >0 if a > b, <0 if a < b, 0 if equal.
 */
function compareSemver(a: string, b: string): number {
  const parse = (v: string) =>
    v.replace(/^v/, '').split('.').map((p) => {
      const n = parseInt(p, 10)
      return isNaN(n) ? 0 : n
    })
  const pa = parse(a)
  const pb = parse(b)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] || 0) - (pb[i] || 0)
    if (diff !== 0) return diff
  }
  return 0
}

async function fetchLatestTag(image: string): Promise<string | null> {
  // Strip digest suffix (e.g. "@sha256:abc") before splitting on ':',
  // otherwise the repo portion becomes "org/name@sha256" which is an invalid API path.
  const imageWithoutDigest = image.split('@')[0]
  // Extract org/repo and current tag prefix from image string
  // e.g. "supabase/gotrue:v2.186.0" → repo="supabase/gotrue", prefix="v"
  const [repo, currentTag] = imageWithoutDigest.split(':')
  const prefix = currentTag?.match(/^(v?)\d/)?.[1] || ''

  try {
    // Fetch recent tags from Docker Hub, sorted by last_updated
    const res = await fetch(
      `https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=25&ordering=last_updated`,
      { signal: AbortSignal.timeout(5000) }
    )

    if (res.status === 429) throw new Error('rate-limited')
    if (!res.ok) return null

    const data = await res.json()
    if (!data || !Array.isArray(data.results)) return null
    const tags: { name: string }[] = (data.results as unknown[]).filter(
      (t): t is { name: string } => t !== null && typeof t === 'object' && typeof (t as any).name === 'string'
    )
    if (tags.length === 0) return null

    // Filter to version-like tags matching the same prefix pattern.
    // Accepts semver (v1.2.3), CalVer (2026.02.16), and SHA-suffixed tags (2026.02.16-sha-xxx).
    // Excludes "latest", plain SHA tags, and other non-version tags.
    const semverPattern = new RegExp(`^${prefix}\\d+\\.\\d+\\.\\d+(-sha-[a-f0-9]+)?$`)
    const semverTags = tags
      .map((t) => t.name)
      .filter((name) => semverPattern.test(name))
      // Strip SHA suffix for comparison — sort by version part only
      .map((name) => ({ full: name, version: name.replace(/-sha-[a-f0-9]+$/, '') }))

    if (semverTags.length === 0) return null

    // Find the highest version
    semverTags.sort((a, b) => compareSemver(b.version, a.version))
    return `${repo}:${semverTags[0].full}`
  } catch (err) {
    if (err instanceof Error && err.message === 'rate-limited') throw err
    return null
  }
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!(await requireAuth(req, res))) return

  if (req.method !== 'GET') {
    res.setHeader('Allow', ['GET'])
    return res.status(405).json({ error: { message: `Method ${req.method} Not Allowed` } })
  }

  // Validate the raw path before resolving — path.resolve() produces an absolute
  // path that never contains '..', so the check must happen before resolution.
  if (COMPOSE_PATH.includes('..')) {
    return res.status(500).json({ error: { message: 'Invalid compose file path' } })
  }
  const composePath = path.resolve(COMPOSE_PATH)
  const composeCmd = process.env.SUPERBASE2_COMPOSE_CMD ||
    'docker compose -f docker-compose.yml -f docker-compose.superbase2.yml'

  const currentImages = parseComposeImages(composePath)

  if (Object.keys(currentImages).length === 0) {
    return res.status(500).json({
      error: { message: 'Could not read compose file' },
    })
  }

  // Check all images in parallel
  const results: ImageStatus[] = await Promise.all(
    Object.entries(currentImages).map(async ([service, currentImage]) => {
      const currentTag = currentImage.split(':')[1] ?? null
      let latest: string | null = null
      let error: string | undefined

      try {
        latest = await fetchLatestTag(currentImage)
      } catch (err: unknown) {
        error = err instanceof Error && err.message === 'rate-limited'
          ? 'Docker Hub rate limit reached — try again later'
          : 'Failed to fetch latest tag'
      }

      const latestTag = latest?.split(':')[1] ?? null

      // Compare version cores (strip SHA suffix) to avoid false positives
      // where the same version has a different SHA rebuild
      const currentCore = currentTag?.replace(/-sha-[a-f0-9]+$/, '') ?? ''
      const latestCore = latestTag?.replace(/-sha-[a-f0-9]+$/, '') ?? ''

      return {
        service,
        current: currentTag,
        latest: latestTag,
        updateAvailable: currentTag !== null && latestTag !== null && latestCore !== currentCore && compareSemver(latestCore, currentCore) > 0,
        ...(error && { error }),
      }
    })
  )

  const hasUpdates = results.some((r) => r.updateAvailable)

  return res.status(200).json({
    hasUpdates,
    services: results.sort((a, b) => a.service.localeCompare(b.service)),
    upgradeInstructions: hasUpdates
      ? [
          'git pull upstream master',
          `${composeCmd} pull`,
          `${composeCmd} up -d`,
        ]
      : null,
  })
}
