# ⚡² SuperBase²

**Multi-project layer for self-hosted [Supabase](https://github.com/supabase/supabase).**

Run multiple database projects on a single Supabase deployment — one PostgreSQL instance, one API gateway, one dashboard — with isolated auth, storage, and APIs per project.

> **Status: Experimental / Hobby-use**
> SuperBase² is new and untested in production. It works by layering on top of stock Supabase with minimal modifications to upstream files (all tracked in [`SB2_MODIFIED_FILES.md`](./SB2_MODIFIED_FILES.md)). This means it inherits Supabase's stability for the core infrastructure, but the multi-project orchestration itself hasn't been battle-tested yet. Great for hobby projects, side projects, and development environments. Use in production at your own discretion.

---

<img width="1382" height="1889" alt="image" src="https://github.com/user-attachments/assets/4026c8c3-660d-4aa0-a4c2-88c11b728482" />


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

- **Minimal modifications to existing Supabase files.** The bulk of SuperBase² is new files in new directories. A small set of upstream Studio files are modified in-place to wire in the sb2 routing, auth, and per-project route handlers — they're all listed in [`SB2_MODIFIED_FILES.md`](./SB2_MODIFIED_FILES.md). The core integration point is `apps/studio/next.config.ts`, which adds the `SUPERBASE2_REWRITES` block that intercepts `/api/platform/**` and routes to the sb2 handlers.
- **`git pull` just works for nearly everything.** Because most upstream files are untouched, pulling new Supabase releases conflicts only on the small set listed in [`SB2_MODIFIED_FILES.md`](./SB2_MODIFIED_FILES.md). When resolving an upstream merge, scrutinize each file in that document — everything else can usually take-upstream safely.
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
6. Coolify shows all the environment variables from Supabase's `.env.example` in its GUI. Generate secrets locally and fill them in:
   ```bash
   cd docker && sh utils/generate-keys.sh
   ```
   Update at minimum:
   - `SUPABASE_PUBLIC_URL` — your Coolify domain for Kong (e.g. `https://api.supabase.example.com`)
   - `API_EXTERNAL_URL` — exact same domain URL as above
   - `POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`
   - `DASHBOARD_USERNAME`, `DASHBOARD_PASSWORD`

   The SuperBase² variables (`SUPERBASE2_ENABLED`, `SUPERBASE2_MANIFEST`, etc.) are hardcoded in the compose file — you don't need to configure them.

7. **Configure Domains in Coolify:** Coolify will auto-generate domain inputs for every single service. **You must delete most of these to keep your database secure.**
   - `studio` → give this a domain (e.g. `https://supabase.example.com`) to access your dashboard.
   - `kong` → give this a domain (e.g. `https://api.supabase.example.com`). This **must match** your `SUPABASE_PUBLIC_URL`.
   - **Delete the domains entirely** for every other service (`auth`, `rest`, `storage`, `meta`, `realtime`, `vector`, `imgproxy`, `functions`, `analytics`, `supavisor`, `superbase2-init`). These are internal microservices that must sit securely behind the `kong` API Gateway and not be publicly exposed.

8. Deploy — Coolify will build the Studio from your fork's source on first deploy (10–30 min). Subsequent deploys are fast due to Docker layer caching.

Once running, open `/sb2` in your browser to create projects. After creating a project in the UI, SSH into the server to start its containers:

```bash
cd docker/superbase2
./superbase2.sh up myproject
```

Or skip the UI and do everything from SSH:

```bash
cd docker/superbase2
./superbase2.sh setup myproject   # create + start in one step
```

**Upgrading on Coolify:** When Supabase releases updates, merge upstream into your fork. The upstream `docker-compose.yml` will update cleanly (SuperBase² never modifies it). Then regenerate the merged Coolify file — the simplest way is to run the merge locally:

```bash
git pull upstream master
# Re-merge: copy upstream docker-compose.yml, apply the superbase2 overlay changes
# The overlay (docker-compose.superbase2.yml) is the source of truth for SB2 changes
```

**Why a merged file instead of the overlay:** Coolify does not support Docker Compose's multi-file `-f` flag. The `docker-compose.coolify.yml` is a pre-merged copy of `docker-compose.yml` + `docker-compose.superbase2.yml`. The overlay file remains the canonical source for SuperBase² changes.

**Why base directory is `/docker` and not `/docker/superbase2`:** Coolify reads `.env.example` from the base directory to populate its env var GUI. By pointing at `/docker`, Coolify reads Supabase's upstream `.env.example` directly — so when Supabase adds new variables, they automatically appear in your Coolify GUI without any SuperBase² changes.

**Why per-project containers need SSH:** Starting Docker containers requires Docker socket access, which the Studio web app doesn't have. The `/sb2` UI creates the database and secrets; SSH handles the container lifecycle. This is standard for Coolify — Coolify's terminal or an SSH connection both work.

---

## Usage

### Creating projects

**Quickest way (SSH only):**

```bash
cd docker/superbase2
./superbase2.sh setup myproject   # creates DB, secrets, Kong routes, starts containers
```

**From the browser + SSH:**

1. Navigate to `/sb2`, type a project name, click Create (creates DB + secrets)
2. SSH into the server and start the containers:
   ```bash
   cd docker/superbase2
   ./superbase2.sh up myproject
   ```

**Two-step CLI (if you need to customize between create and start):**

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

SuperBase² adds these new files and directories:

| File | Purpose |
|------|---------|
| `apps/studio/lib/superbase2/` | Project manifest reader/writer, DB provisioning, response shape helpers |
| `apps/studio/pages/api/superbase2/` | API routes for project CRUD, org listing, upgrade checks |
| `apps/studio/pages/sb2/` | SB2 dashboard UI (amber-themed, distinct from Supabase green) |
| `docker/superbase2/superbase2.sh` | CLI for creating/managing projects and per-project containers |
| `docker/superbase2/templates/` | Docker Compose and Kong config templates for per-project services |
| `docker/docker-compose.superbase2.yml` | Overlay that enables SB2 on the Studio container |
| `docker/docker-compose.coolify.yml` | Pre-merged single compose file for Coolify (base + overlay combined) |
| `docker/superbase2/docker-compose.standalone.yml` | All-in-one merged file for standalone deployment without the upstream Supabase stack |

It also modifies a small number of upstream Studio files — see [`SB2_MODIFIED_FILES.md`](./SB2_MODIFIED_FILES.md) for the authoritative list.

The key integration point is `apps/studio/next.config.ts`. When `SUPERBASE2_ENABLED` is on, the `SUPERBASE2_REWRITES` block intercepts requests to `/api/platform/projects`, `/api/platform/organizations/*/projects`, `/api/platform/profile`, plus per-project `/api/platform/{auth,storage,pg-meta}/[ref]/**` routes, rewriting them to the SB2 API routes. The SB2 routes read from a shared `projects.json` manifest and per-project containers instead of returning the hardcoded single default project.

The existing Studio UI components — project switcher, command palette, project cards — all work unmodified because the SB2 API routes return the exact same response shapes that the Supabase Cloud API uses.

---

## Known limitations

- **Per-project containers need SSH to start.** Creating a project via the `/sb2` UI creates the database and manifest entry, but starting GoTrue/PostgREST/etc. requires running `./superbase2.sh up <name>` on the server (or `./superbase2.sh setup <name>` to do both from SSH). This is because Docker socket access is needed, which Studio doesn't have. On Coolify, use the built-in terminal or SSH.
- **Kong API keys are per-project.** Each project gets its own consumers and API key credentials in Kong, generated during `rebuild-kong`. Projects are isolated at both the Kong routing layer (API key validation) and the JWT level (per-service JWT secrets).
- **No per-project Studio UI yet.** Studio shows all projects but doesn't scope its postgres-meta connection per project when you switch. This is a future improvement.
- **Untested at scale.** This has been tested with a handful of projects. Running 50+ projects on one instance is uncharted territory.

---

## Acknowledgments

SuperBase² is built entirely on top of [Supabase](https://supabase.com), which is open source under the [Apache 2.0 license](LICENSE). SuperBase² does not modify any Supabase source code — it layers additional functionality on top of the official self-hosted Docker deployment.

For Supabase documentation, setup guides, and the full platform feature set, see **[supabase.com/docs](https://supabase.com/docs)**.

---

<!-- ⬇️ Original Supabase README (unmodified) ⬇️ -->

<p align="center">
<img src="https://user-images.githubusercontent.com/8291514/213727234-cda046d6-28c6-491a-b284-b86c5cede25d.png#gh-light-mode-only">
<img src="https://user-images.githubusercontent.com/8291514/213727225-56186826-bee8-43b5-9b15-86e839d89393.png#gh-dark-mode-only">
</p>

# Supabase

[Supabase](https://supabase.com) is the Postgres development platform. We're building the features of Firebase using enterprise-grade open source tools.

- [x] Hosted Postgres Database. [Docs](https://supabase.com/docs/guides/database)
- [x] Authentication and Authorization. [Docs](https://supabase.com/docs/guides/auth)
- [x] Auto-generated APIs.
  - [x] REST. [Docs](https://supabase.com/docs/guides/api)
  - [x] GraphQL. [Docs](https://supabase.com/docs/guides/graphql)
  - [x] Realtime subscriptions. [Docs](https://supabase.com/docs/guides/realtime)
- [x] Functions.
  - [x] Database Functions. [Docs](https://supabase.com/docs/guides/database/functions)
  - [x] Edge Functions [Docs](https://supabase.com/docs/guides/functions)
- [x] File Storage. [Docs](https://supabase.com/docs/guides/storage)
- [x] AI + Vector/Embeddings Toolkit. [Docs](https://supabase.com/docs/guides/ai)
- [x] Dashboard

![Supabase Dashboard](https://raw.githubusercontent.com/supabase/supabase/master/apps/www/public/images/github/supabase-dashboard.png)

Watch "releases" of this repo to get notified of major updates.

<kbd><img src="https://raw.githubusercontent.com/supabase/supabase/d5f7f413ab356dc1a92075cb3cee4e40a957d5b1/web/static/watch-repo.gif" alt="Watch this repo"/></kbd>

## Documentation

For full documentation, visit [supabase.com/docs](https://supabase.com/docs)

To see how to Contribute, visit [Getting Started](./DEVELOPERS.md)

## Community & Support

- [Community Forum](https://github.com/supabase/supabase/discussions). Best for: help with building, discussion about database best practices.
- [GitHub Issues](https://github.com/supabase/supabase/issues). Best for: bugs and errors you encounter using Supabase.
- [Email Support](https://supabase.com/docs/support#business-support). Best for: problems with your database or infrastructure.
- [Discord](https://discord.supabase.com). Best for: sharing your applications and hanging out with the community.

## How it works

Supabase is a combination of open source tools. We’re building the features of Firebase using enterprise-grade, open source products. If the tools and communities exist, with an MIT, Apache 2, or equivalent open license, we will use and support that tool. If the tool doesn't exist, we build and open source it ourselves. Supabase is not a 1-to-1 mapping of Firebase. Our aim is to give developers a Firebase-like developer experience using open source tools.

**Architecture**

Supabase is a [hosted platform](https://supabase.com/dashboard). You can sign up and start using Supabase without installing anything.
You can also [self-host](https://supabase.com/docs/guides/hosting/overview) and [develop locally](https://supabase.com/docs/guides/local-development).

![Architecture](apps/docs/public/img/supabase-architecture.svg)

- [Postgres](https://www.postgresql.org/) is an object-relational database system with over 30 years of active development that has earned it a strong reputation for reliability, feature robustness, and performance.
- [Realtime](https://github.com/supabase/realtime) is an Elixir server that allows you to listen to PostgreSQL inserts, updates, and deletes using websockets. Realtime polls Postgres' built-in replication functionality for database changes, converts changes to JSON, then broadcasts the JSON over websockets to authorized clients.
- [PostgREST](http://postgrest.org/) is a web server that turns your PostgreSQL database directly into a RESTful API.
- [GoTrue](https://github.com/supabase/gotrue) is a JWT-based authentication API that simplifies user sign-ups, logins, and session management in your applications.
- [Storage](https://github.com/supabase/storage-api) a RESTful API for managing files in S3, with Postgres handling permissions.
- [pg_graphql](http://github.com/supabase/pg_graphql/) a PostgreSQL extension that exposes a GraphQL API.
- [postgres-meta](https://github.com/supabase/postgres-meta) is a RESTful API for managing your Postgres, allowing you to fetch tables, add roles, and run queries, etc.
- [Kong](https://github.com/Kong/kong) is a cloud-native API gateway.

#### Client libraries

Our approach for client libraries is modular. Each sub-library is a standalone implementation for a single external system. This is one of the ways we support existing tools.

<table style="table-layout:fixed; white-space: nowrap;">
  <tr>
    <th>Language</th>
    <th>Client</th>
    <th colspan="5">Feature-Clients (bundled in Supabase client)</th>
  </tr>
  <!-- notranslate -->
  <tr>
    <th></th>
    <th>Supabase</th>
    <th><a href="https://github.com/postgrest/postgrest" target="_blank" rel="noopener noreferrer">PostgREST</a></th>
    <th><a href="https://github.com/supabase/gotrue" target="_blank" rel="noopener noreferrer">GoTrue</a></th>
    <th><a href="https://github.com/supabase/realtime" target="_blank" rel="noopener noreferrer">Realtime</a></th>
    <th><a href="https://github.com/supabase/storage-api" target="_blank" rel="noopener noreferrer">Storage</a></th>
    <th>Functions</th>
  </tr>
  <!-- TEMPLATE FOR NEW ROW -->
  <!-- START ROW
  <tr>
    <td>lang</td>
    <td><a href="https://github.com/supabase-community/supabase-lang" target="_blank" rel="noopener noreferrer">supabase-lang</a></td>
    <td><a href="https://github.com/supabase-community/postgrest-lang" target="_blank" rel="noopener noreferrer">postgrest-lang</a></td>
    <td><a href="https://github.com/supabase-community/gotrue-lang" target="_blank" rel="noopener noreferrer">gotrue-lang</a></td>
    <td><a href="https://github.com/supabase-community/realtime-lang" target="_blank" rel="noopener noreferrer">realtime-lang</a></td>
    <td><a href="https://github.com/supabase-community/storage-lang" target="_blank" rel="noopener noreferrer">storage-lang</a></td>
  </tr>
  END ROW -->
  <!-- /notranslate -->
  <th colspan="7">⚡️ Official ⚡️</th>
  <!-- notranslate -->
  <tr>
    <td>JavaScript (TypeScript)</td>
    <td><a href="https://github.com/supabase/supabase-js" target="_blank" rel="noopener noreferrer">supabase-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/postgrest-js" target="_blank" rel="noopener noreferrer">postgrest-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/auth-js" target="_blank" rel="noopener noreferrer">auth-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/realtime-js" target="_blank" rel="noopener noreferrer">realtime-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/storage-js" target="_blank" rel="noopener noreferrer">storage-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/functions-js" target="_blank" rel="noopener noreferrer">functions-js</a></td>
  </tr>
    <tr>
    <td>Flutter</td>
    <td><a href="https://github.com/supabase/supabase-flutter" target="_blank" rel="noopener noreferrer">supabase-flutter</a></td>
    <td><a href="https://github.com/supabase/postgrest-dart" target="_blank" rel="noopener noreferrer">postgrest-dart</a></td>
    <td><a href="https://github.com/supabase/gotrue-dart" target="_blank" rel="noopener noreferrer">gotrue-dart</a></td>
    <td><a href="https://github.com/supabase/realtime-dart" target="_blank" rel="noopener noreferrer">realtime-dart</a></td>
    <td><a href="https://github.com/supabase/storage-dart" target="_blank" rel="noopener noreferrer">storage-dart</a></td>
    <td><a href="https://github.com/supabase/functions-dart" target="_blank" rel="noopener noreferrer">functions-dart</a></td>
  </tr>
  <tr>
    <td>Swift</td>
    <td><a href="https://github.com/supabase/supabase-swift" target="_blank" rel="noopener noreferrer">supabase-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/PostgREST" target="_blank" rel="noopener noreferrer">postgrest-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/Auth" target="_blank" rel="noopener noreferrer">auth-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/Realtime" target="_blank" rel="noopener noreferrer">realtime-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/Storage" target="_blank" rel="noopener noreferrer">storage-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/Functions" target="_blank" rel="noopener noreferrer">functions-swift</a></td>
  </tr>
  <tr>
    <td>Python</td>
    <td><a href="https://github.com/supabase/supabase-py" target="_blank" rel="noopener noreferrer">supabase-py</a></td>
    <td><a href="https://github.com/supabase/postgrest-py" target="_blank" rel="noopener noreferrer">postgrest-py</a></td>
    <td><a href="https://github.com/supabase/gotrue-py" target="_blank" rel="noopener noreferrer">gotrue-py</a></td>
    <td><a href="https://github.com/supabase/realtime-py" target="_blank" rel="noopener noreferrer">realtime-py</a></td>
    <td><a href="https://github.com/supabase/storage-py" target="_blank" rel="noopener noreferrer">storage-py</a></td>
    <td><a href="https://github.com/supabase/functions-py" target="_blank" rel="noopener noreferrer">functions-py</a></td>
  </tr>
  <!-- /notranslate -->
  <th colspan="7">💚 Community 💚</th>
  <!-- notranslate -->
  <tr>
    <td>C#</td>
    <td><a href="https://github.com/supabase-community/supabase-csharp" target="_blank" rel="noopener noreferrer">supabase-csharp</a></td>
    <td><a href="https://github.com/supabase-community/postgrest-csharp" target="_blank" rel="noopener noreferrer">postgrest-csharp</a></td>
    <td><a href="https://github.com/supabase-community/gotrue-csharp" target="_blank" rel="noopener noreferrer">gotrue-csharp</a></td>
    <td><a href="https://github.com/supabase-community/realtime-csharp" target="_blank" rel="noopener noreferrer">realtime-csharp</a></td>
    <td><a href="https://github.com/supabase-community/storage-csharp" target="_blank" rel="noopener noreferrer">storage-csharp</a></td>
    <td><a href="https://github.com/supabase-community/functions-csharp" target="_blank" rel="noopener noreferrer">functions-csharp</a></td>
  </tr>
  <tr>
    <td>Go</td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/postgrest-go" target="_blank" rel="noopener noreferrer">postgrest-go</a></td>
    <td><a href="https://github.com/supabase-community/gotrue-go" target="_blank" rel="noopener noreferrer">gotrue-go</a></td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/storage-go" target="_blank" rel="noopener noreferrer">storage-go</a></td>
    <td><a href="https://github.com/supabase-community/functions-go" target="_blank" rel="noopener noreferrer">functions-go</a></td>
  </tr>
  <tr>
    <td>Java</td>
    <td>-</td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/gotrue-java" target="_blank" rel="noopener noreferrer">gotrue-java</a></td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/storage-java" target="_blank" rel="noopener noreferrer">storage-java</a></td>
    <td>-</td>
  </tr>
  <tr>
    <td>Kotlin</td>
    <td><a href="https://github.com/supabase-community/supabase-kt" target="_blank" rel="noopener noreferrer">supabase-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Postgrest" target="_blank" rel="noopener noreferrer">postgrest-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Auth" target="_blank" rel="noopener noreferrer">auth-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Realtime" target="_blank" rel="noopener noreferrer">realtime-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Storage" target="_blank" rel="noopener noreferrer">storage-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Functions" target="_blank" rel="noopener noreferrer">functions-kt</a></td>
  </tr>
  <tr>
    <td>Ruby</td>
    <td><a href="https://github.com/supabase-community/supabase-rb" target="_blank" rel="noopener noreferrer">supabase-rb</a></td>
    <td><a href="https://github.com/supabase-community/postgrest-rb" target="_blank" rel="noopener noreferrer">postgrest-rb</a></td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
  </tr>
  <tr>
    <td>Rust</td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/postgrest-rs" target="_blank" rel="noopener noreferrer">postgrest-rs</a></td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
  </tr>
  <tr>
    <td>Godot Engine (GDScript)</td>
    <td><a href="https://github.com/supabase-community/godot-engine.supabase" target="_blank" rel="noopener noreferrer">supabase-gdscript</a></td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
  </tr>
  <!-- /notranslate -->
</table>

<!--- Remove this list if you're translating to another language, it's hard to keep updated across multiple files-->
<!--- Keep only the link to the list of translation files-->

## Badges

![Made with Supabase](./apps/www/public/badge-made-with-supabase.svg)

```md
[![Made with Supabase](https://supabase.com/badge-made-with-supabase.svg)](https://supabase.com)
```

```html
<a href="https://supabase.com">
  <img
    width="168"
    height="30"
    src="https://supabase.com/badge-made-with-supabase.svg"
    alt="Made with Supabase"
  />
</a>
```

![Made with Supabase (dark)](./apps/www/public/badge-made-with-supabase-dark.svg)

```md
[![Made with Supabase](https://supabase.com/badge-made-with-supabase-dark.svg)](https://supabase.com)
```

```html
<a href="https://supabase.com">
  <img
    width="168"
    height="30"
    src="https://supabase.com/badge-made-with-supabase-dark.svg"
    alt="Made with Supabase"
  />
</a>
```

## Translations

- [Arabic | العربية](/i18n/README.ar.md)
- [Albanian / Shqip](/i18n/README.sq.md)
- [Bangla / বাংলা](/i18n/README.bn.md)
- [Bulgarian / Български](/i18n/README.bg.md)
- [Catalan / Català](/i18n/README.ca.md)
- [Croatian / Hrvatski](/i18n/README.hr.md)
- [Czech / čeština](/i18n/README.cs.md)
- [Danish / Dansk](/i18n/README.da.md)
- [Dutch / Nederlands](/i18n/README.nl.md)
- [English](https://github.com/supabase/supabase)
- [Estonian / eesti keel](/i18n/README.et.md)
- [Finnish / Suomalainen](/i18n/README.fi.md)
- [French / Français](/i18n/README.fr.md)
- [German / Deutsch](/i18n/README.de.md)
- [Greek / Ελληνικά](/i18n/README.el.md)
- [Gujarati / ગુજરાતી](/i18n/README.gu.md)
- [Hebrew / עברית](/i18n/README.he.md)
- [Hindi / हिंदी](/i18n/README.hi.md)
- [Hungarian / Magyar](/i18n/README.hu.md)
- [Nepali / नेपाली](/i18n/README.ne.md)
- [Indonesian / Bahasa Indonesia](/i18n/README.id.md)
- [Italiano / Italian](/i18n/README.it.md)
- [Japanese / 日本語](/i18n/README.jp.md)
- [Korean / 한국어](/i18n/README.ko.md)
- [Lithuanian / lietuvių](/i18n/README.lt.md)
- [Latvian / latviski](/i18n/README.lv.md)
- [Malay / Bahasa Malaysia](/i18n/README.ms.md)
- [Norwegian (Bokmål) / Norsk (Bokmål)](/i18n/README.nb.md)
- [Persian / فارسی](/i18n/README.fa.md)
- [Polish / Polski](/i18n/README.pl.md)
- [Portuguese / Português](/i18n/README.pt.md)
- [Portuguese (Brazilian) / Português Brasileiro](/i18n/README.pt-br.md)
- [Romanian / Română](/i18n/README.ro.md)
- [Russian / Pусский](/i18n/README.ru.md)
- [Serbian / Srpski](/i18n/README.sr.md)
- [Sinhala / සිංහල](/i18n/README.si.md)
- [Slovak / slovenský](/i18n/README.sk.md)
- [Slovenian / Slovenščina](/i18n/README.sl.md)
- [Spanish / Español](/i18n/README.es.md)
- [Simplified Chinese / 简体中文](/i18n/README.zh-cn.md)
- [Swedish / Svenska](/i18n/README.sv.md)
- [Thai / ไทย](/i18n/README.th.md)
- [Traditional Chinese / 繁體中文](/i18n/README.zh-tw.md)
- [Turkish / Türkçe](/i18n/README.tr.md)
- [Ukrainian / Українська](/i18n/README.uk.md)
- [Vietnamese / Tiếng Việt](/i18n/README.vi-vn.md)
- [List of translations](/i18n/languages.md) <!--- Keep only this -->
