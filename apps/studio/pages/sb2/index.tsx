import { useEffect, useMemo, useState } from 'react'
import Head from 'next/head'
import Link from 'next/link'

/**
 * SuperBase² Dashboard — the main control panel.
 *
 * Accessible at /sb2 when SuperBase² is enabled.
 * Uses a distinct amber/orange accent so it's visually
 * obvious these pages are from SuperBase², not stock Supabase.
 */

interface Project {
  ref: string
  name: string
  status: string
  inserted_at: string
  databases: { identifier: string }[]
}

interface CreatedProject extends Project {
  jwt_secret?: string
  anon_key?: string
  service_role_key?: string
}

interface ServiceInfo {
  name: string
  enabled: boolean
  description: string
}

interface UpgradeInfo {
  hasUpdates: boolean
  services: {
    service: string
    current: string
    latest: string | null
    updateAvailable: boolean
  }[]
  upgradeInstructions: string[] | null
}

const PAGE_SIZE = 24

/** Read the sb2_csrf cookie value for mutating requests. */
function getCsrfToken(): string {
  const match = document.cookie.match(/(?:^|;\s*)sb2_csrf=([^;]+)/)
  return match?.[1] || ''
}

function copyToClipboard(text: string) {
  navigator.clipboard.writeText(text).catch(() => {
    // clipboard API unavailable (e.g. non-HTTPS context)
  })
}

export default function SB2Dashboard() {
  const [projects, setProjects] = useState<Project[]>([])
  const [upgrade, setUpgrade] = useState<UpgradeInfo | null>(null)
  const [loading, setLoading] = useState(true)
  const [creating, setCreating] = useState(false)
  const [deleting, setDeleting] = useState<string | null>(null)
  const [newName, setNewName] = useState('')
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [page, setPage] = useState(0)
  const [createdProject, setCreatedProject] = useState<CreatedProject | null>(null)
  const [copied, setCopied] = useState<string | null>(null)
  const [expandedRef, setExpandedRef] = useState<string | null>(null)
  const [services, setServices] = useState<Record<string, ServiceInfo[]>>({})
  const [togglingService, setTogglingService] = useState(false)
  const [serviceChanged, setServiceChanged] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    const { signal } = controller
    const timeoutId = setTimeout(() => controller.abort(), 10_000)

    Promise.all([
      fetch('/api/superbase2/projects', { signal })
        .then((r) => {
          if (!r.ok) throw new Error(`Failed to fetch projects: ${r.status}`)
          return r.json()
        })
        .then((data) => setProjects(Array.isArray(data) ? data : []))
        .catch((err) => { if (err.name !== 'AbortError') setError(err.message) }),
      fetch('/api/superbase2/upgrade', { signal })
        .then((r) => {
          if (!r.ok) return null
          return r.json()
        })
        .then((data) => setUpgrade(data))
        .catch(() => null),
    ]).finally(() => {
      clearTimeout(timeoutId)
      setLoading(false)
    })

    return () => {
      clearTimeout(timeoutId)
      controller.abort()
    }
  }, [])

  const filteredProjects = useMemo(() => {
    if (!search) return projects
    const q = search.toLowerCase()
    return projects.filter(
      (p) => p.name.toLowerCase().includes(q) || p.ref.toLowerCase().includes(q)
    )
  }, [projects, search])

  const totalPages = Math.ceil(filteredProjects.length / PAGE_SIZE)
  const pagedProjects = filteredProjects.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE)

  const updatableServices = useMemo(
    () => upgrade?.services.filter((s) => s.updateAvailable) ?? [],
    [upgrade]
  )

  // Reset page when search changes
  useEffect(() => { setPage(0) }, [search])

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!newName.trim() || creating) return

    setCreating(true)
    setError('')
    setCreatedProject(null)

    try {
      const res = await fetch('/api/superbase2/projects', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-SB2-CSRF': getCsrfToken(),
        },
        body: JSON.stringify({ name: newName.trim() }),
      })

      if (!res.ok) {
        let message = 'Failed to create project'
        try { message = (await res.json()).error?.message || message } catch {}
        if (res.status === 403) message += ' — refresh the page and try again.'
        setError(message)
        return
      }

      const data = await res.json()

      setProjects((prev) => [...prev, data])
      setNewName('')
      // Show secrets panel if they were returned
      if (data.jwt_secret) {
        setCreatedProject(data)
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Unknown error')
    } finally {
      setCreating(false)
    }
  }

  const handleDelete = async (ref: string, name: string) => {
    if (!confirm(`Delete project '${name}'?\n\nThis drops the database permanently. Stop per-project containers first.`)) {
      return
    }
    setDeleting(ref)
    setError('')

    try {
      const res = await fetch(`/api/superbase2/projects/${ref}`, {
        method: 'DELETE',
        headers: { 'X-SB2-CSRF': getCsrfToken() },
      })
      if (!res.ok) {
        let message = 'Failed to delete project'
        try { message = (await res.json()).error?.message || message } catch {}
        if (res.status === 403) message += ' — refresh the page and try again.'
        setError(message)
        return
      }
      setProjects((prev) => prev.filter((p) => p.ref !== ref))
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Unknown error')
    } finally {
      setDeleting(null)
    }
  }

  const handleExpandServices = async (ref: string) => {
    if (expandedRef === ref) {
      setExpandedRef(null)
      return
    }
    setExpandedRef(ref)
    if (!services[ref]) {
      try {
        const res = await fetch(`/api/superbase2/projects/${ref}/services`)
        if (res.ok) {
          const data = await res.json()
          setServices((prev) => ({ ...prev, [ref]: data.services }))
        }
      } catch {
        // Ignore — services panel just won't load
      }
    }
  }

  const handleToggleService = async (ref: string, serviceName: string, currentlyEnabled: boolean) => {
    setTogglingService(true)
    try {
      const current = services[ref] || []
      const newDisabled = current
        .filter((s) => (s.name === serviceName ? currentlyEnabled : !s.enabled))
        .map((s) => s.name)

      const res = await fetch(`/api/superbase2/projects/${ref}/services`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-SB2-CSRF': getCsrfToken(),
        },
        body: JSON.stringify({ disabled_services: newDisabled }),
      })

      if (res.ok) {
        setServices((prev) => ({
          ...prev,
          [ref]: current.map((s) =>
            s.name === serviceName ? { ...s, enabled: !currentlyEnabled } : s
          ),
        }))
        setServiceChanged(ref)
      }
    } catch {
      // Ignore toggle errors
    } finally {
      setTogglingService(false)
    }
  }

  const handleCopy = (text: string, label: string) => {
    copyToClipboard(text)
    setCopied(label)
    setTimeout(() => setCopied(null), 2000)
  }

  return (
    <>
      <Head>
        <title>SB2 — SuperBase²</title>
      </Head>

      <div style={styles.page}>
        {/* Header */}
        <header style={styles.header} role="banner">
          <div style={styles.headerInner}>
            <div style={styles.logo}>
              <span style={styles.logoIcon} aria-hidden="true">&#x26A1;&#xB2;</span>
              <span style={styles.logoText}>SuperBase²</span>
            </div>
            <nav aria-label="SuperBase² navigation" style={styles.headerLinks}>
              <Link href={projects.length > 0 ? `/project/${projects[0].ref}` : '/sb2'} style={styles.headerLink}>
                Studio →
              </Link>
            </nav>
          </div>
        </header>

        <main style={styles.main} role="main">
          {/* Upgrade banner */}
          {upgrade?.hasUpdates && (
            <div style={styles.upgradeBanner} role="alert">
              <div style={styles.upgradeBannerInner}>
                <span style={styles.upgradeIcon} aria-hidden="true">↑</span>
                <div style={{ flex: 1 }}>
                  <strong>Updates available</strong>
                  <span style={styles.upgradeCount}>
                    {' '}
                    — {updatableServices.length} service
                    {updatableServices.length > 1 ? 's' : ''}
                  </span>
                  <div style={styles.upgradeServices}>
                    {updatableServices.map((s) => (
                      <span key={s.service} style={styles.upgradeChip}>
                        {s.service}: {s.current} → {s.latest}
                      </span>
                    ))}
                  </div>
                  {upgrade.upgradeInstructions && (
                    <div style={{ position: 'relative' as const }}>
                      <pre style={styles.upgradeCode}>
                        {upgrade.upgradeInstructions.join('\n')}
                      </pre>
                      <button
                        onClick={() => handleCopy(upgrade.upgradeInstructions!.join('\n'), 'upgrade')}
                        style={styles.copyBtn}
                        aria-label="Copy upgrade commands"
                        title="Copy commands"
                      >
                        {copied === 'upgrade' ? 'Copied' : 'Copy'}
                      </button>
                    </div>
                  )}
                </div>
              </div>
            </div>
          )}

          {/* Created project secrets (one-time display) */}
          {createdProject && (
            <div style={styles.secretsBanner} role="alert">
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
                <strong>Project '{createdProject.name}' created — save these secrets now!</strong>
                <button
                  onClick={() => setCreatedProject(null)}
                  style={styles.dismissBtn}
                  aria-label="Dismiss secrets panel"
                >
                  Dismiss
                </button>
              </div>
              <p style={{ fontSize: 13, color: SB2_MUTED, marginBottom: 12 }}>
                These secrets are only shown once. Copy them now.
              </p>
              {[
                { label: 'Project Ref', value: createdProject.ref },
                { label: 'JWT Secret', value: createdProject.jwt_secret },
                { label: 'Anon Key', value: createdProject.anon_key },
                { label: 'Service Role Key', value: createdProject.service_role_key },
              ].map(({ label, value }) =>
                value ? (
                  <div key={label} style={styles.secretRow}>
                    <span style={styles.secretLabel}>{label}</span>
                    <code style={styles.secretValue}>{value}</code>
                    <button
                      onClick={() => handleCopy(value, label)}
                      style={styles.copyBtn}
                      aria-label={`Copy ${label}`}
                    >
                      {copied === label ? 'Copied' : 'Copy'}
                    </button>
                  </div>
                ) : null
              )}
            </div>
          )}

          {/* Create project */}
          <section style={styles.section}>
            <h2 style={styles.sectionTitle}>Create Project</h2>
            <form onSubmit={handleCreate} style={styles.createForm} aria-label="Create new project">
              <label htmlFor="sb2-project-name" style={{ position: 'absolute' as const, width: 1, height: 1, overflow: 'hidden', clip: 'rect(0,0,0,0)' }}>
                Project name
              </label>
              <input
                id="sb2-project-name"
                type="text"
                value={newName}
                onChange={(e) => setNewName(e.target.value.replace(/[^a-zA-Z0-9]/g, ''))}
                placeholder="Project name (letters and numbers only)"
                pattern="^[a-zA-Z0-9]{2,48}$"
                title="Only letters and numbers (2-48 chars). No hyphens or underscores."
                style={styles.input}
                disabled={creating}
                minLength={2}
                maxLength={48}
                aria-describedby="sb2-project-hint"
              />
              <button type="submit" style={styles.button} disabled={creating || !newName.trim() || newName.length < 2}>
                {creating ? 'Creating...' : 'Create'}
              </button>
            </form>
            {error && <p style={styles.error} role="alert" aria-live="polite">{error}</p>}
            <p id="sb2-project-hint" style={styles.hint}>
              Creates the database and secrets. Only letters and numbers allowed (no underscores or hyphens — required for Docker DNS). Run{' '}
              <code style={styles.code}>./superbase2.sh up {'<name>'}</code> on the server to start
              the per-project containers.
            </p>
          </section>

          {/* Projects list */}
          <section style={styles.section}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 }}>
              <h2 style={{ ...styles.sectionTitle, marginBottom: 0 }}>
                Projects{' '}
                {!loading && (
                  <span style={styles.count}>{filteredProjects.length}</span>
                )}
              </h2>
              {projects.length > 0 && (
                <input
                  type="text"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="Search projects..."
                  style={{ ...styles.input, flex: 'none', width: 240 }}
                  aria-label="Search projects"
                />
              )}
            </div>

            {loading ? (
              <p style={styles.muted} role="status" aria-live="polite">Loading...</p>
            ) : filteredProjects.length === 0 ? (
              <p style={styles.muted}>
                {search ? 'No projects match your search.' : 'No projects yet. Create one above.'}
              </p>
            ) : (
              <>
                <div style={styles.grid} role="list" aria-label="Projects">
                  {pagedProjects.map((p) => (
                    <div
                      key={p.ref}
                      style={styles.card}
                      role="listitem"
                    >
                      <Link
                        href={`/project/${p.ref}`}
                        style={{ textDecoration: 'none', color: 'inherit', display: 'block' }}
                        aria-label={`Open project ${p.name}`}
                      >
                        <div style={styles.cardHeader}>
                          <span style={styles.cardName}>{p.name}</span>
                          <span
                            style={{
                              ...styles.statusDot,
                              backgroundColor:
                                p.status === 'ACTIVE_HEALTHY' ? '#22c55e' : '#eab308',
                            }}
                            role="img"
                            aria-label={p.status === 'ACTIVE_HEALTHY' ? 'Healthy' : 'Warning'}
                          />
                        </div>
                      </Link>
                      <div style={styles.cardMeta}>
                        <span style={styles.cardRef}>{p.ref}</span>
                        <button
                          onClick={() => handleCopy(p.ref, `ref-${p.ref}`)}
                          style={styles.cardCopyBtn}
                          aria-label={`Copy project ref ${p.ref}`}
                          title="Copy ref"
                        >
                          {copied === `ref-${p.ref}` ? 'Copied' : 'Copy'}
                        </button>
                        <button
                          onClick={() => handleExpandServices(p.ref)}
                          style={styles.cardCopyBtn}
                          aria-label={`Toggle services for ${p.name}`}
                          title="Configure services"
                        >
                          Services
                        </button>
                        <button
                          onClick={() => handleDelete(p.ref, p.name)}
                          style={styles.deleteBtn}
                          disabled={deleting === p.ref}
                          aria-label={`Delete project ${p.name}`}
                        >
                          {deleting === p.ref ? 'Deleting...' : 'Delete'}
                        </button>
                      </div>
                      {/* Service toggles */}
                      {expandedRef === p.ref && (
                        <div style={styles.servicesPanel}>
                          <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 4 }}>
                            Per-project services
                          </div>
                          <div style={{ fontSize: 11, color: SB2_MUTED, marginBottom: 10 }}>
                            Auth, PostgREST, and pg-meta are always on. Toggle optional services below.
                          </div>
                          {services[p.ref] ? (
                            <>
                              {services[p.ref].map((svc) => (
                                <label key={svc.name} style={styles.serviceRow}>
                                  <input
                                    type="checkbox"
                                    checked={svc.enabled}
                                    onChange={() => handleToggleService(p.ref, svc.name, svc.enabled)}
                                    disabled={togglingService}
                                    style={{ marginRight: 8, accentColor: SB2_ACCENT }}
                                  />
                                  <div style={{ flex: 1, minWidth: 0 }}>
                                    <div style={{ fontSize: 13, fontWeight: 500 }}>
                                      {svc.name.charAt(0).toUpperCase() + svc.name.slice(1)}
                                      {!svc.enabled && <span style={{ color: '#ef4444', fontSize: 11, marginLeft: 6 }}>off</span>}
                                    </div>
                                    <div style={{ fontSize: 11, color: SB2_MUTED, lineHeight: '1.4' }}>{svc.description}</div>
                                  </div>
                                </label>
                              ))}
                              {serviceChanged === p.ref && (
                                <div style={styles.restartNotice}>
                                  Restart to apply: <code style={styles.code}>./superbase2.sh down {p.name} && ./superbase2.sh up {p.name}</code>
                                  <button
                                    onClick={() => {
                                      handleCopy(`./superbase2.sh down ${p.name} && ./superbase2.sh up ${p.name}`, `restart-${p.ref}`)
                                    }}
                                    style={{ ...styles.copyBtn, marginLeft: 8 }}
                                  >
                                    {copied === `restart-${p.ref}` ? 'Copied' : 'Copy'}
                                  </button>
                                </div>
                              )}
                            </>
                          ) : (
                            <span style={{ fontSize: 12, color: SB2_MUTED }}>Loading...</span>
                          )}
                        </div>
                      )}
                    </div>
                  ))}
                </div>

                {/* Pagination */}
                {totalPages > 1 && (
                  <div style={styles.pagination} role="navigation" aria-label="Projects pagination">
                    <button
                      onClick={() => setPage((p) => Math.max(0, p - 1))}
                      disabled={page === 0}
                      style={styles.pageBtn}
                      aria-label="Previous page"
                    >
                      ← Prev
                    </button>
                    <span style={styles.muted}>
                      Page {page + 1} of {totalPages}
                    </span>
                    <button
                      onClick={() => setPage((p) => Math.min(totalPages - 1, p + 1))}
                      disabled={page >= totalPages - 1}
                      style={styles.pageBtn}
                      aria-label="Next page"
                    >
                      Next →
                    </button>
                  </div>
                )}
              </>
            )}
          </section>

          {/* Version info */}
          {upgrade && !upgrade.hasUpdates && (
            <p style={styles.muted}>All services are up to date.</p>
          )}
        </main>

        <footer style={styles.footer}>
          <span style={styles.footerText}>SuperBase² — multi-project layer for self-hosted Supabase</span>
        </footer>
      </div>
    </>
  )
}

// ─── Styles (inline to avoid needing CSS module setup) ──────────────────────

const SB2_ACCENT = '#f59e0b'
const SB2_ACCENT_DARK = '#d97706'
const SB2_BG = '#0c0c0c'
const SB2_SURFACE = '#161616'
const SB2_BORDER = '#262626'
const SB2_TEXT = '#e5e5e5'
const SB2_MUTED = '#737373'

const styles: Record<string, React.CSSProperties> = {
  page: {
    minHeight: '100vh',
    backgroundColor: SB2_BG,
    color: SB2_TEXT,
    fontFamily:
      '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif',
  },
  header: {
    borderBottom: `1px solid ${SB2_BORDER}`,
    backgroundColor: SB2_SURFACE,
  },
  headerInner: {
    maxWidth: 960,
    margin: '0 auto',
    padding: '16px 24px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  logo: {
    display: 'flex',
    alignItems: 'center',
    gap: 10,
  },
  logoIcon: {
    fontSize: 24,
    color: SB2_ACCENT,
  },
  logoText: {
    fontSize: 18,
    fontWeight: 700,
    color: SB2_ACCENT,
    letterSpacing: '-0.02em',
  },
  headerLinks: {
    display: 'flex',
    gap: 16,
  },
  headerLink: {
    color: SB2_MUTED,
    textDecoration: 'none',
    fontSize: 14,
  },
  main: {
    maxWidth: 960,
    margin: '0 auto',
    padding: '32px 24px',
  },
  upgradeBanner: {
    backgroundColor: '#451a03',
    border: `1px solid ${SB2_ACCENT_DARK}`,
    borderRadius: 8,
    padding: 20,
    marginBottom: 32,
  },
  upgradeBannerInner: {
    display: 'flex',
    gap: 12,
    alignItems: 'flex-start',
  },
  upgradeIcon: {
    fontSize: 20,
    color: SB2_ACCENT,
    fontWeight: 700,
  },
  upgradeCount: {
    color: SB2_MUTED,
    fontSize: 14,
  },
  upgradeServices: {
    display: 'flex',
    flexWrap: 'wrap' as const,
    gap: 6,
    marginTop: 8,
  },
  upgradeChip: {
    fontSize: 12,
    backgroundColor: '#292524',
    color: SB2_ACCENT,
    padding: '2px 8px',
    borderRadius: 4,
    fontFamily: 'monospace',
  },
  upgradeCode: {
    marginTop: 12,
    padding: 12,
    backgroundColor: '#0a0a0a',
    borderRadius: 6,
    fontSize: 13,
    fontFamily: 'monospace',
    color: SB2_TEXT,
    overflowX: 'auto' as const,
    border: `1px solid ${SB2_BORDER}`,
  },
  secretsBanner: {
    backgroundColor: '#1a2e05',
    border: '1px solid #4d7c0f',
    borderRadius: 8,
    padding: 20,
    marginBottom: 32,
  },
  secretRow: {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    marginBottom: 8,
    padding: '6px 0',
  },
  secretLabel: {
    fontSize: 12,
    color: SB2_MUTED,
    minWidth: 120,
    flexShrink: 0,
  },
  secretValue: {
    fontSize: 12,
    fontFamily: 'monospace',
    color: SB2_TEXT,
    backgroundColor: '#0a0a0a',
    padding: '4px 8px',
    borderRadius: 4,
    border: `1px solid ${SB2_BORDER}`,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap' as const,
    flex: 1,
    minWidth: 0,
  },
  dismissBtn: {
    padding: '4px 12px',
    fontSize: 12,
    backgroundColor: 'transparent',
    color: SB2_MUTED,
    border: `1px solid ${SB2_BORDER}`,
    borderRadius: 4,
    cursor: 'pointer',
  },
  copyBtn: {
    padding: '4px 10px',
    fontSize: 11,
    backgroundColor: SB2_SURFACE,
    color: SB2_ACCENT,
    border: `1px solid ${SB2_BORDER}`,
    borderRadius: 4,
    cursor: 'pointer',
    flexShrink: 0,
  },
  section: {
    marginBottom: 40,
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: 600,
    marginBottom: 16,
    color: SB2_TEXT,
    display: 'flex',
    alignItems: 'center',
    gap: 8,
  },
  count: {
    fontSize: 12,
    color: SB2_MUTED,
    backgroundColor: SB2_SURFACE,
    padding: '2px 8px',
    borderRadius: 10,
    border: `1px solid ${SB2_BORDER}`,
  },
  createForm: {
    display: 'flex',
    gap: 8,
    position: 'relative' as const,
  },
  input: {
    flex: 1,
    padding: '10px 14px',
    backgroundColor: SB2_SURFACE,
    border: `1px solid ${SB2_BORDER}`,
    borderRadius: 6,
    color: SB2_TEXT,
    fontSize: 14,
    outline: 'none',
  },
  button: {
    padding: '10px 20px',
    backgroundColor: SB2_ACCENT,
    color: '#000',
    border: 'none',
    borderRadius: 6,
    fontSize: 14,
    fontWeight: 600,
    cursor: 'pointer',
  },
  error: {
    color: '#ef4444',
    fontSize: 13,
    marginTop: 8,
  },
  hint: {
    color: SB2_MUTED,
    fontSize: 13,
    marginTop: 8,
  },
  code: {
    backgroundColor: SB2_SURFACE,
    padding: '2px 6px',
    borderRadius: 4,
    fontSize: 12,
    fontFamily: 'monospace',
    color: SB2_ACCENT,
  },
  grid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))',
    gap: 12,
  },
  card: {
    backgroundColor: SB2_SURFACE,
    border: `1px solid ${SB2_BORDER}`,
    borderRadius: 8,
    padding: 16,
    color: SB2_TEXT,
    transition: 'border-color 0.15s',
  },
  cardHeader: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  cardName: {
    fontWeight: 600,
    fontSize: 15,
  },
  statusDot: {
    width: 8,
    height: 8,
    borderRadius: '50%',
    display: 'inline-block',
  },
  cardMeta: {
    marginTop: 8,
    display: 'flex',
    alignItems: 'center',
    gap: 8,
  },
  cardRef: {
    fontSize: 12,
    fontFamily: 'monospace',
    color: SB2_MUTED,
    flex: 1,
    minWidth: 0,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
  },
  cardCopyBtn: {
    padding: '2px 8px',
    fontSize: 11,
    backgroundColor: 'transparent',
    color: SB2_MUTED,
    border: `1px solid ${SB2_BORDER}`,
    borderRadius: 4,
    cursor: 'pointer',
    flexShrink: 0,
  },
  deleteBtn: {
    padding: '2px 8px',
    fontSize: 11,
    backgroundColor: 'transparent',
    color: '#ef4444',
    border: '1px solid #7f1d1d',
    borderRadius: 4,
    cursor: 'pointer',
    flexShrink: 0,
  },
  servicesPanel: {
    marginTop: 12,
    paddingTop: 12,
    borderTop: `1px solid ${SB2_BORDER}`,
  },
  serviceRow: {
    display: 'flex',
    alignItems: 'flex-start',
    padding: '6px 0',
    cursor: 'pointer',
    gap: 0,
  },
  restartNotice: {
    marginTop: 10,
    padding: '8px 12px',
    backgroundColor: '#451a03',
    border: `1px solid ${SB2_ACCENT_DARK}`,
    borderRadius: 6,
    fontSize: 12,
    color: SB2_ACCENT,
    display: 'flex',
    alignItems: 'center',
    flexWrap: 'wrap' as const,
    gap: 4,
  },
  pagination: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 16,
    marginTop: 20,
  },
  pageBtn: {
    padding: '6px 14px',
    fontSize: 13,
    backgroundColor: SB2_SURFACE,
    color: SB2_TEXT,
    border: `1px solid ${SB2_BORDER}`,
    borderRadius: 6,
    cursor: 'pointer',
  },
  muted: {
    color: SB2_MUTED,
    fontSize: 14,
  },
  footer: {
    borderTop: `1px solid ${SB2_BORDER}`,
    padding: 24,
    textAlign: 'center' as const,
  },
  footerText: {
    color: SB2_MUTED,
    fontSize: 12,
  },
}
