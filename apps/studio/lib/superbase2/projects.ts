/**
 * SuperBase² — project manifest reader/writer.
 *
 * The manifest is a JSON file that bridges the CLI tooling (superbase2.sh)
 * and the Studio UI. Both read/write the same file.
 *
 * Location is set via SUPERBASE2_MANIFEST env var, defaulting to
 * /etc/superbase2/projects.json (mounted from docker/superbase2/projects.json).
 */

import crypto from 'crypto'
import fs from 'fs'
import path from 'path'

import { isValidProjectName } from './db'

const MANIFEST_PATH =
  process.env.SUPERBASE2_MANIFEST || '/etc/superbase2/projects.json'

const LOCK_PATH = MANIFEST_PATH + '.lock'
const LOCK_STALE_MS = 10_000 // Consider lock stale after 10 seconds

/** Per-project services that can be individually disabled.
 *  auth and rest are required (PostgREST + GoTrue are core to Supabase).
 *  meta is required for the Studio table editor.
 *  realtime, storage, and functions can be toggled off. */
export const OPTIONAL_SERVICES = ['realtime', 'storage', 'functions'] as const
export type OptionalService = typeof OPTIONAL_SERVICES[number]

export interface MultiProject {
  ref: string
  name: string
  db: string
  jwt_secret: string
  anon_key: string
  service_role_key: string
  status: string
  created_at: string
  // Services that are explicitly disabled for this project.
  // If undefined or empty, all services are enabled (default).
  disabled_services?: OptionalService[]
  // Secondary secrets — stored in manifest so disk-state reconstruction
  // doesn't regenerate them (which would break running services).
  // Optional for backward compatibility with older manifests.
  secret_key_base?: string
  pg_meta_crypto_key?: string
  s3_access_key_id?: string
  s3_access_key_secret?: string
}

interface Manifest {
  projects: MultiProject[]
}

/**
 * Try to acquire the file lock once (non-blocking).
 * Returns true if acquired, false if the lock is held by another process.
 * Breaks stale locks older than LOCK_STALE_MS using rename-then-unlink
 * to avoid TOCTOU races (two processes both detecting and deleting a stale lock).
 */
function tryAcquireLock(retries: number = 1): boolean {
  try {
    const fd = fs.openSync(LOCK_PATH, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY)
    fs.writeSync(fd, `${process.pid}:${Date.now()}`)
    fs.closeSync(fd)
    return true
  } catch (err: any) {
    if (err.code !== 'EEXIST') throw err
    if (retries <= 0) return false

    // Check for stale lock
    try {
      const content = fs.readFileSync(LOCK_PATH, 'utf-8')
      const timestamp = parseInt(content.split(':')[1] || '0', 10)
      if (Date.now() - timestamp > LOCK_STALE_MS) {
        // Rename to a unique temp name before unlinking — avoids the race where
        // two processes both detect the same stale lock and one deletes a fresh lock.
        const stalePath = `${LOCK_PATH}.stale.${process.pid}`
        try {
          fs.renameSync(LOCK_PATH, stalePath)
          fs.unlinkSync(stalePath)
        } catch {
          // Another process beat us to it — fine, just retry
        }
        return tryAcquireLock(retries - 1)
      }
    } catch {
      // Lock file disappeared — retry once
      return tryAcquireLock(retries - 1)
    }

    return false
  }
}

/** Sleep without blocking the event loop. */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/**
 * Acquire an advisory file lock using O_EXCL (atomic create-if-not-exists).
 * Retries with non-blocking sleeps, and breaks stale locks older than LOCK_STALE_MS.
 */
async function acquireLock(maxWaitMs: number = 5000): Promise<void> {
  const start = Date.now()
  while (true) {
    if (tryAcquireLock()) return

    if (Date.now() - start > maxWaitMs) {
      throw new Error('Timed out waiting for manifest lock')
    }

    await sleep(50)
  }
}

function releaseLock(): void {
  try {
    fs.unlinkSync(LOCK_PATH)
  } catch {
    // Already released — acceptable
  }
}

function readManifest(): Manifest {
  try {
    const raw = fs.readFileSync(MANIFEST_PATH, 'utf-8')
    const parsed = JSON.parse(raw)
    if (!parsed || !Array.isArray(parsed.projects)) {
      console.error(`[SuperBase²] Manifest at ${MANIFEST_PATH} has invalid structure, treating as empty`)
      return { projects: [] }
    }
    return parsed
  } catch (err: any) {
    if (err.code === 'ENOENT') {
      // File doesn't exist yet — normal on first boot
      return { projects: [] }
    }
    console.error(`[SuperBase²] Failed to read manifest at ${MANIFEST_PATH}:`, err.message)
    return { projects: [] }
  }
}

function writeManifest(manifest: Manifest): void {
  const dir = path.dirname(MANIFEST_PATH)
  try {
    fs.mkdirSync(dir, { recursive: true })
  } catch {
    // Directory already exists — fine
  }
  // Write to temp file first, then rename for atomic replacement.
  // Mode 0o600: only the owner (Studio process) can read/write the manifest
  // since it contains JWT secrets and API keys.
  const tmpPath = MANIFEST_PATH + '.tmp'
  fs.writeFileSync(tmpPath, JSON.stringify(manifest, null, 2), { encoding: 'utf-8', mode: 0o600 })
  fs.renameSync(tmpPath, MANIFEST_PATH)
}

/**
 * Perform a locked read-modify-write on the manifest.
 * Ensures concurrent API requests don't lose writes.
 */
async function withManifestLock<T>(fn: (manifest: Manifest) => { manifest: Manifest; result: T }): Promise<T> {
  await acquireLock()
  try {
    const current = readManifest()
    const { manifest, result } = fn(current)
    writeManifest(manifest)
    return result
  } finally {
    releaseLock()
  }
}

export function listProjects(): MultiProject[] {
  return readManifest().projects
}

export function getProject(ref: string): MultiProject | undefined {
  return readManifest().projects.find((p) => p.ref === ref)
}

/** Project refs are 20-char hex strings (from crypto.randomBytes(10).toString('hex')). */
export function isValidProjectRef(ref: string): boolean {
  return /^[a-f0-9]{20}$/.test(ref)
}

/**
 * Atomically check for duplicate name and add the project under a single lock.
 * Returns true if added, false if a project with the same name already exists.
 */
export async function addProjectIfNotExists(project: MultiProject): Promise<boolean> {
  return withManifestLock((manifest) => {
    if (manifest.projects.some((p) => p.name === project.name || p.db === project.db)) {
      return { manifest, result: false }
    }
    manifest.projects.push(project)
    return { manifest, result: true }
  })
}

export async function updateProjectName(ref: string, newName: string): Promise<boolean> {
  // Validate name before acquiring lock
  if (!isValidProjectName(newName)) {
    throw new Error(`Invalid project name: '${newName}'`)
  }
  return withManifestLock((manifest) => {
    const project = manifest.projects.find((p) => p.ref === ref)
    if (!project) return { manifest, result: false }
    if (manifest.projects.some((p) => p.ref !== ref && p.name === newName)) {
      return { manifest, result: false }
    }
    project.name = newName
    return { manifest, result: true }
  })
}

export async function updateDisabledServices(ref: string, disabled: OptionalService[]): Promise<boolean> {
  return withManifestLock((manifest) => {
    const project = manifest.projects.find((p) => p.ref === ref)
    if (!project) return { manifest, result: false }
    project.disabled_services = disabled.length > 0 ? disabled : undefined
    return { manifest, result: true }
  })
}

export async function removeProject(ref: string): Promise<void> {
  await withManifestLock((manifest) => {
    manifest.projects = manifest.projects.filter((p) => p.ref !== ref)
    return { manifest, result: undefined }
  })
}

// ── Key generation (mirrors docker/superbase2/superbase2.sh) ──

function base64UrlEncode(buffer: Buffer): string {
  return buffer.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function generateJwt(role: string, secret: string): string {
  const header = { alg: 'HS256', typ: 'JWT' }
  const now = Math.floor(Date.now() / 1000)
  const payload = {
    role,
    iss: 'supabase',
    iat: now,
    exp: now + 5 * 365 * 24 * 3600, // 5 years
  }

  const headerB64 = base64UrlEncode(Buffer.from(JSON.stringify(header)))
  const payloadB64 = base64UrlEncode(Buffer.from(JSON.stringify(payload)))
  const signedContent = `${headerB64}.${payloadB64}`
  const signature = base64UrlEncode(
    crypto.createHmac('sha256', secret).update(signedContent).digest()
  )

  return `${signedContent}.${signature}`
}

export function generateProjectSecrets(name: string) {
  const ref = crypto.randomBytes(10).toString('hex')
  const jwtSecret = crypto.randomBytes(32).toString('base64')
  const anonKey = generateJwt('anon', jwtSecret)
  const serviceRoleKey = generateJwt('service_role', jwtSecret)
  // Validation already rejects hyphens/symbols — no fallback transform needed.
  const dbName = `project_${name}`

  return {
    ref,
    name,
    db: dbName,
    jwt_secret: jwtSecret,
    anon_key: anonKey,
    service_role_key: serviceRoleKey,
    status: 'ACTIVE_HEALTHY',
    created_at: new Date().toISOString(),
    // Secondary secrets — persisted in manifest so they survive disk-state reconstruction
    secret_key_base: crypto.randomBytes(48).toString('base64'),
    pg_meta_crypto_key: crypto.randomBytes(24).toString('base64'),
    s3_access_key_id: crypto.randomBytes(16).toString('hex'),
    s3_access_key_secret: crypto.randomBytes(32).toString('hex'),
  } satisfies MultiProject
}

/**
 * Check if SuperBase² mode is enabled.
 * Used by middleware and API routes.
 */
export function isSuperBase2Enabled(): boolean {
  // Default to enabled — anyone installing SuperBase² wants multi-project mode.
  // Set SUPERBASE2_ENABLED=false to explicitly disable.
  return process.env.SUPERBASE2_ENABLED !== 'false'
}
