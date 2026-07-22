import Head from 'next/head'
import Link from 'next/link'
import { useEffect, useMemo, useState } from 'react'

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
  db_url?: string
  db_password?: string | null
}

type LifecycleAction = 'up' | 'down' | 'restart'

interface ServiceInfo {
  name: string
  enabled: boolean
  description: string
}

interface ProjectKeys {
  ref: string
  name: string
  url: string | null
  anon_key: string
  service_role_key: string
  jwt_secret: string
  db_url: string
  db_password: string | null
  restart_pending?: boolean
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
  upgradeNote: string | null
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

function ClipboardIcon() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  )
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
  const [togglingService, setTogglingService] = useState<string | null>(null)
  const [serviceChanged, setServiceChanged] = useState<string | null>(null)
  const [serviceError, setServiceError] = useState<string | null>(null)
  const [lifecycleBusy, setLifecycleBusy] = useState<string | null>(null)
  const [lifecycleError, setLifecycleError] = useState<string | null>(null)
  const [lifecycleMessage, setLifecycleMessage] = useState<string | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<Project | null>(null)
  const [deleteConfirmInput, setDeleteConfirmInput] = useState('')
  const [expandedKeysRef, setExpandedKeysRef] = useState<string | null>(null)
  const [keys, setKeys] = useState<Record<string, ProjectKeys>>({})
  const [keysError, setKeysError] = useState<string | null>(null)
  const [keysLoadingRef, setKeysLoadingRef] = useState<string | null>(null)
  const [revealedKeys, setRevealedKeys] = useState<Record<string, boolean>>({})
  const [rotateTarget, setRotateTarget] = useState<Project | null>(null)
  const [rotating, setRotating] = useState(false)
  const [lifecycleConfirm, setLifecycleConfirm] = useState<{
    project: Project
    action: LifecycleAction
  } | null>(null)
  const [hoveredCard, setHoveredCard] = useState<string | null>(null)

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
        .catch((err) => {
          if (err.name !== 'AbortError') setError(err.message)
        }),
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
  useEffect(() => {
    setPage(0)
  }, [search])

  /** POST with automatic CSRF retry: if the token hasn't been set yet
   *  (fresh page load), the first POST returns 403. We fetch projects (GET)
   *  to plant the cookie, then retry the POST once. */
  const postWithCsrfRetry = async (url: string, body: unknown): Promise<Response> => {
    const doPost = () =>
      fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-SB2-CSRF': getCsrfToken(),
        },
        body: JSON.stringify(body),
      })

    const res = await doPost()
    if (res.status === 403) {
      // Plant the CSRF cookie via a GET, then retry once
      await fetch('/api/superbase2/projects')
      return doPost()
    }
    return res
  }

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!newName.trim() || creating) return

    setCreating(true)
    setError('')
    setCreatedProject(null)

    try {
      const res = await postWithCsrfRetry('/api/superbase2/projects', { name: newName.trim() })

      if (!res.ok) {
        let message = 'Failed to create project'
        try {
          message = (await res.json()).error?.message || message
        } catch {}
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

  /** DELETE with automatic CSRF retry (same pattern as postWithCsrfRetry). */
  const deleteWithCsrfRetry = async (url: string): Promise<Response> => {
    const doDelete = () =>
      fetch(url, {
        method: 'DELETE',
        headers: { 'X-SB2-CSRF': getCsrfToken() },
      })

    const res = await doDelete()
    if (res.status === 403) {
      await fetch('/api/superbase2/projects')
      return doDelete()
    }
    return res
  }

  const openDeleteModal = (project: Project) => {
    setDeleteTarget(project)
    setDeleteConfirmInput('')
    setError('')
    setLifecycleError(null)
    setLifecycleMessage(null)
  }

  const closeDeleteModal = () => {
    setDeleteTarget(null)
    setDeleteConfirmInput('')
  }

  const confirmDelete = async () => {
    if (!deleteTarget) return
    if (deleteConfirmInput !== deleteTarget.name) return

    const ref = deleteTarget.ref
    setDeleting(ref)
    setError('')

    try {
      const res = await deleteWithCsrfRetry(`/api/superbase2/projects/${ref}`)
      if (!res.ok) {
        let message = 'Failed to delete project'
        try {
          message = (await res.json()).error?.message || message
        } catch {}
        if (res.status === 403) message += ' — refresh the page and try again.'
        setError(message)
        return
      }
      setProjects((prev) => prev.filter((p) => p.ref !== ref))
      closeDeleteModal()
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Unknown error')
    } finally {
      setDeleting(null)
    }
  }

  const handleLifecycle = async (ref: string, name: string, action: LifecycleAction) => {
    setLifecycleBusy(`${action}:${ref}`)
    setLifecycleError(null)
    // Starting a project creates 6 service containers and waits for each
    // to report healthy (depends_on: service_healthy). Realtime + auth in
    // particular run first-time DB setup and can hold the chain for a
    // while. Images are already cached locally — this is health-check
    // settling, not a pull.
    if (action === 'up') {
      setLifecycleMessage(
        `Starting '${name}'… this usually takes 30–90 seconds while each service ` +
          `comes up and passes its health check. The first request after start may ` +
          `still be slow while connections warm up.`
      )
    } else if (action === 'restart') {
      setLifecycleMessage(`Restarting '${name}'… this may take a minute.`)
    } else {
      setLifecycleMessage(null)
    }

    try {
      const res = await postWithCsrfRetry(`/api/superbase2/projects/${ref}/lifecycle`, { action })
      const body = await res.json().catch(() => ({}))

      if (!res.ok) {
        const msg = body?.error?.message || body?.stderr || `Failed to ${action} project`
        setLifecycleError(`${name}: ${msg.trim().slice(0, 400)}`)
        setLifecycleMessage(null)
        return
      }

      const verb = action === 'up' ? 'started' : action === 'down' ? 'stopped' : 'restarted'
      setLifecycleMessage(`Project '${name}' ${verb}.`)
      setTimeout(() => setLifecycleMessage(null), 4000)
    } catch (err: unknown) {
      setLifecycleError(err instanceof Error ? err.message : 'Unknown error')
      setLifecycleMessage(null)
    } finally {
      setLifecycleBusy(null)
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

  const handleToggleService = async (
    ref: string,
    serviceName: string,
    currentlyEnabled: boolean
  ) => {
    setTogglingService(ref)
    setServiceError(null)
    try {
      const current = services[ref] || []
      const newDisabled = current
        .filter((s) => (s.name === serviceName ? currentlyEnabled : !s.enabled))
        .map((s) => s.name)

      const doPatch = () =>
        fetch(`/api/superbase2/projects/${ref}/services`, {
          method: 'PATCH',
          headers: {
            'Content-Type': 'application/json',
            'X-SB2-CSRF': getCsrfToken(),
          },
          body: JSON.stringify({ disabled_services: newDisabled }),
        })

      let res = await doPatch()
      if (res.status === 403) {
        await fetch('/api/superbase2/projects')
        res = await doPatch()
      }

      if (res.ok) {
        setServices((prev) => ({
          ...prev,
          [ref]: current.map((s) =>
            s.name === serviceName ? { ...s, enabled: !currentlyEnabled } : s
          ),
        }))
        setServiceChanged(ref)
      } else {
        let message = 'Failed to toggle service'
        try {
          message = (await res.json()).error?.message || message
        } catch {}
        setServiceError(message)
      }
    } catch (err: unknown) {
      setServiceError(err instanceof Error ? err.message : 'Failed to toggle service')
    } finally {
      setTogglingService(null)
    }
  }

  const handleExpandKeys = async (ref: string) => {
    if (expandedKeysRef === ref) {
      setExpandedKeysRef(null)
      return
    }
    setExpandedKeysRef(ref)
    setKeysError(null)
    // Always refetch — values can change out-of-band (CLI rotation, another
    // operator using the dashboard) and a stale cache would silently lie.
    setKeysLoadingRef(ref)
    try {
      const res = await fetch(`/api/superbase2/projects/${ref}/keys`)
      if (res.ok) {
        const data: ProjectKeys = await res.json()
        setKeys((prev) => ({ ...prev, [ref]: data }))
      } else {
        let message = 'Failed to load keys'
        try {
          message = (await res.json()).error?.message || message
        } catch {}
        setKeysError(message)
      }
    } catch (err: unknown) {
      setKeysError(err instanceof Error ? err.message : 'Failed to load keys')
    } finally {
      setKeysLoadingRef(null)
    }
  }

  const toggleReveal = (ref: string) => {
    setRevealedKeys((prev) => ({ ...prev, [ref]: !prev[ref] }))
  }

  const openRotateModal = (project: Project) => {
    setRotateTarget(project)
    setKeysError(null)
  }

  const closeRotateModal = () => {
    setRotateTarget(null)
  }

  const confirmRotate = async () => {
    if (!rotateTarget) return
    const ref = rotateTarget.ref
    setRotating(true)
    setKeysError(null)
    try {
      const res = await postWithCsrfRetry(`/api/superbase2/projects/${ref}/keys`, {})
      const body = await res.json().catch(() => ({}))
      if (!res.ok) {
        const msg = body?.error?.message || body?.stderr || 'Failed to rotate keys'
        setKeysError(msg.toString().trim().slice(0, 400))
        return
      }
      setKeys((prev) => ({ ...prev, [ref]: body as ProjectKeys }))
      setRevealedKeys((prev) => ({ ...prev, [ref]: true }))
      setExpandedKeysRef(ref)
      const restarting = Boolean((body as ProjectKeys)?.restart_pending)
      setLifecycleMessage(
        `Keys rotated for '${rotateTarget.name}'. Update any client SDKs and server processes with the new values.` +
          (restarting
            ? ' Project containers are restarting in the background — give them ~60s before reconnecting clients.'
            : '')
      )
      closeRotateModal()
    } catch (err: unknown) {
      setKeysError(err instanceof Error ? err.message : 'Failed to rotate keys')
    } finally {
      setRotating(false)
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
              <span style={styles.logoIcon} aria-hidden="true">
                &#x26A1;&#xB2;
              </span>
              <span style={styles.logoText}>SuperBase²</span>
            </div>
            <nav aria-label="SuperBase² navigation" style={styles.headerLinks}>
              {projects.length > 0 ? (
                <Link href={`/project/${projects[0].ref}`} style={styles.headerLink}>
                  Studio →
                </Link>
              ) : (
                <span
                  style={{ ...styles.headerLink, opacity: 0.4, cursor: 'default' }}
                  title="Create a project first"
                >
                  Studio →
                </span>
              )}
            </nav>
          </div>
        </header>

        <main style={styles.main} role="main">
          {/* Upgrade banner */}
          {upgrade?.hasUpdates && (
            <div style={styles.upgradeBanner} role="alert">
              <div style={styles.upgradeBannerInner}>
                <span style={styles.upgradeIcon} aria-hidden="true">
                  ↑
                </span>
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
                      <pre style={styles.upgradeCode}>{upgrade.upgradeInstructions.join('\n')}</pre>
                      <button
                        onClick={() =>
                          handleCopy(upgrade.upgradeInstructions!.join('\n'), 'upgrade')
                        }
                        style={styles.copyBtn}
                        aria-label="Copy upgrade commands"
                        title="Copy commands"
                      >
                        {copied === 'upgrade' ? 'Copied' : 'Copy'}
                      </button>
                    </div>
                  )}
                  {upgrade.upgradeNote && (
                    <p style={{ fontSize: 12, color: SB2_MUTED, margin: '8px 0 0' }}>
                      {upgrade.upgradeNote}
                    </p>
                  )}
                </div>
              </div>
            </div>
          )}

          {/* Created project secrets (one-time display) */}
          {createdProject && (
            <div style={styles.secretsBanner} role="alert">
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  marginBottom: 12,
                }}
              >
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
                These secrets are only shown once. Copy them now. When you're done, click{' '}
                <strong style={{ color: SB2_ACCENT }}>Start</strong> on the project card below to
                boot the container stack.
              </p>
              {(() => {
                const fields: { label: string; envKey: string; value?: string }[] = [
                  { label: 'Project Ref', envKey: 'PROJECT_REF', value: createdProject.ref },
                  {
                    label: 'JWT Secret',
                    envKey: 'SUPABASE_JWT_SECRET',
                    value: createdProject.jwt_secret,
                  },
                  {
                    label: 'Anon Key',
                    envKey: 'SUPABASE_ANON_KEY',
                    value: createdProject.anon_key,
                  },
                  {
                    label: 'Service Role Key',
                    envKey: 'SUPABASE_SERVICE_ROLE_KEY',
                    value: createdProject.service_role_key,
                  },
                  {
                    label: 'Database Password',
                    envKey: 'POSTGRES_PASSWORD',
                    value: createdProject.db_password ?? undefined,
                  },
                  {
                    label: 'Database URL (in-network)',
                    envKey: 'DATABASE_URL',
                    value: createdProject.db_url,
                  },
                ]
                const envBlock = fields
                  .filter((f) => f.value)
                  .map((f) => `${f.envKey}=${f.value}`)
                  .join('\n')
                return (
                  <>
                    {fields.map(({ label, value }) =>
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
                    <div style={{ marginTop: 12, display: 'flex', justifyContent: 'flex-end' }}>
                      <button
                        onClick={() => handleCopy(envBlock, 'all-env')}
                        style={styles.copyBtn}
                        aria-label="Copy all secrets as .env"
                        title="Copy all as .env-style key=value block"
                      >
                        {copied === 'all-env' ? 'Copied' : 'Copy all as .env'}
                      </button>
                    </div>
                  </>
                )
              })()}
            </div>
          )}

          {/* Projects list */}
          <section style={styles.section}>
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                marginBottom: 16,
              }}
            >
              <h2 style={{ ...styles.sectionTitle, marginBottom: 0 }}>
                Projects {!loading && <span style={styles.count}>{filteredProjects.length}</span>}
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
              <p style={styles.muted} role="status" aria-live="polite">
                Loading...
              </p>
            ) : filteredProjects.length === 0 ? (
              <p style={styles.muted}>
                {search ? 'No projects match your search.' : 'No projects yet. Create one above.'}
              </p>
            ) : (
              <>
                <div style={styles.grid} role="list" aria-label="Projects">
                  {pagedProjects.map((p) => {
                    const isActive = p.status === 'ACTIVE_HEALTHY'
                    const isHovered = hoveredCard === p.ref
                    return (
                      <div key={p.ref} style={styles.card} role="listitem">
                        <Link
                          href={`/project/${p.ref}`}
                          onMouseEnter={() => setHoveredCard(p.ref)}
                          onMouseLeave={() =>
                            setHoveredCard((prev) => (prev === p.ref ? null : prev))
                          }
                          style={{
                            ...styles.cardOpenLink,
                            borderColor: isHovered ? SB2_ACCENT_DARK : SB2_BORDER,
                            backgroundColor: isHovered ? '#1f1a10' : SB2_BG,
                          }}
                          aria-label={`Open project ${p.name}`}
                        >
                          <div style={styles.cardHeader}>
                            <span style={styles.cardName}>{p.name}</span>
                            <span
                              style={{
                                ...styles.statusBadge,
                                ...(isActive ? styles.statusBadgeActive : null),
                              }}
                            >
                              {isActive ? 'active' : p.status.toLowerCase().replace(/_/g, ' ')}
                            </span>
                          </div>
                          <div style={styles.cardOpenHint}>
                            <span>Open dashboard</span>
                            <span aria-hidden style={{ marginLeft: 6 }}>
                              →
                            </span>
                          </div>
                        </Link>
                        <div style={styles.cardMeta}>
                          <button
                            onClick={() => handleExpandServices(p.ref)}
                            style={{
                              ...styles.cardCopyBtn,
                              ...(expandedRef === p.ref ? styles.cardCopyBtnActive : null),
                            }}
                            aria-label={`Toggle services for ${p.name}`}
                            aria-expanded={expandedRef === p.ref}
                            title="Configure services"
                          >
                            Services
                          </button>
                          <button
                            onClick={() => handleExpandKeys(p.ref)}
                            style={{
                              ...styles.cardCopyBtn,
                              ...(expandedKeysRef === p.ref ? styles.cardCopyBtnActive : null),
                            }}
                            aria-label={`Show API keys for ${p.name}`}
                            aria-expanded={expandedKeysRef === p.ref}
                            title="View ref + API keys + JWT secret"
                          >
                            Keys
                          </button>
                        </div>
                        <div style={styles.cardDivider} aria-hidden />
                        <div style={styles.cardActions}>
                          <button
                            onClick={() => setLifecycleConfirm({ project: p, action: 'up' })}
                            style={styles.startBtn}
                            disabled={!!lifecycleBusy}
                            title="Start container stack"
                          >
                            {lifecycleBusy === `up:${p.ref}` ? 'Starting…' : 'Start'}
                          </button>
                          <button
                            onClick={() => setLifecycleConfirm({ project: p, action: 'down' })}
                            style={styles.stopBtn}
                            disabled={!!lifecycleBusy}
                            title="Stop container stack"
                          >
                            {lifecycleBusy === `down:${p.ref}` ? 'Stopping…' : 'Stop'}
                          </button>
                          <button
                            onClick={() => setLifecycleConfirm({ project: p, action: 'restart' })}
                            style={styles.restartBtn}
                            disabled={!!lifecycleBusy}
                            title="Restart container stack"
                          >
                            {lifecycleBusy === `restart:${p.ref}` ? 'Restarting…' : 'Restart'}
                          </button>
                          <div style={{ flex: 1 }} />
                          <button
                            onClick={() => openDeleteModal(p)}
                            style={styles.deleteBtn}
                            disabled={deleting === p.ref}
                            aria-label={`Delete project ${p.name}`}
                          >
                            {deleting === p.ref ? 'Deleting...' : 'Delete'}
                          </button>
                        </div>
                        {/* Keys panel */}
                        {expandedKeysRef === p.ref && (
                          <div style={styles.servicesPanel}>
                            <div
                              style={{
                                display: 'flex',
                                alignItems: 'center',
                                justifyContent: 'space-between',
                                marginBottom: 6,
                              }}
                            >
                              <div style={{ fontSize: 12, fontWeight: 600 }}>
                                API keys & JWT secret
                              </div>
                              <div style={{ display: 'flex', gap: 6 }}>
                                <button
                                  onClick={() => toggleReveal(p.ref)}
                                  style={styles.cardCopyBtn}
                                  aria-label={revealedKeys[p.ref] ? 'Hide keys' : 'Reveal keys'}
                                >
                                  {revealedKeys[p.ref] ? 'Hide' : 'Reveal'}
                                </button>
                                <button
                                  onClick={() => openRotateModal(p)}
                                  style={{
                                    ...styles.cardCopyBtn,
                                    color: SB2_ACCENT,
                                    borderColor: SB2_ACCENT_DARK,
                                  }}
                                  aria-label={`Rotate keys for ${p.name}`}
                                  title="Generate new JWT secret + API keys (containers will restart)"
                                >
                                  Rotate
                                </button>
                              </div>
                            </div>
                            <div style={{ fontSize: 11, color: SB2_MUTED, marginBottom: 10 }}>
                              These are the live keys from the project manifest. Treat the
                              service_role key like a database password — never ship it to a
                              browser.
                            </div>
                            <div style={{ fontSize: 11, color: SB2_MUTED, marginBottom: 10 }}>
                              <strong>Database password:</strong> the Database URL below
                              authenticates as this project&apos;s own Postgres role, which owns
                              this database and cannot open any other project&apos;s. Rotate
                              regenerates it along with the keys.
                            </div>
                            <div style={{ fontSize: 11, color: SB2_MUTED, marginBottom: 10 }}>
                              <strong>Database URL</strong> uses the <code>db</code> Docker
                              hostname, so it works from edge functions and other containers on the
                              Supabase network. Postgres is not published to the host by default —
                              reaching it from outside Docker needs a published port or a pooler,
                              and the hostname swapped for your server&apos;s address.
                            </div>
                            <div style={styles.secretRow}>
                              <span style={styles.secretLabel}>Project ref</span>
                              <code style={styles.secretValue}>{p.ref}</code>
                              <button
                                onClick={() => handleCopy(p.ref, `ref-${p.ref}`)}
                                style={styles.copyBtn}
                                aria-label={`Copy project ref ${p.ref}`}
                                title="Copy ref"
                              >
                                {copied === `ref-${p.ref}` ? 'Copied' : <ClipboardIcon />}
                              </button>
                            </div>
                            {keysLoadingRef === p.ref && !keys[p.ref] ? (
                              <span style={{ fontSize: 12, color: SB2_MUTED }}>Loading...</span>
                            ) : keys[p.ref] ? (
                              (() => {
                                const k = keys[p.ref]
                                const revealed = !!revealedKeys[p.ref]
                                const mask = (s: string) =>
                                  revealed ? s : s ? '•'.repeat(Math.min(s.length, 32)) : ''
                                const fields: {
                                  label: string
                                  envKey: string
                                  value: string | null
                                }[] = [
                                  { label: 'URL', envKey: 'SUPABASE_URL', value: k.url },
                                  {
                                    label: 'Anon Key',
                                    envKey: 'SUPABASE_ANON_KEY',
                                    value: k.anon_key,
                                  },
                                  {
                                    label: 'Service Role Key',
                                    envKey: 'SUPABASE_SERVICE_ROLE_KEY',
                                    value: k.service_role_key,
                                  },
                                  {
                                    label: 'JWT Secret',
                                    envKey: 'SUPABASE_JWT_SECRET',
                                    value: k.jwt_secret,
                                  },
                                  {
                                    label: 'Database Password',
                                    envKey: 'POSTGRES_PASSWORD',
                                    value: k.db_password,
                                  },
                                  {
                                    label: 'Database URL (in-network)',
                                    envKey: 'DATABASE_URL',
                                    value: k.db_url,
                                  },
                                ]
                                // Only the project URL is safe to show unmasked — the
                                // database URL now embeds the project's real password.
                                const plain = new Set(['URL'])
                                const envBlock = fields
                                  .filter((f) => f.value)
                                  .map((f) => `${f.envKey}=${f.value}`)
                                  .join('\n')
                                return (
                                  <>
                                    {fields.map(({ label, value }) =>
                                      value ? (
                                        <div key={label} style={styles.secretRow}>
                                          <span style={styles.secretLabel}>{label}</span>
                                          <code style={styles.secretValue}>
                                            {plain.has(label) ? value : mask(value)}
                                          </code>
                                          <button
                                            onClick={() => handleCopy(value, `${p.ref}-${label}`)}
                                            style={styles.copyBtn}
                                            aria-label={`Copy ${label}`}
                                            title={`Copy ${label}`}
                                          >
                                            {copied === `${p.ref}-${label}` ? (
                                              'Copied'
                                            ) : (
                                              <ClipboardIcon />
                                            )}
                                          </button>
                                        </div>
                                      ) : null
                                    )}
                                    <div
                                      style={{
                                        marginTop: 8,
                                        display: 'flex',
                                        justifyContent: 'flex-end',
                                      }}
                                    >
                                      <button
                                        onClick={() => handleCopy(envBlock, `${p.ref}-all-env`)}
                                        style={styles.copyBtn}
                                        title="Copy as .env-style key=value block"
                                      >
                                        {copied === `${p.ref}-all-env` ? 'Copied' : 'Copy as .env'}
                                      </button>
                                    </div>
                                  </>
                                )
                              })()
                            ) : keysError && expandedKeysRef === p.ref ? (
                              <p style={{ ...styles.error, marginTop: 0 }}>{keysError}</p>
                            ) : null}
                          </div>
                        )}
                        {/* Service toggles */}
                        {expandedRef === p.ref && (
                          <div style={styles.servicesPanel}>
                            <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 4 }}>
                              Per-project services
                            </div>
                            <div style={{ fontSize: 11, color: SB2_MUTED, marginBottom: 10 }}>
                              Auth, PostgREST, and pg-meta are always on. Toggle optional services
                              below.
                            </div>
                            {services[p.ref] ? (
                              <>
                                {services[p.ref].map((svc) => (
                                  <label key={svc.name} style={styles.serviceRow}>
                                    <input
                                      type="checkbox"
                                      checked={svc.enabled}
                                      onChange={() =>
                                        handleToggleService(p.ref, svc.name, svc.enabled)
                                      }
                                      disabled={togglingService === p.ref}
                                      style={{ marginRight: 8, accentColor: SB2_ACCENT }}
                                    />
                                    <div style={{ flex: 1, minWidth: 0 }}>
                                      <div style={{ fontSize: 13, fontWeight: 500 }}>
                                        {svc.name.charAt(0).toUpperCase() + svc.name.slice(1)}
                                        {!svc.enabled && (
                                          <span
                                            style={{
                                              color: '#ef4444',
                                              fontSize: 11,
                                              marginLeft: 6,
                                            }}
                                          >
                                            off
                                          </span>
                                        )}
                                      </div>
                                      <div
                                        style={{
                                          fontSize: 11,
                                          color: SB2_MUTED,
                                          lineHeight: '1.4',
                                        }}
                                      >
                                        {svc.description}
                                      </div>
                                    </div>
                                  </label>
                                ))}
                                {serviceError && expandedRef === p.ref && (
                                  <p
                                    style={{ ...styles.error, marginTop: 8, marginBottom: 0 }}
                                    role="alert"
                                  >
                                    {serviceError}
                                  </p>
                                )}
                                {serviceChanged === p.ref && (
                                  <div style={styles.restartNotice}>
                                    Click <strong>Restart</strong> above to apply the service
                                    changes.
                                  </div>
                                )}
                              </>
                            ) : (
                              <span style={{ fontSize: 12, color: SB2_MUTED }}>Loading...</span>
                            )}
                          </div>
                        )}
                      </div>
                    )
                  })}
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

          {/* Create project */}
          <section style={styles.section}>
            <h2 style={styles.sectionTitle}>Create Project</h2>
            <form onSubmit={handleCreate} style={styles.createForm} aria-label="Create new project">
              <label
                htmlFor="sb2-project-name"
                style={{
                  position: 'absolute' as const,
                  width: 1,
                  height: 1,
                  overflow: 'hidden',
                  clip: 'rect(0,0,0,0)',
                }}
              >
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
              <button
                type="submit"
                style={styles.button}
                disabled={creating || !newName.trim() || newName.length < 2}
              >
                {creating ? 'Creating...' : 'Create'}
              </button>
            </form>
            {error && (
              <p style={styles.error} role="alert" aria-live="polite">
                {error}
              </p>
            )}
            <p id="sb2-project-hint" style={styles.hint}>
              Creates the database and secrets. Only letters and numbers allowed (no underscores or
              hyphens — required for Docker DNS). After creation, click{' '}
              <strong style={{ color: SB2_ACCENT }}>Start</strong> on the project card to boot the
              per-project containers.
            </p>
          </section>

          {/* Lifecycle toast / error */}
          {lifecycleMessage && (
            <div style={styles.toastSuccess} role="status" aria-live="polite">
              {lifecycleMessage}
            </div>
          )}
          {lifecycleError && (
            <div style={styles.toastError} role="alert">
              <div style={{ flex: 1 }}>{lifecycleError}</div>
              <button
                onClick={() => setLifecycleError(null)}
                style={styles.dismissBtn}
                aria-label="Dismiss error"
              >
                Dismiss
              </button>
            </div>
          )}

          {/* Version info */}
          {upgrade && !upgrade.hasUpdates && (
            <p style={styles.muted}>All services are up to date.</p>
          )}
        </main>

        {/* Delete confirmation modal */}
        {deleteTarget && (
          <div
            style={styles.modalBackdrop}
            role="dialog"
            aria-modal="true"
            aria-labelledby="sb2-delete-title"
            onClick={(e) => {
              if (e.target === e.currentTarget && deleting !== deleteTarget.ref) closeDeleteModal()
            }}
          >
            <div style={styles.modal}>
              <div style={styles.modalHeader}>
                <span style={styles.modalIcon} aria-hidden>
                  ⚠
                </span>
                <h3 id="sb2-delete-title" style={styles.modalTitle}>
                  Permanently delete this project?
                </h3>
              </div>

              <div style={styles.modalBody}>
                <p style={{ margin: '0 0 12px 0', color: '#fecaca' }}>
                  This will <strong>drop the Postgres database</strong> for{' '}
                  <code style={styles.code}>{deleteTarget.name}</code> and remove it from the
                  manifest.{' '}
                  <strong>
                    All tables, rows, storage objects, and auth users in this project will be
                    destroyed.
                  </strong>
                </p>
                <ul style={styles.modalList}>
                  <li>
                    This action is <strong>irreversible</strong> — there is no soft delete.
                  </li>
                  <li>Per-project containers will be stopped automatically before the drop.</li>
                  <li>Other projects on this server are unaffected.</li>
                </ul>

                <label htmlFor="sb2-delete-confirm" style={styles.modalLabel}>
                  To confirm, type the project name{' '}
                  <code style={styles.code}>{deleteTarget.name}</code> below:
                </label>
                <input
                  id="sb2-delete-confirm"
                  type="text"
                  value={deleteConfirmInput}
                  onChange={(e) => setDeleteConfirmInput(e.target.value)}
                  style={styles.modalInput}
                  autoFocus
                  disabled={deleting === deleteTarget.ref}
                  placeholder={deleteTarget.name}
                  autoComplete="off"
                />
              </div>

              <div style={styles.modalFooter}>
                <button
                  onClick={closeDeleteModal}
                  style={styles.modalCancelBtn}
                  disabled={deleting === deleteTarget.ref}
                >
                  Cancel
                </button>
                <button
                  onClick={confirmDelete}
                  style={{
                    ...styles.modalDeleteBtn,
                    opacity:
                      deleteConfirmInput === deleteTarget.name && deleting !== deleteTarget.ref
                        ? 1
                        : 0.45,
                    cursor:
                      deleteConfirmInput === deleteTarget.name && deleting !== deleteTarget.ref
                        ? 'pointer'
                        : 'not-allowed',
                  }}
                  disabled={
                    deleteConfirmInput !== deleteTarget.name || deleting === deleteTarget.ref
                  }
                >
                  {deleting === deleteTarget.ref
                    ? 'Deleting…'
                    : `Permanently delete ${deleteTarget.name}`}
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Lifecycle confirmation modal (start/stop/restart) */}
        {lifecycleConfirm &&
          (() => {
            const { project: lp, action: la } = lifecycleConfirm
            const verbTitle = la === 'up' ? 'Start' : la === 'down' ? 'Stop' : 'Restart'
            const accent = la === 'down' ? '#ef4444' : SB2_ACCENT
            const accentDark = la === 'down' ? '#7f1d1d' : SB2_ACCENT_DARK
            const description =
              la === 'up'
                ? 'Boots the per-project containers (auth, rest, realtime, storage, functions, meta). Takes 30–90 seconds while each service passes its health check.'
                : la === 'down'
                  ? 'Stops the per-project containers. The dashboard, database, and other projects keep running, but this project will stop responding to API requests until restarted.'
                  : "Restarts the per-project containers. About 30–90 seconds of downtime for this project. Open Studio tabs may show errors during the restart — reload if they don't recover on their own."
            return (
              <div
                style={styles.modalBackdrop}
                role="dialog"
                aria-modal="true"
                aria-labelledby="sb2-lifecycle-title"
                onClick={(e) => {
                  if (e.target === e.currentTarget) setLifecycleConfirm(null)
                }}
              >
                <div style={{ ...styles.modal, border: `2px solid ${accentDark}` }}>
                  <div style={styles.modalHeader}>
                    <span style={{ ...styles.modalIcon, color: accent }} aria-hidden>
                      {la === 'up' ? '▶' : la === 'down' ? '■' : '↻'}
                    </span>
                    <h3 id="sb2-lifecycle-title" style={{ ...styles.modalTitle, color: accent }}>
                      {verbTitle} {lp.name}?
                    </h3>
                  </div>
                  <div style={styles.modalBody}>
                    <p style={{ margin: 0 }}>{description}</p>
                  </div>
                  <div style={styles.modalFooter}>
                    <button onClick={() => setLifecycleConfirm(null)} style={styles.modalCancelBtn}>
                      Cancel
                    </button>
                    <button
                      onClick={() => {
                        handleLifecycle(lp.ref, lp.name, la)
                        setLifecycleConfirm(null)
                      }}
                      style={{
                        ...styles.modalDeleteBtn,
                        backgroundColor: accent,
                        color: '#000',
                        border: `1px solid ${accentDark}`,
                      }}
                    >
                      {verbTitle} project
                    </button>
                  </div>
                </div>
              </div>
            )
          })()}

        {/* Rotate keys confirmation modal */}
        {rotateTarget && (
          <div
            style={styles.modalBackdrop}
            role="dialog"
            aria-modal="true"
            aria-labelledby="sb2-rotate-title"
            onClick={(e) => {
              if (e.target === e.currentTarget && !rotating) closeRotateModal()
            }}
          >
            <div style={{ ...styles.modal, border: `2px solid ${SB2_ACCENT_DARK}` }}>
              <div style={styles.modalHeader}>
                <span style={{ ...styles.modalIcon, color: SB2_ACCENT }} aria-hidden>
                  ↻
                </span>
                <h3 id="sb2-rotate-title" style={{ ...styles.modalTitle, color: SB2_ACCENT }}>
                  Rotate keys for {rotateTarget.name}?
                </h3>
              </div>
              <div style={styles.modalBody}>
                <p style={{ margin: '0 0 12px 0' }}>
                  This will generate a new <strong>JWT secret</strong>, <strong>anon key</strong>,{' '}
                  <strong>service_role key</strong> and <strong>database password</strong> for this
                  project, then restart its containers.
                </p>
                <ul style={{ ...styles.modalList, color: SB2_TEXT }}>
                  <li>
                    All existing JWTs minted by this project become invalid immediately — users will
                    be signed out.
                  </li>
                  <li>
                    The database password is regenerated, so anything connecting over this
                    project&apos;s <code>DATABASE_URL</code> must be updated too. The database
                    itself is untouched — no data moves.
                  </li>
                  <li>
                    Projects created before per-project database roles existed keep the shared
                    server password; only their keys rotate. Run{' '}
                    <code>superbase2.sh migrate-db-owner &lt;name&gt;</code> to give one its own.
                  </li>
                  <li>Every client SDK and server process using the old keys must be updated.</li>
                  <li>
                    <strong>This project</strong> will experience 30–90s of downtime while its
                    containers (auth, rest, realtime, storage, functions, meta) restart with the new
                    keys.
                  </li>
                  <li>
                    <strong>This dashboard</strong> may show errors or appear frozen during the
                    restart — open Studio tabs hold connections to the project's pg-meta and will
                    reconnect once the containers are back. Reload the page if it doesn't recover.
                  </li>
                  <li>
                    Other projects on this server are unaffected — Kong reloads its config without
                    dropping connections.
                  </li>
                </ul>
                {keysError && <p style={{ ...styles.error, marginTop: 0 }}>{keysError}</p>}
              </div>
              <div style={styles.modalFooter}>
                <button
                  onClick={closeRotateModal}
                  style={styles.modalCancelBtn}
                  disabled={rotating}
                >
                  Cancel
                </button>
                <button
                  onClick={confirmRotate}
                  style={{
                    ...styles.modalDeleteBtn,
                    backgroundColor: SB2_ACCENT,
                    color: '#000',
                    border: `1px solid ${SB2_ACCENT_DARK}`,
                    opacity: rotating ? 0.6 : 1,
                    cursor: rotating ? 'not-allowed' : 'pointer',
                  }}
                  disabled={rotating}
                >
                  {rotating ? 'Rotating…' : 'Rotate keys'}
                </button>
              </div>
            </div>
          </div>
        )}

        <footer style={styles.footer}>
          <span style={styles.footerText}>
            SuperBase² — multi-project layer for self-hosted Supabase
          </span>
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
  cardOpenLink: {
    display: 'block',
    textDecoration: 'none',
    color: 'inherit',
    padding: '10px 12px',
    borderRadius: 6,
    border: `1px solid ${SB2_BORDER}`,
    backgroundColor: SB2_BG,
    transition: 'border-color 0.15s, background-color 0.15s',
    cursor: 'pointer',
  },
  cardOpenHint: {
    marginTop: 6,
    fontSize: 11,
    color: SB2_ACCENT,
    fontWeight: 500,
    display: 'flex',
    alignItems: 'center',
  },
  cardDivider: {
    margin: '12px 0 10px',
    borderTop: `1px dashed ${SB2_BORDER}`,
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
  statusBadge: {
    fontSize: 10,
    color: SB2_MUTED,
    backgroundColor: SB2_BG,
    padding: '2px 8px',
    borderRadius: 4,
    border: `1px solid ${SB2_BORDER}`,
    textTransform: 'uppercase' as const,
    letterSpacing: '0.04em',
  },
  statusBadgeActive: {
    color: '#bef264',
    backgroundColor: '#1a2e05',
    border: '1px solid #4d7c0f',
  },
  cardCopyBtnActive: {
    color: SB2_ACCENT,
    borderColor: SB2_ACCENT_DARK,
    backgroundColor: '#1f1a10',
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
  cardActions: {
    marginTop: 10,
    display: 'flex',
    alignItems: 'center',
    gap: 6,
    flexWrap: 'wrap' as const,
  },
  startBtn: {
    padding: '4px 10px',
    fontSize: 11,
    fontWeight: 600,
    backgroundColor: SB2_ACCENT,
    color: '#000',
    border: `1px solid ${SB2_ACCENT_DARK}`,
    borderRadius: 4,
    cursor: 'pointer',
    flexShrink: 0,
  },
  stopBtn: {
    padding: '4px 10px',
    fontSize: 11,
    backgroundColor: 'transparent',
    color: SB2_TEXT,
    border: `1px solid ${SB2_BORDER}`,
    borderRadius: 4,
    cursor: 'pointer',
    flexShrink: 0,
  },
  restartBtn: {
    padding: '4px 10px',
    fontSize: 11,
    backgroundColor: 'transparent',
    color: SB2_ACCENT,
    border: `1px solid ${SB2_ACCENT_DARK}`,
    borderRadius: 4,
    cursor: 'pointer',
    flexShrink: 0,
  },
  toastSuccess: {
    position: 'fixed' as const,
    right: 24,
    bottom: 24,
    maxWidth: 420,
    padding: '10px 14px',
    backgroundColor: '#1a2e05',
    border: '1px solid #4d7c0f',
    borderRadius: 6,
    color: '#bef264',
    fontSize: 13,
    boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
    zIndex: 900,
  },
  toastError: {
    position: 'fixed' as const,
    right: 24,
    bottom: 24,
    maxWidth: 480,
    padding: '10px 14px',
    backgroundColor: '#3f0a0a',
    border: '1px solid #7f1d1d',
    borderRadius: 6,
    color: '#fecaca',
    fontSize: 13,
    display: 'flex',
    alignItems: 'flex-start',
    gap: 12,
    boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
    zIndex: 900,
  },
  modalBackdrop: {
    position: 'fixed' as const,
    inset: 0,
    backgroundColor: 'rgba(0, 0, 0, 0.75)',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
    zIndex: 1000,
  },
  modal: {
    backgroundColor: SB2_SURFACE,
    border: '2px solid #7f1d1d',
    borderRadius: 10,
    maxWidth: 560,
    width: '100%',
    boxShadow: '0 20px 60px rgba(0,0,0,0.6)',
  },
  modalHeader: {
    display: 'flex',
    alignItems: 'center',
    gap: 12,
    padding: '20px 24px 12px',
    borderBottom: `1px solid ${SB2_BORDER}`,
  },
  modalIcon: {
    fontSize: 28,
    color: '#ef4444',
  },
  modalTitle: {
    margin: 0,
    fontSize: 18,
    fontWeight: 700,
    color: '#fecaca',
  },
  modalBody: {
    padding: '16px 24px',
    fontSize: 13,
    color: SB2_TEXT,
    lineHeight: 1.5,
  },
  modalList: {
    margin: '0 0 16px 0',
    paddingLeft: 20,
    color: '#fecaca',
    fontSize: 13,
  },
  modalLabel: {
    display: 'block',
    fontSize: 12,
    color: SB2_MUTED,
    marginBottom: 6,
  },
  modalInput: {
    width: '100%',
    padding: '10px 14px',
    backgroundColor: SB2_BG,
    border: `1px solid ${SB2_BORDER}`,
    borderRadius: 6,
    color: SB2_TEXT,
    fontSize: 14,
    fontFamily: 'monospace',
    outline: 'none',
    boxSizing: 'border-box' as const,
  },
  modalFooter: {
    display: 'flex',
    justifyContent: 'flex-end',
    gap: 8,
    padding: '12px 24px 20px',
    borderTop: `1px solid ${SB2_BORDER}`,
  },
  modalCancelBtn: {
    padding: '8px 16px',
    fontSize: 13,
    backgroundColor: 'transparent',
    color: SB2_MUTED,
    border: `1px solid ${SB2_BORDER}`,
    borderRadius: 6,
    cursor: 'pointer',
  },
  modalDeleteBtn: {
    padding: '8px 16px',
    fontSize: 13,
    fontWeight: 600,
    backgroundColor: '#7f1d1d',
    color: '#fee2e2',
    border: '1px solid #991b1b',
    borderRadius: 6,
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
