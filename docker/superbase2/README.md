# ⚡² SuperBase²

**Multi-project layer for self-hosted [Supabase](../../README.md).**

Run multiple database projects on a single Supabase deployment — one PostgreSQL instance, one API gateway, one dashboard — with isolated auth, storage, and APIs per project.

> **Status: Experimental / Hobby-use**
> SuperBase² is new and untested in production. It works by layering on top of stock Supabase without modifying any upstream files, so it inherits Supabase's stability for the core infrastructure — the multi-project orchestration itself is what's young.
>
> **What's roughly tested:**
> - Creating, starting, stopping, and destroying projects from the `/sb2` UI and CLI
> - Multiple isolated databases on the shared Postgres, each visible in Studio with the correct schema/tables (table editor, SQL editor, postgres-meta routing per project)
> - Per-project API keys + zero-downtime rotation through Kong reload
> - Studio project switcher / `Cmd+K` / dashboard auth admin against the per-project GoTrue
>
> **What still needs work / is not exercised yet:**
> - Realtime — boots and per-project tenant is seeded, but subscriptions haven't been smoke-tested end-to-end
> - Storage — per-project containers come up and Kong routes resolve, but uploads/downloads/imgproxy paths are unverified
> - Edge Functions, Analytics/Logflare, Supavisor pooler — wired up but not validated under real load
> - Running more than a handful of projects on a single host
>
> Great for hobby projects, side projects, and development environments. Use in production at your own discretion.

---

## What it does

Self-hosted Supabase is hardcoded to a single project. If you want to run two apps (say, a main product and an internal tool), you'd normally need two full Supabase stacks — duplicating PostgreSQL, Kong, Studio, analytics, and everything else.

SuperBase² fixes this:

- **Heavy containers are shared** — PostgreSQL, Kong (API gateway), Studio (dashboard), imgproxy, analytics, vector, and the connection pooler run once regardless of how many projects you have.
- **Lightweight containers are per-project** — GoTrue (auth), PostgREST (REST API), Realtime, Storage, Edge Functions, and postgres-meta each get a small isolated instance per project, pointed at their own database.
- **Each project gets its own database** on the shared PostgreSQL instance, with its own JWT secrets, API keys, auth schema, and storage.
- **Everything routes through one port** — Kong on `:8000` handles routing to the right per-project service based on the project ref in the URL path.
- **The Studio dashboard gets a project switcher** — the existing sidebar project selector and `Cmd+K` search just work, showing all your projects. postgres-meta queries (table editor, SQL editor) are routed to the correct per-project database based on the project ref in the URL, and Studio's auth admin panel talks to the per-project GoTrue.
- **A dedicated SB2 dashboard** at `/sb2` lets you create projects, start/stop/restart them with confirmation prompts, view & rotate per-project API keys (zero-downtime via Kong reload), and check for upstream updates — visually distinct from the standard Supabase UI.
- **A small sidecar agent (`sb2-agent`)** runs alongside the stack and exposes the project lifecycle (create / up / down / restart / rotate-keys / rebuild-kong) over an internal HTTP API, so the `/sb2` UI can drive Docker without giving Studio direct socket access. It also auto-restores per-project Kong routes on every (re)deploy.

## Design: seamless upstream updates

SuperBase² is designed so that updating Supabase is painless:

- **Zero modifications to existing Supabase files.** Every SuperBase² file is new — new directories, new API routes, new middleware, new compose files. Nothing in the original Supabase codebase is edited.
- **`git pull` just works.** Because no upstream files are touched, pulling new Supabase releases won't cause merge conflicts. The only theoretical future conflict is if Supabase adds their own `middleware.ts` (they don't have one today) — and that would be a one-time, straightforward merge.
- **Stock Docker images for all services.** Per-project services (GoTrue, PostgREST, Realtime, Storage, Edge Functions, postgres-meta) use the exact same official Supabase Docker images — no forks, no custom builds. When Supabase releases a new version, pull and restart. The Studio is the one exception: it must be built from this fork's source because the SuperBase² API routes live inside it.
- **Upgrade detection built in.** The `/sb2` dashboard checks Docker Hub for newer image tags and shows a banner when updates are available, along with the exact commands to run.

```
# Upgrading (VPS / bare metal):
git pull upstream master
docker compose -f docker-compose.yml -f docker-compose.superbase2.yml pull
docker compose -f docker-compose.yml -f docker-compose.superbase2.yml up -d

# Upgrading (Coolify): merge upstream, then re-generate the Coolify compose file.
# See the Coolify section below for details.
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Shared (run once)                     │
│  ┌──────────┐ ┌──────┐ ┌────────┐ ┌────────┐ ┌───────┐ │
│  │ Postgres │ │ Kong │ │ Studio │ │Imgproxy│ │Vector │ │
│  │ (all DBs)│ │:8000 │ │  :3000 │ │        │ │       │ │
│  └──────────┘ └──┬───┘ └────────┘ └────────┘ └───────┘ │
│                  │                                      │
│    ┌─────────────┼─────────────┐                        │
│    │ /project/abc123/rest/v1/  │ Kong routes by         │
│    │ /project/abc123/auth/v1/  │ project ref prefix     │
│    │ /project/def456/rest/v1/  │                        │
│    └─────────────┼─────────────┘                        │
└──────────────────┼──────────────────────────────────────┘
                   │
    ┌──────────────┼──────────────┐
    ▼              ▼              ▼
┌────────┐   ┌────────┐   ┌────────┐
│Project │   │Project │   │Project │   Per-project
│  abc   │   │  def   │   │  ghi   │   (lightweight)
│        │   │        │   │        │
│GoTrue  │   │GoTrue  │   │GoTrue  │   ~30 MB
│PostgRST│   │PostgRST│   │PostgRST│   ~15 MB
│Realtime│   │Realtime│   │Realtime│   ~100 MB
│Storage │   │Storage │   │Storage │   ~50 MB
│EdgeFn  │   │EdgeFn  │   │EdgeFn  │   ~80 MB
│pg-meta │   │pg-meta │   │pg-meta │   ~20 MB
└────────┘   └────────┘   └────────┘
```

Each per-project container connects to its own database on the shared PostgreSQL instance and uses its own JWT secret. They communicate over Docker's internal network — no extra ports exposed.

---

## Install

### Option A: Any server (VPS, bare metal, etc.)

```bash
git clone https://github.com/zbcoding/superbase2.git
cd superbase2/docker/superbase2
./install.sh
```

The install script handles everything interactively:
1. Checks prerequisites (Docker, openssl)
2. Generates all secrets
3. Asks for your domain (or defaults to localhost)
4. Builds the Studio from source (~5–15 min on first run, cached after that)
5. Pulls all other Docker images
6. Starts the shared infrastructure
7. Optionally creates your first project

Or non-interactively:

```bash
./install.sh --project myapp
```

### Option B: Coolify

Coolify expects a single compose file — it does not support the multi-file `-f … -f …` syntax. A pre-merged `docker-compose.coolify.yml` is provided for this.

1. Fork this repo on GitHub, push your SuperBase² changes, and merge to your master branch.
2. In Coolify: **New Resource → Docker Compose**
3. Git source: your fork, master branch
4. Base directory: `/docker`
5. Docker Compose Location: `/docker/docker-compose.coolify.yml`
6. Generate environment variables and paste them into Coolify's **Environment Variables** panel:
   ```bash
   cd docker && sh utils/generate-keys.sh --coolify
   ```
   Copy the entire output and paste it in one go — Coolify reads `KEY=value` lines and ignores `#` comment lines. All secrets are freshly generated. You only need to fill in two things manually:
   - `SUPABASE_PUBLIC_URL` — your Kong domain (set this after step 7, then save).
   - `DASHBOARD_PASSWORD` — change to a strong password.

   Two optional SuperBase² toggles:

   | Variable | Default | What it does |
   |---|---|---|
   | `SUPERBASE2_ENABLED` | `true` | Multi-project mode. Set `false` for plain single-project Supabase. |

   Do **not** add `COOLIFY_RESOURCE_UUID` here — Coolify injects it into every container it manages, and SuperBase² reads it to decide whether the upgrade banner shows shell commands or "redeploy in Coolify". If a future Coolify version stops setting it, the banner reverts to shell commands that won't survive your next redeploy; set it manually at that point.

7. **Configure Domains in Coolify:** Coolify auto-generates a domain field for every service in the compose file. **Kong is the only service that gets a domain.** Everything else must be cleared.
   - `kong` → set your public domain, e.g. `https://supabase.yourdomain.com:8000`. Two requirements:
     - **`https://` prefix is required** — without it Coolify only generates HTTP routes and HTTPS will not work.
     - **`:8000` suffix is for Coolify only** — it tells Traefik which container port to forward to. It is not part of your public URL and must not appear in `SUPABASE_PUBLIC_URL`.
   - `studio` → leave blank. Kong proxies `/` to Studio after auth. A direct Studio domain bypasses Kong and exposes the dashboard without authentication.
   - All other services (`auth`, `rest`, `storage`, `meta`, `realtime`, `vector`, `imgproxy`, `functions`, `analytics`, `supavisor`, `superbase2-init`) → **delete their domains entirely** — these are internal microservices that must stay behind Kong.

   Once you have the Kong domain, go back to step 6 and set `SUPABASE_PUBLIC_URL` to your domain without the port — e.g. `https://supabase.yourdomain.com`.

8. **Configure Coolify Advanced Settings:** Go to the deployment's **Advanced** tab and enable:
   - **Connect To Predefined Network** — required for Traefik to reliably reach your containers. Without this, Coolify's proxy may pick the wrong Docker network IP and return 504 Gateway Timeout errors even though all containers are healthy.
   - **Force HTTPS** — redirects HTTP to HTTPS.

9. **Configure DNS:** Point your chosen domains to your server's IP.
   - If using **Cloudflare proxy** (orange cloud): set SSL mode to **Full** (not Strict, unless you've installed a Cloudflare Origin CA certificate). Coolify's Traefik will auto-provision Let's Encrypt certificates for the origin.
   - If using **Cloudflare DNS only** (grey cloud) or **other DNS providers**: Traefik's Let's Encrypt certificates will be served directly to browsers. No extra SSL configuration needed.

10. Deploy — Coolify pulls the pre-built Studio image from ghcr.io (fast, no build step).

### What happens on first boot

Coolify cannot bind-mount individual files from the git repo (Docker creates directories where files are expected), so `docker-compose.coolify.yml` ships with a set of one-shot **init containers** that materialize config and SQL into named volumes before the real services start. They all use `restart: "no"` and run to completion in dependency order:

| Init container | Image | Purpose |
|---|---|---|
| `db-init` | alpine:3.19 | Writes all Postgres migrations and init scripts (`97-_supabase.sql`, `99-realtime.sql`, `99-logs.sql`, `99-pooler.sql`, `98-webhooks.sql`, `99-roles.sql`, `99-jwt.sql`) into the `db-init-migrations` and `db-init-initscripts` volumes. The `db` service mounts these as `/docker-entrypoint-initdb.d/*`. |
| `db-setup` | postgres client | Runs after `db` is healthy. Ensures the `_supabase` database and required schemas exist on subsequent boots (Postgres's `docker-entrypoint-initdb.d` only runs on first init when PGDATA is empty, so this fills the gap for restarts). |
| `kong-init` | alpine:3.19 | Decodes the base64-embedded `kong.yml` and entrypoint into the `kong-config` volume. Kong then reads its declarative config from the volume instead of a bind-mount. |
| `vector-pooler-init` | busybox:1.37 | Writes Vector and Supavisor pooler config files into the `vector-config` volume. |
| `functions-init` | alpine:3.19 | Creates a default `main/index.ts` in the edge-functions volume if one doesn't already exist, so the `functions` service has something to serve on a clean install. |
| `superbase2-init` | alpine:3.19 | Creates the `projects.json` manifest file that the SB2 middleware reads, and verifies `ANON_KEY` / `SERVICE_ROLE_KEY` against `JWT_SECRET` (HMAC check) — fails fast with a remediation message if keys drifted from the live secret instead of letting Studio crash later with `bad_jwt` 403s. `studio` depends on this completing successfully. |
| `kong-sb2-init` | sb2-agent | Waits for Kong readiness, then re-runs `rebuild-kong` so that per-project routes (`/project/<ref>/*`) are restored on every Coolify redeploy. Without this, redeploys would ship a base-only Kong config and break auth/rest/realtime/storage for all existing projects. |
| `sb2-agent` | sb2-agent | Long-running sidecar (not an init container). Owns the Docker socket and exposes the project lifecycle API consumed by the `/sb2` UI. Periodically checks Kong routes and rebuilds them if missing. |

If a deployment hangs, check these containers' logs first — a failed init container will block its dependents via `condition: service_completed_successfully`.

Once running, verify the deployment:
- Open your Kong domain — a browser basic-auth popup should appear. Credentials: username `supabase`, password is your `DASHBOARD_PASSWORD` env var. After auth, Kong proxies `/` to Studio.

Open `/sb2` in your browser to create and manage projects. The `sb2-agent` sidecar handles the container lifecycle — Create, Start, Stop, Restart, and Rotate Keys are all driven from the UI without SSH. SSH is still useful for `superbase2.sh` advanced commands (`destroy`, `verify`, `status`, `client-config`).

**Upgrading on Coolify:** When Supabase releases updates, merge upstream into your fork and push to master — Coolify will pick up the new `docker-compose.coolify.yml` on its next deploy.

```bash
git fetch upstream
git merge upstream/master
# Resolve any conflicts in docker-compose.coolify.yml (the pre-merged file)
# by re-applying the diff from docker-compose.superbase2.yml on top of the
# new upstream docker-compose.yml. The overlay is the source of truth for
# SB2 changes; the coolify file is its flattened form.
git push origin master
```

Then in Coolify: **Deploy** → Coolify pulls the updated compose file and the latest Studio image from ghcr.io. The init containers re-run on every deploy and are idempotent, so config files and the admin user get refreshed automatically.

**Why a merged file instead of the overlay:** Coolify does not support Docker Compose's multi-file `-f` flag. The `docker-compose.coolify.yml` is a pre-merged copy of `docker-compose.yml` + `docker-compose.superbase2.yml`. The overlay file remains the canonical source for SuperBase² changes.

**Why base directory is `/docker` and not `/docker/superbase2`:** Coolify reads `.env.example` from the base directory to populate its env var GUI. By pointing at `/docker`, Coolify reads Supabase's upstream `.env.example` directly — so when Supabase adds new variables, they automatically appear in your Coolify GUI without any SuperBase² changes.

**How the lifecycle works:** Starting Docker containers requires Docker socket access, which the Studio web app deliberately doesn't have. Instead, the `sb2-agent` sidecar owns the socket and exposes a small internal HTTP API (`/projects/:name/up`, `/down`, `/restart`, `/rotate-keys`, `/rebuild-kong`, `/verify`) that Studio's middleware calls. The agent runs on the same Docker network and is not exposed publicly. SSH stays available as a fallback through `superbase2.sh`, but isn't required for routine use.

### Fully removing a SuperBase² deployment (Coolify)

Deleting the app in the Coolify UI removes containers and the application directory (`/data/coolify/applications/<app-id>/`), but **leaves named Docker volumes behind**. Those volumes hold state that you must wipe explicitly if you want a clean re-deploy, or if the deployment was ever exposed without auth and you're sure nothing valuable is in them:

```bash
# Replace with your app's Coolify ID (shown in the UI URL or as the prefix
# on container names: e.g. db-<app-id>-xxxxx)
APP_ID=<your-app-id>   # e.g. the 24-char hash from the Coolify app URL

# 1. Stop & delete the resource in the Coolify UI first (Settings → Delete).
#    This removes the containers and the application directory.

# 2. Remove named volumes the UI does NOT delete. Project/studio metadata
#    (the SB2 sidecar's projects.json, saved connections, etc.) lives in
#    superbase2-config, so it survives a plain app-delete.
docker volume rm \
  ${APP_ID}_db-config \
  ${APP_ID}_db-init-initscripts \
  ${APP_ID}_db-init-migrations \
  ${APP_ID}_deno-cache \
  ${APP_ID}_functions-data \
  ${APP_ID}_kong-config \
  ${APP_ID}_pooler-config \
  ${APP_ID}_superbase2-config \
  ${APP_ID}_vector-config

# 3. If the application directory still exists (e.g. you only stopped the
#    app without deleting), remove the PGDATA bind-mount and stale init
#    SQL directories manually:
rm -rf /data/coolify/applications/${APP_ID}/volumes/db/data
rm -rf /data/coolify/applications/${APP_ID}/volumes/db/*.sql

# 4. Verify — no volumes and no app dir should match:
docker volume ls | grep ${APP_ID}
ls /data/coolify/applications/ | grep ${APP_ID}
```

Partial resets (keep the app, wipe only the database): stop the app in the UI, then delete `volumes/db/data` plus the `db-config` / `db-init-*` volumes. On next deploy, Postgres initializes a fresh cluster. Leave `superbase2-config` alone if you want to preserve the SB2 project list.

**Troubleshooting Coolify deployments:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| 503 Service Unavailable | Traefik has no router for the domain | Check that domains in Coolify include the `https://` prefix and correct port |
| 504 Gateway Timeout (but containers are healthy) | Traefik picking wrong Docker network IP | Enable "Connect To Predefined Network" in Advanced settings |
| Too many redirects | Cloudflare SSL mode conflict with Force HTTPS | Set Cloudflare SSL to Full; if that doesn't work, temporarily set to Flexible to regain access |
| Browser "not secure" warning | No HTTPS router generated | Ensure domain has `https://` prefix in Coolify; verify with `docker inspect <kong-container> --format '{{json .Config.Labels}}'` and look for `entryPoints = https` |
| Kong crash-looping (`error parsing declarative config`) | Corrupt or empty `kong.yml` | Check `kong-init` container logs; verify the base64 blob decodes correctly |

---

## Usage

### Creating projects

**From the browser (default):**

1. Navigate to `/sb2`, type a project name, click Create. The `sb2-agent` sidecar provisions the database, mints secrets, rebuilds Kong, and starts the per-project containers.
2. From the project card you can Start / Stop / Restart (with a confirmation modal that warns about downtime), open the Keys panel to view the project ref + ANON / SERVICE_ROLE keys, and rotate keys (Kong reloads in place — other projects are unaffected).

**From SSH (CLI fallback):**

```bash
cd docker/superbase2
./superbase2.sh setup myproject     # creates DB, secrets, Kong routes, starts containers
# or two-step:
./superbase2.sh create myproject    # creates DB, secrets, Kong routes
./superbase2.sh up myproject        # starts per-project containers
```

### Switching between projects

The standard Supabase Studio sidebar and `Cmd+K` project switcher work automatically — they show all your projects. Click one to switch.

### Managing projects

```bash
./superbase2.sh list                    # list all projects
./superbase2.sh status                  # show container status (warns on JWT-secret drift)
./superbase2.sh verify                  # check that container JWT secrets match the manifest
./superbase2.sh client-config myproject # print SDK connection details
./superbase2.sh rotate-keys myproject   # mint a fresh JWT secret + ANON/SERVICE keys, reload Kong
./superbase2.sh rebuild-kong            # regenerate per-project Kong routes (zero-downtime reload)
./superbase2.sh down myproject          # stop a project's containers
./superbase2.sh destroy myproject       # delete project, database, and all data
```

### Connecting from your app

```js
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'https://your-domain.com/project/<ref>',
  '<anon-key>'  // from: ./superbase2.sh client-config <name>
)
```

---

## Checking for updates

The `/sb2` dashboard automatically checks Docker Hub for newer image tags. When updates are available, it shows an amber banner with the outdated services and upgrade commands.

The banner shows shell commands built from `SUPERBASE2_COMPOSE_CMD`, **except on Coolify**, where it shows "Redeploy the application in Coolify" instead. Coolify regenerates the compose file on every deploy and keeps it outside the container, so a hand-run `docker compose up -d` is undone by the next redeploy.

That branch is keyed on `COOLIFY_RESOURCE_UUID`, which Coolify injects into every container it manages (alongside `COOLIFY_CONTAINER_NAME`, `COOLIFY_FQDN`, `COOLIFY_URL`, `COOLIFY_BRANCH`). Nothing sets it in the standalone install. If Coolify ever renames that variable, the upgrade banner falls back to shell commands — wrong advice, but not a broken deployment. Set it manually to force the Coolify wording on a non-Coolify host.

You can also check programmatically:

```bash
curl http://localhost:8000/api/superbase2/upgrade
```

---

## How it works (technical)

SuperBase² adds these files (all new, none modified):

| File | Purpose |
|------|---------|
| `apps/studio/middleware.ts` | Intercepts Supabase API calls and rewrites them to SB2 handlers when enabled. Also injects the per-project DB connection header into postgres-meta requests so Studio's table/SQL editors hit the right database. |
| `apps/studio/lib/superbase2/` | Project manifest reader/writer, DB provisioning, response shape helpers, agent client |
| `apps/studio/pages/api/superbase2/` | API routes for project CRUD, lifecycle (start/stop/restart), key rotation, org listing, upgrade checks. Lifecycle + rotation routes proxy to the `sb2-agent` sidecar. |
| `apps/studio/pages/sb2/` | SB2 dashboard UI (amber-themed, distinct from Supabase green) — project cards, lifecycle controls, keys panel |
| `docker/superbase2/agent/` | `sb2-agent` sidecar: Node HTTP service that owns the Docker socket and exposes the project lifecycle / key rotation / Kong rebuild endpoints. Also hosts the baked init configs (`agent/configs/`) so they survive Coolify's ARG_MAX limit. |
| `docker/superbase2/superbase2.sh` | CLI for creating/managing projects and per-project containers (still works; the agent shells out to it under the hood) |
| `docker/superbase2/templates/` | Docker Compose and Kong config templates for per-project services |
| `docker/docker-compose.superbase2.yml` | Overlay that enables SB2 on the Studio container |
| `docker/docker-compose.coolify.yml` | Pre-merged single compose file for Coolify (base + overlay combined) |
| `docker/superbase2/docker-compose.standalone.yml` | All-in-one merged file for standalone deployment without the upstream Supabase stack |

The middleware (`middleware.ts`) is the key integration point. When `SUPERBASE2_ENABLED=true`, it intercepts requests to `/api/platform/projects`, `/api/platform/organizations/*/projects`, and `/api/platform/profile`, rewriting them to the SB2 API routes. The SB2 routes read from a shared `projects.json` manifest instead of returning the hardcoded single default project.

The existing Studio UI components — project switcher, command palette, project cards — all work unmodified because the SB2 API routes return the exact same response shapes that the Supabase Cloud API uses.

---

## Known limitations

- **Realtime / Storage / Edge Functions / Analytics are not exercised yet.** Containers boot and Kong routes resolve, but real subscriptions, file uploads, function invocations, and log queries haven't been smoke-tested end-to-end. Expect rough edges and please open issues.
- **Kong API keys are per-project.** Each project gets its own consumers and API key credentials in Kong, generated during `rebuild-kong`. Projects are isolated at both the Kong routing layer (API key validation) and the JWT level (per-service JWT secrets).
- **Untested at scale.** This has been tested with a handful of projects. Running 50+ projects on one instance is uncharted territory.

---

## Acknowledgments

SuperBase² is built entirely on top of [Supabase](https://supabase.com), which is open source under the [Apache 2.0 license](../../LICENSE). SuperBase² does not modify any Supabase source code — it layers additional functionality on top of the official self-hosted Docker deployment.

For Supabase documentation, setup guides, and the full platform feature set, see the **[main Supabase README](../../README.md)** and **[supabase.com/docs](https://supabase.com/docs)**.
