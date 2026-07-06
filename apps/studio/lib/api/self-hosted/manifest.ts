import fs from 'fs'

type Sb2Project = {
  ref: string
  db: string
  name?: string
}

type ManifestCache = {
  mtimeMs: number
  byRef: Map<string, Sb2Project>
}

const MANIFEST_PATH = process.env.SUPERBASE2_MANIFEST || '/etc/superbase2/projects.json'

let cache: ManifestCache | null = null

export function getProjectByRef(ref: string | string[] | undefined): Sb2Project | null {
  if (typeof ref !== 'string' || ref.length === 0) return null
  try {
    const stat = fs.statSync(MANIFEST_PATH)
    if (!cache || cache.mtimeMs !== stat.mtimeMs) {
      const raw = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8')) as { projects?: Sb2Project[] }
      const byRef = new Map<string, Sb2Project>()
      for (const p of raw.projects ?? []) {
        if (p?.ref && p?.db) byRef.set(p.ref, p)
      }
      cache = { mtimeMs: stat.mtimeMs, byRef }
    }
    return cache.byRef.get(ref) ?? null
  } catch {
    return null
  }
}
