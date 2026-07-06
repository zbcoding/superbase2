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
 *   POST /rebuild-kong              Regenerate Kong config with per-project routes
 *   POST /projects/:name/up
 *   POST /projects/:name/down
 *   POST /projects/:name/restart
 *   POST /projects/:name/rotate-keys
 *   GET  /projects/:name/status
 *   GET  /projects/:name/verify     Check single project's JWT secrets match manifest
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
      if (!authorized(req)) {
        return json(res, 401, { error: { message: 'Unauthorized' } })
      }
      const result = await runScript(['rebuild-kong'])
      return json(res, result.ok ? 200 : 500, result)
    }

    // /projects/:name/<action>
    const m = path.match(/^\/projects\/([^\/]+)\/(up|down|restart|status|rotate-keys|verify)$/)
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
        const down = await runScript(['down', name])
        const up = await runScript(['up', name])
        return json(res, up.ok ? 200 : 500, {
          ok: up.ok,
          down,
          up,
        })
      }

      // rotate-keys runs the disk/DB/Kong work synchronously, then returns.
      // Container restart is the caller's responsibility (Studio fires it
      // async after responding so the browser doesn't hit a proxy timeout).
      const extraEnv = action === 'rotate-keys' ? { SB2_ROTATE_SKIP_RESTART: '1' } : {}
      const result = await runScript([action, name], extraEnv)
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
// rebuild-kong. This guard checks on startup (and periodically) whether the
// Kong config has per-project routes, rebuilding automatically if missing.

async function getKongContainerName() {
  try {
    const raw = execFileSync('docker', ['ps', '--filter', 'label=com.docker.compose.service=kong', '--format', '{{.Names}}'], { encoding: 'utf8' })
    return raw.split('\n').map(s => s.trim()).find(Boolean) || null
  } catch { return null }
}

async function kongHasProjectRoutes() {
  const kongCtr = await getKongContainerName()
  if (!kongCtr) return false
  try {
    // Check if any /project/ routes exist in the kong.yml
    const raw = execFileSync('docker', ['exec', kongCtr, 'grep', '-c', '/project/', '/usr/local/kong/kong.yml'], { encoding: 'utf8' })
    const count = parseInt(raw.trim(), 10)
    return count > 0
  } catch {
    // grep returns exit 1 if no matches, which throws
    return false
  }
}

async function ensureKongRoutes() {
  const hasRoutes = await kongHasProjectRoutes()
  if (hasRoutes) {
    console.log('[sb2-agent] Kong per-project routes OK')
    return
  }
  console.log('[sb2-agent] Kong per-project routes MISSING — rebuilding...')
  const result = await runScript(['rebuild-kong'])
  if (result.ok) {
    console.log('[sb2-agent] Kong rebuilt successfully')
  } else {
    console.error('[sb2-agent] Kong rebuild FAILED:', result.stderr || result.stdout)
  }
}

// Check every 5 minutes (Coolify can redeploy at any time)
const KONG_CHECK_INTERVAL_MS = 5 * 60 * 1000

server.listen(PORT, async () => {
  console.log(`[sb2-agent] listening on :${PORT} (docker_dir=${DOCKER_DIR})`)
  // Initial check on startup
  await ensureKongRoutes()
  // Periodic check
  setInterval(ensureKongRoutes, KONG_CHECK_INTERVAL_MS)
})

const shutdown = () => {
  console.log('[sb2-agent] shutting down')
  server.close(() => process.exit(0))
  setTimeout(() => process.exit(1), 5000).unref()
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
