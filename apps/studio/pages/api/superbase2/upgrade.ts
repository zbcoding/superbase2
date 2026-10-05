import type { NextApiRequest, NextApiResponse } from 'next'

import { AgentUnavailableError, getMainStackImages } from '@/lib/superbase2/agent-client'
import { requireAuth } from '@/lib/superbase2/auth'
import { isSuperBase2Enabled } from '@/lib/superbase2/projects'

/**
 * SuperBase² upgrade check endpoint.
 *
 * GET  /api/superbase2/upgrade — check for upstream Supabase updates
 *
 * Compares the images the main stack is running (read from Docker by the
 * sb2-agent) with the versions upstream pins in its self-hosting compose
 * files. Upstream's pins are versions Supabase tested together; the newest
 * tag on Docker Hub is not, and can be a major version the stack can't
 * run (e.g. a Postgres major upgrade).
 */

interface ImageStatus {
  service: string
  current: string | null
  latest: string | null
  updateAvailable: boolean
}

const UPSTREAM_COMPOSE_BASE = 'https://raw.githubusercontent.com/supabase/supabase/master/docker'

// Every upstream compose file that pins an image the SuperBase² stacks run.
// pg15/pg17 both pin supabase/postgres; the one matching the running major wins.
const UPSTREAM_COMPOSE_FILES = [
  'docker-compose.yml',
  'docker-compose.kong.yml',
  'docker-compose.logs.yml',
  'docker-compose.pg15.yml',
  'docker-compose.pg17.yml',
]

function splitImage(image: string): { repo: string; tag: string | null } {
  const withoutDigest = image.split('@')[0]
  const colon = withoutDigest.lastIndexOf(':')
  // A colon before the last slash is a registry port, not a tag.
  if (colon === -1 || colon < withoutDigest.lastIndexOf('/')) {
    return { repo: withoutDigest, tag: null }
  }
  return { repo: withoutDigest.slice(0, colon), tag: withoutDigest.slice(colon + 1) }
}

/** repo → every tag upstream pins for it. */
async function fetchUpstreamPins(): Promise<Map<string, string[]>> {
  const pins = new Map<string, string[]>()
  const files = await Promise.all(
    UPSTREAM_COMPOSE_FILES.map(async (file) => {
      const res = await fetch(`${UPSTREAM_COMPOSE_BASE}/${file}`, {
        signal: AbortSignal.timeout(5000),
      })
      if (!res.ok) throw new Error(`Fetching upstream ${file} failed: HTTP ${res.status}`)
      return res.text()
    })
  )
  for (const content of files) {
    for (const match of content.matchAll(/^\s*image:\s*['"]?([^\s'"#]+)/gm)) {
      const { repo, tag } = splitImage(match[1])
      if (!tag) continue
      pins.set(repo, [...(pins.get(repo) ?? []), tag])
    }
  }
  return pins
}

function versionParts(tag: string): number[] {
  return tag
    .replace(/^v/, '')
    .replace(/-.*$/, '')
    .split('.')
    .map((p) => parseInt(p, 10) || 0)
}

/** >0 if a > b, <0 if a < b, 0 if equal. */
function compareVersions(a: string, b: string): number {
  const pa = versionParts(a)
  const pb = versionParts(b)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0)
    if (diff !== 0) return diff
  }
  return 0
}

/**
 * Upstream's pin for the same major version as `current`, or null. A major
 * version change (Postgres 15 → 17, or a 1.x → 2.x service) needs a migration
 * and is never offered as a routine update.
 */
function upstreamPinFor(current: string, candidates: string[]): string | null {
  const major = versionParts(current)[0]
  const sameMajor = candidates.filter((tag) => versionParts(tag)[0] === major)
  if (sameMajor.length === 0) return null
  return sameMajor.sort((a, b) => compareVersions(b, a))[0]
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

  const composeCmd =
    process.env.SUPERBASE2_COMPOSE_CMD ||
    'docker compose -f docker-compose.yml -f docker-compose.superbase2.yml'

  // Coolify generates the compose file on every deploy and stores it outside the
  // container, so the git-pull + `docker compose up` steps are wrong there: the
  // path in SUPERBASE2_COMPOSE_CMD isn't reachable, and a manual `up -d` would be
  // undone by the next redeploy. Coolify always injects COOLIFY_RESOURCE_UUID.
  const isCoolifyDeployment = Boolean(process.env.COOLIFY_RESOURCE_UUID)

  let currentImages: Record<string, string>
  try {
    currentImages = await getMainStackImages()
  } catch (err) {
    const message =
      err instanceof AgentUnavailableError ? err.message : 'Could not read running images'
    return res.status(503).json({ error: { message } })
  }

  let pins: Map<string, string[]>
  try {
    pins = await fetchUpstreamPins()
  } catch (err) {
    return res.status(502).json({
      error: { message: err instanceof Error ? err.message : 'Could not fetch upstream versions' },
    })
  }

  const results: ImageStatus[] = []
  for (const [service, image] of Object.entries(currentImages)) {
    const { repo, tag } = splitImage(image)
    const candidates = pins.get(repo)
    // Images upstream doesn't pin (the SuperBase² Studio and agent, alpine
    // one-shots) have nothing to compare against.
    if (!tag || !candidates) continue
    const latest = upstreamPinFor(tag, candidates)
    results.push({
      service,
      current: tag,
      latest,
      updateAvailable: latest !== null && compareVersions(latest, tag) > 0,
    })
  }

  const hasUpdates = results.some((r) => r.updateAvailable)

  return res.status(200).json({
    hasUpdates,
    services: results.sort((a, b) => a.service.localeCompare(b.service)),
    upgradeInstructions:
      hasUpdates && !isCoolifyDeployment
        ? ['git pull upstream master', `${composeCmd} pull`, `${composeCmd} up -d`]
        : null,
    // Rendered as prose, not as a copyable command block — on Coolify the upgrade
    // is a button in its UI, so there is nothing to paste into a shell. The tags
    // are pinned in docker-compose.coolify.yml, so redeploying alone re-pulls the
    // same versions.
    upgradeNote:
      hasUpdates && isCoolifyDeployment
        ? 'Update the image tags in docker/docker-compose.coolify.yml to these versions, push, and redeploy in Coolify. Running projects switch to the new images automatically once the stack is up.'
        : null,
  })
}
