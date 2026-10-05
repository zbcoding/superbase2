#!/usr/bin/env node
/*
 * SuperBase² Agent
 *
 * Tiny HTTP server that sits alongside Studio and executes `superbase2.sh`
 * against the host Docker socket. Studio (which has no socket access) calls
 * this agent to start/stop/restart per-project container stacks — replacing
 * the old "SSH in and run the script" step.
 *
 * Exposes, on an internal-only port, bearer-auth'd:
 *   GET  /health
 *   GET  /verify                    Check all projects' JWT secrets match manifest
 *   GET  /images                    Images the main stack's services are running
 *   POST /rebuild-kong              Regenerate Kong config with per-project routes
 *   POST /projects/:name/up
 *   POST /projects/:name/down
 *   POST /projects/:name/restart
 *   POST /projects/:name/rotate-keys
 *   POST /projects/:name/destroy    Remove containers, volumes, disk state and Kong routes
 *   GET  /projects/:name/status
 *   GET  /projects/:name/verify     Check single project's JWT secrets match manifest
 *
 * On startup it runs `superbase2.sh reconcile`, which recreates started
 * projects' containers against the freshly deployed main stack.
 *
 * The script + docker directory are bind-mounted at SB2_DOCKER_DIR.
 */

const http = require('node:http')
const crypto = require('node:crypto')
const fs = require('node:fs')
const { spawn, execFileSync } = require('node:child_process')
const { URL } = require('node:url')

const PORT = Number(process.env.SB2_AGENT_PORT || 8088)
const TOKEN = process.env.SB2_AGENT_TOKEN || ''
const DOCKER_DIR = process.env.SB2_DOCKER_DIR || '/workspace'
const SCRIPT = `${DOCKER_DIR}/superbase2/superbase2.sh`
const MAX_OUTPUT_BYTES = 512 * 1024

if (!TOKEN) {
  console.error('[sb2-agent] FATAL: SB2_AGENT_TOKEN is required')
  process.exit(1)
}

// Resolve the compose network the agent itself is on and export it so
// per-project docker-compose files can attach to the right network. On
// Coolify the stack network name is UUID-prefixed (e.g. "nwcirqsw..._default"),
// so we can't rely on the "supabase_default" literal baked into the template.
function resolveNetworkName() {
  if (process.env.SUPABASE_NETWORK_NAME) return process.env.SUPABASE_NETWORK_NAME
  try {
    const hostname = fs.readFileSync('/etc/hostname', 'utf8').trim()
    const raw = execFileSync(
      'docker',
      ['inspect', '-f', '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}\n{{end}}', hostname],
      { encoding: 'utf8' }
    )
    const nets = raw.split('\n').map((s) => s.trim()).filter(Boolean)
    // Filter out well-known infrastructure networks that are never the
    // compose app network (Coolify management, Docker built-ins).
    const skip = new Set(['bridge', 'host', 'none', 'coolify'])
    const appNets = nets.filter((n) => !skip.has(n))
    // Prefer a _default network (Compose convention) among app networks;
    // otherwise the first app network wins. Fall back to the full list
    // if all networks were filtered out.
    const pool = appNets.length > 0 ? appNets : nets
    return pool.find((n) => n.endsWith('_default')) || pool[0] || null
  } catch (err) {
    console.warn('[sb2-agent] could not resolve network name:', err.message)
    return null
  }
}

const NETWORK_NAME = resolveNetworkName()
if (NETWORK_NAME) {
  console.log(`[sb2-agent] compose network: ${NETWORK_NAME}`)
  process.env.SUPABASE_NETWORK_NAME = NETWORK_NAME
}

// The compose project this agent belongs to (UUID-based on Coolify), used to
// scope container lookups to this stack. Null when not run by Compose.
function resolveOwnComposeProject() {
  try {
    const hostname = fs.readFileSync('/etc/hostname', 'utf8').trim()
    const project = execFileSync(
      'docker',
      ['inspect', '-f', '{{ index .Config.Labels "com.docker.compose.project" }}', hostname],
      { encoding: 'utf8' }
    ).trim()
    return project || null
  } catch (err) {
    console.warn('[sb2-agent] could not resolve own compose project:', err.message)
    return null
  }
}

const OWN_PROJECT = resolveOwnComposeProject()

// Where superbase2.sh keeps per-project state (mirrors its SB2_STATE_DIR default).
const STATE_DIR = process.env.SB2_STATE_DIR || `${DOCKER_DIR}/superbase2`

// Docker DNS / Compose project names restrict to letters, digits, underscores,
// and hyphens. SuperBase² itself restricts project names further (letters +
// digits only), but we accept the broader set so this layer doesn't silently
// reject something the script would otherwise run. The first character must
// be alphanumeric so a name can never be mistaken for a CLI flag by the
// downstream script (e.g. "-rf").
const NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9_-]{1,47}$/

// Pre-hash the token once so every auth check compares fixed-length buffers,
// avoiding the length-leak that early-returning on a length mismatch would
// introduce.
const TOKEN_HASH = TOKEN ? crypto.createHash('sha256').update(TOKEN).digest() : null

function json(res, status, body) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
  })
  res.end(payload)
}

function runScript(args, extraEnv = {}) {
  // Build a clean environment for the child process. Coolify's env panel
  // may set some variables to empty strings (e.g. SMTP_PORT=) which override
  // the defaults in the project .env file because Docker Compose prioritises
  // shell environment over --env-file. For variables where an empty string
  // would break downstream services (GoTrue can't parse "" as an int for
  // SMTP_PORT), unset them so the .env defaults take effect.
  //
  // Similarly, project-specific variables (PROJECT_JWT_SECRET, etc.) must
  // NEVER come from the shell environment — they must always come from the
  // project .env file. If Coolify's global env sets JWT_SECRET (for the
  // default project), Docker Compose would use that shell value for
  // ${PROJECT_JWT_SECRET} in the per-project compose if it happened to
  // be set, causing a JWT secret mismatch between containers and the
  // manifest. Stripping these ensures the --env-file is the sole source.
  const STRIP_IF_EMPTY = new Set([
    'SMTP_PORT', 'SMTP_HOST', 'SMTP_USER', 'SMTP_PASS',
    'SMTP_ADMIN_EMAIL', 'SMTP_SENDER_NAME',
    'MAILER_URLPATHS_CONFIRMATION', 'MAILER_URLPATHS_INVITE',
    'MAILER_URLPATHS_RECOVERY', 'MAILER_URLPATHS_EMAIL_CHANGE',
  ])
  // Project-specific vars that must always come from the project .env,
  // never from the shell environment. This prevents Coolify's global
  // JWT_SECRET or other shared vars from leaking into per-project
  // containers and causing JWT secret mismatches.
  const STRIP_ALWAYS = new Set([
    'PROJECT_JWT_SECRET',
    'PROJECT_ANON_KEY',
    'PROJECT_SERVICE_ROLE_KEY',
    'PROJECT_SECRET_KEY_BASE',
    'PROJECT_PG_META_CRYPTO_KEY',
    'PROJECT_S3_ACCESS_KEY_ID',
    'PROJECT_S3_ACCESS_KEY_SECRET',
    'PROJECT_DB_ENC_KEY',
    'PROJECT_NAME',
    'PROJECT_REF',
    'PROJECT_DB',
  ])
  const cleanEnv = {}
  for (const [k, v] of Object.entries(process.env)) {
    if (v === '' && STRIP_IF_EMPTY.has(k)) continue
    if (STRIP_ALWAYS.has(k)) continue
    cleanEnv[k] = v
  }

  return new Promise((resolve) => {
    const child = spawn('bash', [SCRIPT, ...args], {
      cwd: `${DOCKER_DIR}/superbase2`,
      env: {
        ...cleanEnv,
        PATH: cleanEnv.PATH || '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        ...extraEnv,
      },
    })

    let stdout = ''
    let stderr = ''
    let truncated = false

    const collect = (buf, target) => {
      if (truncated) return target
      const next = target + buf.toString('utf8')
      if (next.length > MAX_OUTPUT_BYTES) {
        truncated = true
        return next.slice(0, MAX_OUTPUT_BYTES) + '\n…(output truncated)\n'
      }
      return next
    }

    child.stdout.on('data', (b) => { stdout = collect(b, stdout) })
    child.stderr.on('data', (b) => { stderr = collect(b, stderr) })

    child.on('error', (err) => {
      resolve({ ok: false, exit_code: -1, stdout, stderr: `${stderr}${err.message}\n` })
    })
    child.on('close', (code) => {
      resolve({ ok: code === 0, exit_code: code ?? -1, stdout, stderr })
    })
  })
}

function authorized(req) {
  if (!TOKEN_HASH) return false
  const h = req.headers['authorization'] || ''
  const m = h.match(/^Bearer\s+(.+)$/i)
  if (!m) return false
  const givenHash = crypto.createHash('sha256').update(m[1]).digest()
  return crypto.timingSafeEqual(givenHash, TOKEN_HASH)
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost')
    const path = url.pathname

    if (path === '/health' && req.method === 'GET') {
      return json(res, 200, { ok: true, service: 'sb2-agent' })
    }

    // Global verify: check all projects' JWT secrets
    if (path === '/verify' && req.method === 'GET') {
      if (!authorized(req)) {
        return json(res, 401, { error: { message: 'Unauthorized' } })
      }
      const result = await runScript(['verify'])
      return json(res, result.ok ? 200 : 500, result)
    }

    if (!authorized(req)) {
      return json(res, 401, { error: { message: 'Unauthorized' } })
    }

    // Global rebuild-kong: regenerate Kong config with per-project routes
    if (path === '/rebuild-kong' && req.method === 'POST') {
      const result = await runScript(['rebuild-kong'])
      return json(res, result.ok ? 200 : 500, result)
    }

    // Images of the main stack's running services, for Studio's upgrade check.
    // Read from Docker rather than a compose file: on Coolify the deployed
    // compose file lives outside every container.
    if (path === '/images' && req.method === 'GET') {
      if (!OWN_PROJECT) {
        return json(res, 500, { error: { message: 'Agent is not running under Docker Compose' } })
      }
      return json(res, 200, { images: mainStackImages() })
    }

    // /projects/:name/<action>
    const m = path.match(
      /^\/projects\/([^\/]+)\/(up|down|restart|status|rotate-keys|destroy|verify)$/
    )
    if (m) {
      const name = decodeURIComponent(m[1])
      const action = m[2]
      if (!NAME_RE.test(name)) {
        return json(res, 400, { error: { message: 'Invalid project name' } })
      }

      const wantsPost = action !== 'status' && action !== 'verify'
      if (wantsPost && req.method !== 'POST') {
        res.setHeader('Allow', 'POST')
        return json(res, 405, { error: { message: 'Method not allowed' } })
      }
      if (!wantsPost && req.method !== 'GET') {
        res.setHeader('Allow', 'GET')
        return json(res, 405, { error: { message: 'Method not allowed' } })
      }

      if (action === 'restart') {
        // One script run: it checks the main stack before stopping anything,
        // so a restart during a redeploy can't leave the project stopped.
        const result = await runScript(['restart', name])
        return json(res, result.ok ? 200 : 500, result)
      }

      // rotate-keys runs the disk/DB/Kong work synchronously, then returns.
      // Container restart is the caller's responsibility (Studio fires it
      // async after responding so the browser doesn't hit a proxy timeout).
      const extraEnv = action === 'rotate-keys' ? { SB2_ROTATE_SKIP_RESTART: '1' } : {}
      // destroy prompts for confirmation on a terminal; the caller confirmed in the UI.
      const args = action === 'destroy' ? ['destroy', name, '--yes'] : [action, name]
      const result = await runScript(args, extraEnv)
      return json(res, result.ok ? 200 : 500, result)
    }

    return json(res, 404, { error: { message: 'Not found' } })
  } catch (err) {
    console.error('[sb2-agent] unhandled:', err)
    return json(res, 500, { error: { message: 'Internal error' } })
  }
})

// ── Kong config guard ────────────────────────────────────────────────────────
//
// When Coolify redeploys the main stack, it recreates the Kong container from
// the base image. The per-project routes injected by `rebuild-kong` are lost,
// so all /project/<ref>/* paths return 404 until someone manually runs
// rebuild-kong. This guard checks periodically that every project on disk has
// its routes in Kong's live config, rebuilding if any are missing.

function getKongContainerName() {
  const args = ['ps', '--filter', 'label=com.docker.compose.service=kong']
  // Scope to this stack so another stack's `kong` service is never picked up.
  if (OWN_PROJECT) args.push('--filter', `label=com.docker.compose.project=${OWN_PROJECT}`)
  args.push('--format', '{{.Names}}')
  try {
    const raw = execFileSync('docker', args, { encoding: 'utf8' })
    return raw.split('\n').map((s) => s.trim()).find(Boolean) || null
  } catch {
    return null
  }
}

// Projects this agent manages: those with a .env under STATE_DIR/projects
// (same source as superbase2.sh list_projects).
function projectNamesOnDisk() {
  const projectsDir = `${STATE_DIR}/projects`
  let names
  try {
    names = fs.readdirSync(projectsDir)
  } catch (err) {
    if (err.code === 'ENOENT') return []
    throw err
  }
  return names.filter((name) => fs.existsSync(`${projectsDir}/${name}/.env`))
}

// Refs of the projects rebuild-kong generates routes for.
function expectedProjectRefs() {
  const refs = []
  for (const name of projectNamesOnDisk()) {
    let env
    try {
      env = fs.readFileSync(`${STATE_DIR}/projects/${name}/.env`, 'utf8')
    } catch {
      continue
    }
    const ref = env.match(/^PROJECT_REF=(.+)$/m)?.[1]?.trim()
    if (ref) refs.push(ref)
  }
  return refs
}

function missingKongRefs(kongCtr, refs) {
  const config = execFileSync('docker', ['exec', kongCtr, 'cat', '/usr/local/kong/kong.yml'], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  })
  return refs.filter((ref) => !config.includes(`/project/${ref}/`))
}

async function ensureKongRoutes() {
  try {
    const refs = expectedProjectRefs()
    if (refs.length === 0) return
    const kongCtr = getKongContainerName()
    if (!kongCtr) {
      console.warn('[sb2-agent] Kong container not found; skipping route check')
      return
    }
    const missing = missingKongRefs(kongCtr, refs)
    if (missing.length === 0) return
    console.log(`[sb2-agent] Kong routes missing for ${missing.join(', ')} — rebuilding...`)
    const result = await runScript(['rebuild-kong'])
    if (result.ok) {
      console.log('[sb2-agent] Kong rebuilt successfully')
    } else {
      console.error('[sb2-agent] Kong rebuild FAILED:', result.stderr || result.stdout)
    }
  } catch (err) {
    console.error('[sb2-agent] Kong route check failed:', err.message)
  }
}

// ── Image drift ──────────────────────────────────────────────────────────────
//
// Per-project containers run the main stack's images (superbase2.sh exports
// them on every `up`). A redeploy that changes those images doesn't always
// recreate this agent, so the startup reconcile alone can miss it; compare
// periodically and reconcile when they diverge.

// Compose labels and configured image of every container matching `filters`.
function inspectContainers(filters) {
  const ids = execFileSync('docker', ['ps', '-aq', ...filters.flatMap((f) => ['--filter', f])], {
    encoding: 'utf8',
  })
    .split('\n')
    .filter(Boolean)
  if (ids.length === 0) return []
  const raw = execFileSync(
    'docker',
    [
      'inspect',
      '-f',
      '{{index .Config.Labels "com.docker.compose.project"}}\t{{index .Config.Labels "com.docker.compose.service"}}\t{{.Config.Image}}\t{{.State.Running}}',
      ...ids,
    ],
    { encoding: 'utf8' }
  )
  return raw
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      const [project, service, image, running] = line.split('\t')
      return { project, service, image, running: running === 'true' }
    })
}

function mainStackImages() {
  const images = {}
  for (const c of inspectContainers([`label=com.docker.compose.project=${OWN_PROJECT}`])) {
    if (c.running && c.service) images[c.service] = c.image
  }
  return images
}

// This agent's per-project containers (compose project `supabase-<name>` for a
// project on disk) whose image differs from the main-stack service they
// mirror, e.g. `auth-foo` vs `auth`. Other `supabase-*` stacks on the host
// (another sb2 install, orphans of a failed destroy) are not ours to fix:
// reconcile can't change them, so counting them would reconcile forever.
function driftedProjects() {
  const main = mainStackImages()
  const ours = new Set(projectNamesOnDisk())
  const drifted = new Set()
  for (const c of inspectContainers(['label=com.docker.compose.project'])) {
    if (c.project === OWN_PROJECT || !c.project.startsWith('supabase-')) continue
    const name = c.project.slice('supabase-'.length)
    if (!ours.has(name) || !c.service.endsWith(`-${name}`)) continue
    const base = c.service.slice(0, -(name.length + 1))
    if (main[base] && main[base] !== c.image) drifted.add(name)
  }
  return [...drifted]
}

// Check every 5 minutes (Coolify can redeploy at any time)
const CHECK_INTERVAL_MS = 5 * 60 * 1000
const MAX_RETRY_DELAY_MS = 60 * 60 * 1000

// A failed reconcile (main stack mid-redeploy, one broken project) is retried
// even if no image drifted, since a template or env change would otherwise
// never reach the projects. Full retries back off from 5 minutes to an hour,
// so a project that keeps failing doesn't reload Kong every check. Meanwhile
// drifted projects other than the failed ones are still reconciled on their
// own, so one broken project can't hold back another's image update.
let reconcileFailures = 0
let nextReconcileAt = 0
let failedProjects = new Set()

// `names` empty = every started project (and the result decides the backoff).
async function reconcile(reason, names = []) {
  console.log(`[sb2-agent] reconciling per-project containers (${reason})...`)
  const result = await runScript(['reconcile', ...names])
  if (result.ok) {
    if (names.length === 0) {
      reconcileFailures = 0
      failedProjects = new Set()
    }
    console.log('[sb2-agent] reconcile done:\n' + result.stdout)
    return
  }
  const failed = (result.stderr.match(/^Error: failed to start project\(s\): (.+)$/m)?.[1] ?? '')
    .split(' ')
    .filter(Boolean)
  for (const name of failed) failedProjects.add(name)
  if (names.length > 0) {
    console.error('[sb2-agent] reconcile FAILED:\n' + (result.stderr || result.stdout))
    return
  }
  reconcileFailures += 1
  const delay = Math.min(CHECK_INTERVAL_MS * 2 ** (reconcileFailures - 1), MAX_RETRY_DELAY_MS)
  nextReconcileAt = Date.now() + delay
  console.error(
    `[sb2-agent] reconcile FAILED (attempt ${reconcileFailures}; retrying in ${Math.round(delay / 60000)} min):\n` +
      (result.stderr || result.stdout)
  )
}

let checkRunning = false

async function periodicCheck() {
  // A reconcile can outlast the interval (it waits for the main stack and the
  // state lock); don't start another check on top of it.
  if (checkRunning) return
  checkRunning = true
  try {
    let drifted = []
    if (OWN_PROJECT) {
      try {
        drifted = driftedProjects()
      } catch (err) {
        console.error('[sb2-agent] image drift check failed:', err.message)
      }
    }
    // reconcile rebuilds Kong too, so it covers the route check.
    if (reconcileFailures > 0 && Date.now() >= nextReconcileAt) {
      await reconcile('retrying after a failed reconcile')
    } else if (reconcileFailures === 0 && drifted.length > 0) {
      await reconcile(`images differ from the main stack for ${drifted.join(', ')}`)
    } else if (drifted.some((name) => !failedProjects.has(name))) {
      const healthy = drifted.filter((name) => !failedProjects.has(name))
      await reconcile(`images differ from the main stack for ${healthy.join(', ')}`, healthy)
    } else {
      await ensureKongRoutes()
    }
  } finally {
    checkRunning = false
  }
}

server.listen(PORT, async () => {
  console.log(`[sb2-agent] listening on :${PORT} (docker_dir=${DOCKER_DIR})`)
  // Bring started projects in line with the (re)deployed main stack. This
  // also rebuilds Kong, so it replaces an initial route check.
  await reconcile('startup')
  setInterval(periodicCheck, CHECK_INTERVAL_MS)
})

const shutdown = () => {
  console.log('[sb2-agent] shutting down')
  server.close(() => process.exit(0))
  setTimeout(() => process.exit(1), 5000).unref()
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
