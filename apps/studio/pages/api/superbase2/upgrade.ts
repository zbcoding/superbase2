import type { NextApiRequest, NextApiResponse } from 'next'
import fs from 'fs'
import path from 'path'
import { requireAuth } from 'lib/superbase2/auth'
import { isSuperBase2Enabled } from 'lib/superbase2/projects'

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
  current: string
  latest: string | null
  updateAvailable: boolean
}

const COMPOSE_PATH =
  process.env.SUPERBASE2_COMPOSE_FILE || '/etc/superbase2/docker-compose.coolify.yml'

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

  for (const line of content.split('\n')) {
    // Detect top-level 'services:' key (no indent) — allow trailing comments
    if (/^services:\s*(#.*)?$/.test(line)) {
      inServices = true
      continue
    }

    // Another top-level key ends the services block
    if (inServices && /^\S/.test(line) && !line.startsWith('#')) {
      inServices = false
      currentService = null
      continue
    }

    if (!inServices) continue

    // Service definition: one indent level (2 spaces or 1 tab) + name + colon
    // Allow trailing comments or whitespace
    const svcMatch = line.match(/^(?:  |\t)([a-zA-Z0-9_-]+):\s*(#.*)?$/)
    if (svcMatch) {
      currentService = svcMatch[1]
      continue
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
  // Extract org/repo and current tag prefix from image string
  // e.g. "supabase/gotrue:v2.186.0" → repo="supabase/gotrue", prefix="v"
  const [repo, currentTag] = image.split(':')
  const prefix = currentTag?.match(/^(v?)\d/)?.[1] || ''

  try {
    // Fetch recent tags from Docker Hub, sorted by last_updated
    const res = await fetch(
      `https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=25&ordering=last_updated`,
      { signal: AbortSignal.timeout(5000) }
    )

    if (!res.ok) return null

    const data = await res.json()
    const tags: { name: string }[] = data.results
    if (!Array.isArray(tags) || tags.length === 0) return null

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
  } catch {
    return null
  }
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (!isSuperBase2Enabled()) {
    return res.status(404).json({ error: { message: 'SuperBase² is not enabled' } })
  }
  if (!requireAuth(req, res)) return

  if (req.method !== 'GET') {
    res.setHeader('Allow', ['GET'])
    return res.status(405).json({ error: { message: `Method ${req.method} Not Allowed` } })
  }

  // Validate compose path doesn't escape expected directory
  const composePath = path.resolve(COMPOSE_PATH)
  if (composePath.includes('..')) {
    return res.status(500).json({ error: { message: 'Invalid compose file path' } })
  }

  const currentImages = parseComposeImages(composePath)

  if (Object.keys(currentImages).length === 0) {
    return res.status(500).json({
      error: { message: 'Could not read compose file' },
    })
  }

  // Check all images in parallel
  const results: ImageStatus[] = await Promise.all(
    Object.entries(currentImages).map(async ([service, currentImage]) => {
      const latest = await fetchLatestTag(currentImage)
      const currentTag = currentImage.split(':')[1]
      const latestTag = latest?.split(':')[1] ?? null

      // Compare version cores (strip SHA suffix) to avoid false positives
      // where the same version has a different SHA rebuild
      const currentCore = currentTag?.replace(/-sha-[a-f0-9]+$/, '') ?? ''
      const latestCore = latestTag?.replace(/-sha-[a-f0-9]+$/, '') ?? ''

      return {
        service,
        current: currentTag,
        latest: latestTag,
        updateAvailable: latestTag !== null && latestCore !== currentCore && compareSemver(latestCore, currentCore) > 0,
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
          'docker compose -f docker-compose.coolify.yml pull',
          'docker compose -f docker-compose.coolify.yml up -d',
        ]
      : null,
  })
}
