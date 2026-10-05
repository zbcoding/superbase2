AGENTS.md for Superbase2 development

# Project Documentation

## Documentation Location

All project documentation files related to sb2 should be created in the `../superbase2/docker/superbase2/docs.local` directory.

# General

## Documenting tools
Maintain docs.local/papercuts.md, a global log shared by all sessions of anything that slowed down development. When you lose time to one mid-session, append date · symptom · fix · project. Check this file first when tooling fails mysteriously.


# SuperBase² specifics

## Layout
- sb2 code lives in new files: `docker/superbase2/` (CLI `superbase2.sh`, Node agent `agent/agent.js`, per-project template `templates/docker-compose.project.yml.tpl`), `apps/studio/lib/superbase2/`, `apps/studio/pages/api/superbase2/`, `apps/studio/pages/sb2/`.
- Upstream Supabase files that sb2 edits in place are listed in `SB2_MODIFIED_FILES.md` (repo root). Update that list whenever you edit an upstream file.
- Deploy layouts: `docker/docker-compose.coolify.yml` (Coolify, flattened), `docker/docker-compose.superbase2.yml` (overlay on upstream `docker/docker-compose.yml`), `docker/superbase2/docker-compose.standalone.yml`. A compose change usually belongs in all three.
- The agent image is `node:22-alpine` with BusyBox tools (no `flock -w`, no `bun`). `superbase2.sh` must run there and on a plain host.

## Git and deploy
- Branch `development`, rebased on `upstream/master` (supabase/supabase). Don't push: the user pushes, force-pushing after rebases.
- The test server's Coolify app deploys `development` automatically on push. Server facts (app UUID, secrets present, projects, limits) are in `docs.local/coolify-server.md`; read that before logging in to the server.

## Verification
- Verify per-project behaviour on a local Coolify-layout stack (`docker compose -p <name> -f docker/docker-compose.coolify.yml`), not only with `bash -n` / `node --check`. Tear it down afterwards (containers, `<name>_*` volumes, `supabase-<project>_*` volumes and networks).
- Studio: `pnpm exec tsc --noEmit` in `apps/studio`.
