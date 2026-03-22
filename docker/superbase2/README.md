# ⚡² SuperBase²

**Multi-project layer for self-hosted [Supabase](../../README.md).**

Run multiple database projects on a single Supabase deployment — one PostgreSQL instance, one API gateway, one dashboard — with isolated auth, storage, and APIs per project.

> **Status: Experimental / Hobby-use**
> SuperBase² is new and untested in production. It works by layering on top of stock Supabase without modifying any upstream files. This means it inherits Supabase's stability for the core infrastructure, but the multi-project orchestration itself hasn't been battle-tested yet. Great for hobby projects, side projects, and development environments. Use in production at your own discretion.

---

## What it does

Self-hosted Supabase is hardcoded to a single project. If you want to run two apps (say, a main product and an internal tool), you'd normally need two full Supabase stacks — duplicating PostgreSQL, Kong, Studio, analytics, and everything else.

SuperBase² fixes this:

- **Heavy containers are shared** — PostgreSQL, Kong (API gateway), Studio (dashboard), imgproxy, analytics, vector, and the connection pooler run once regardless of how many projects you have.
- **Lightweight containers are per-project** — GoTrue (auth), PostgREST (REST API), Realtime, Storage, Edge Functions, and postgres-meta each get a small isolated instance per project, pointed at their own database.
- **Each project gets its own database** on the shared PostgreSQL instance, with its own JWT secrets, API keys, auth schema, and storage.
- **Everything routes through one port** — Kong on `:8000` handles routing to the right per-project service based on the project ref in the URL path.
- **The Studio dashboard gets a project switcher** — the existing sidebar project selector and `Cmd+K` search just work, showing all your projects.
- **A dedicated SB2 dashboard** at `/sb2` lets you create projects and check for upstream updates, visually distinct from the standard Supabase UI.

## Design: seamless upstream updates

SuperBase² is designed so that updating Supabase is painless:

- **Zero modifications to existing Supabase files.** Every SuperBase² file is new — new directories, new API routes, new middleware, new compose files. Nothing in the original Supabase codebase is edited.
- **`git pull` just works.** Because no upstream files are touched, pulling new Supabase releases won't cause merge conflicts. The only theoretical future conflict is if Supabase adds their own `middleware.ts` (they don't have one today) — and that would be a one-time, straightforward merge.
- **Stock Docker images.** SuperBase² uses the exact same official Supabase Docker images. No custom builds, no forks of individual services. When Supabase releases a new version of GoTrue or PostgREST, you pull the new image and restart.
- **Upgrade detection built in.** The `/sb2` dashboard checks Docker Hub for newer image tags and shows a banner when updates are available, along with the exact commands to run.

```
# Upgrading is three commands:
git pull upstream master
docker compose -f superbase2/docker-compose.coolify.yml pull
docker compose -f superbase2/docker-compose.coolify.yml up -d
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
git clone https://github.com/YOUR_USERNAME/supabase.git
cd supabase/docker/superbase2
./install.sh
```

The install script handles everything interactively:
1. Checks prerequisites (Docker, openssl)
2. Generates all secrets
3. Asks for your domain (or defaults to localhost)
4. Pulls Docker images
5. Starts the shared infrastructure
6. Optionally creates your first project

Or non-interactively:

```bash
./install.sh --project myapp
```

### Option B: Coolify

1. Fork this repo on GitHub
2. In Coolify: **New Resource → Docker Compose**
3. Git source: your fork, branch with SuperBase²
4. Base directory: `docker` (important — this is where upstream's `.env.example` lives, so Coolify auto-detects all Supabase env vars in its GUI)
5. Compose file: `superbase2/docker-compose.coolify.yml`
6. Coolify shows all the environment variables from Supabase's `.env.example` in its GUI. Generate secrets locally and fill them in:
   ```bash
   cd docker && sh utils/generate-keys.sh
   ```
   Update `SUPABASE_PUBLIC_URL` and `API_EXTERNAL_URL` to your domain.
   The two SuperBase² variables (`SUPERBASE2_ENABLED`, `SUPERBASE2_MANIFEST`) are hardcoded in the compose file — you don't need to configure them.
7. Deploy

Once running, open `/sb2` in your browser to create projects.

**Why base directory is `docker/` and not `docker/superbase2/`:** Coolify reads `.env.example` from the base directory to populate its env var GUI. By pointing at `docker/`, Coolify reads Supabase's upstream `.env.example` directly — so when Supabase adds new variables, they automatically appear in your Coolify GUI without any SuperBase² changes. Zero merge conflicts.

### Option C: Two-file compose (advanced)

If you already have Supabase self-hosted running and want to add SuperBase² on top:

```bash
cd docker
docker compose -f docker-compose.yml -f docker-compose.superbase2.yml up -d
```

---

## Usage

### Creating projects

**From the browser:**

Navigate to `/sb2`, type a project name, click Create. This creates the database and secrets. You'll need to SSH in to start the per-project containers:

```bash
cd docker/superbase2
./superbase2.sh up myproject
```

**From the command line:**

```bash
./superbase2.sh create myproject   # creates DB, secrets, Kong routes
./superbase2.sh up myproject       # starts per-project containers
```

### Switching between projects

The standard Supabase Studio sidebar and `Cmd+K` project switcher work automatically — they show all your projects. Click one to switch.

### Managing projects

```bash
./superbase2.sh list                    # list all projects
./superbase2.sh status                  # show container status
./superbase2.sh client-config myproject # print SDK connection details
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

You can also check programmatically:

```bash
curl http://localhost:8000/api/superbase2/upgrade
```

---

## How it works (technical)

SuperBase² adds these files (all new, none modified):

| File | Purpose |
|------|---------|
| `apps/studio/middleware.ts` | Intercepts Supabase API calls and rewrites them to SB2 handlers when enabled |
| `apps/studio/lib/superbase2/` | Project manifest reader/writer, DB provisioning, response shape helpers |
| `apps/studio/pages/api/superbase2/` | API routes for project CRUD, org listing, upgrade checks |
| `apps/studio/pages/sb2/` | SB2 dashboard UI (amber-themed, distinct from Supabase green) |
| `docker/superbase2/superbase2.sh` | CLI for creating/managing projects and per-project containers |
| `docker/superbase2/templates/` | Docker Compose and Kong config templates for per-project services |
| `docker/docker-compose.superbase2.yml` | Overlay that enables SB2 on the Studio container |
| `docker/superbase2/docker-compose.coolify.yml` | All-in-one compose file for single-file deployment platforms |

The middleware (`middleware.ts`) is the key integration point. When `SUPERBASE2_ENABLED=true`, it intercepts requests to `/api/platform/projects`, `/api/platform/organizations/*/projects`, and `/api/platform/profile`, rewriting them to the SB2 API routes. The SB2 routes read from a shared `projects.json` manifest instead of returning the hardcoded single default project.

The existing Studio UI components — project switcher, command palette, project cards — all work unmodified because the SB2 API routes return the exact same response shapes that the Supabase Cloud API uses.

---

## Known limitations

- **Per-project containers need CLI to start.** Creating a project via the `/sb2` UI creates the database and manifest entry, but starting GoTrue/PostgREST/etc. requires running `./superbase2.sh up <name>` on the server. This is because starting Docker containers requires Docker socket access, which Studio doesn't have.
- **Kong API keys are per-project.** Each project gets its own consumers and API key credentials in Kong, generated during `rebuild-kong`. Projects are isolated at both the Kong routing layer (API key validation) and the JWT level (per-service JWT secrets).
- **No per-project Studio UI yet.** Studio shows all projects but doesn't scope its postgres-meta connection per project when you switch. This is a future improvement.
- **Untested at scale.** This has been tested with a handful of projects. Running 50+ projects on one instance is uncharted territory.

---

## Acknowledgments

SuperBase² is built entirely on top of [Supabase](https://supabase.com), which is open source under the [Apache 2.0 license](../../LICENSE). SuperBase² does not modify any Supabase source code — it layers additional functionality on top of the official self-hosted Docker deployment.

For Supabase documentation, setup guides, and the full platform feature set, see the **[main Supabase README](../../README.md)** and **[supabase.com/docs](https://supabase.com/docs)**.
