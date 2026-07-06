# SuperBase² — Modified Upstream Files

This document is the authoritative list of **original Supabase files that SuperBase² modifies in-place**, separate from the many new sb2-only files (which live under `apps/studio/pages/api/superbase2/`, `apps/studio/pages/sb2/`, `docker/superbase2/`, etc.).

**Why this matters:** Almost all sb2 code is in new files and merges cleanly when you pull upstream Supabase changes. The files below are the only ones where take-upstream during a merge would silently drop sb2 functionality. **Scrutinize each of these during every upstream merge.**

---

## Core integration points (Studio)

| File | What sb2 changes |
|---|---|
| `apps/studio/next.config.ts` | `SUPERBASE2_REWRITES` block — intercepts `/api/platform/**` and routes to sb2 handlers. Active routing implementation (replaces the older `middleware.ts` / `proxy.ts` approach which didn't work with Next.js 16 standalone builds). |
| `apps/studio/lib/constants/index.ts` | `SUPERBASE2_ENABLED` flag. |
| `apps/studio/lib/api/self-hosted/query.ts` | Self-hosted query helper. |
| `apps/studio/lib/api/self-hosted/util.ts` | Self-hosted util helper. |
| `apps/studio/components/interfaces/App/RouteValidationWrapper.tsx` | Bypass route validation when `SUPERBASE2_ENABLED`. |
| `apps/studio/components/layouts/Navigation/LayoutHeader/LayoutHeader.tsx` | Header gating around `SUPERBASE2_ENABLED`. |
| `apps/studio/data/fetchers.ts` | Stray `console.log('[SB2 debug] ...')` left in `handleError` from the removed GoTrue-auth debugging pass — no functional change, candidate for cleanup. |
| `apps/studio/pages/sign-in.tsx` | Self-hosted redirect target after Kong basic-auth: `/organizations` when `SUPERBASE2_ENABLED` (sb2 has no `default` ref) vs `/project/default` upstream. |
| `apps/studio/pages/project/[ref]/settings/general.tsx` | Self-hosted redirect uses the current `:ref` instead of hardcoded `default` (sb2 is multi-project). |
| `apps/studio/pages/project/[ref]/settings/log-drains.tsx` | Wraps the page in `PageLayout` during the entitlement-check loading state to avoid a layout reflow flash. |
| `apps/studio/package.json` | Adds `jose` dependency (used by sb2 JWT minting). |
| `apps/studio/Dockerfile` | sb2 build steps. |
| `apps/studio/turbo.jsonc` | sb2-aware turbo config. |
| `apps/studio/proxy.ts` | Currently NOT functionally modified — historical sb2 routing lived here, now in `next.config.ts`. Safe to take-upstream. |

## Per-project API route handlers

These are upstream platform routes that sb2 re-implements to be project-aware (read `:ref`, route to the correct per-project container instead of the hosted Supabase API):

**Auth (7 files):**
- `apps/studio/pages/api/platform/auth/[ref]/invite.ts`
- `apps/studio/pages/api/platform/auth/[ref]/magiclink.ts`
- `apps/studio/pages/api/platform/auth/[ref]/otp.ts`
- `apps/studio/pages/api/platform/auth/[ref]/recover.ts`
- `apps/studio/pages/api/platform/auth/[ref]/users/index.ts`
- `apps/studio/pages/api/platform/auth/[ref]/users/[id]/index.ts`
- `apps/studio/pages/api/platform/auth/[ref]/users/[id]/factors.ts`

**pg-meta (11 files):** — all use `guardSb2Project` (validates `:ref` against the SB2 manifest, 404s unknown refs before any DB access; on merge, keep the guard)
- `apps/studio/pages/api/platform/pg-meta/[ref]/column-privileges.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/extensions.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/foreign-tables.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/materialized-views.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/policies.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/publications.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/tables.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/triggers.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/types.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/views.ts`
- `apps/studio/pages/api/platform/pg-meta/[ref]/query/index.ts`

**Storage (10 files):**
- `apps/studio/pages/api/platform/storage/[ref]/buckets/index.ts`
- `apps/studio/pages/api/platform/storage/[ref]/buckets/[id]/index.ts`
- `apps/studio/pages/api/platform/storage/[ref]/buckets/[id]/empty.ts`
- `apps/studio/pages/api/platform/storage/[ref]/buckets/[id]/objects/index.ts`
- `apps/studio/pages/api/platform/storage/[ref]/buckets/[id]/objects/list.ts`
- `apps/studio/pages/api/platform/storage/[ref]/buckets/[id]/objects/download.ts`
- `apps/studio/pages/api/platform/storage/[ref]/buckets/[id]/objects/move.ts`
- `apps/studio/pages/api/platform/storage/[ref]/buckets/[id]/objects/public-url.ts`
- `apps/studio/pages/api/platform/storage/[ref]/buckets/[id]/objects/sign.ts`
- `apps/studio/pages/api/platform/storage/[ref]/buckets/[id]/objects/sign-multi.ts`

**Projects:**
- `apps/studio/pages/api/platform/projects/index.ts` — only a `_req` rename vs upstream; SB2 rewrites intercept before this is hit. Safe to take-upstream.

## Other modified files

| File | What sb2 changes |
|---|---|
| `docker/dev/docker-compose.dev.yml` | Dev stack adjustments. |
| `docker/docker-compose.coolify.yml` | Coolify deploy stack. `DB_ENC_KEY: ${DB_ENC_KEY}` (env-driven instead of the upstream `supabaserealtime` literal) so the Realtime tenant-encryption key is rotatable via a Coolify env var; plus Studio upgrade-endpoint wiring. |
| `docker/utils/generate-keys.sh` | Key generation for per-project secrets. |
| `README.md` | sb2 documentation at the top, upstream README below. |
| `.gitignore` | sb2-specific ignores. |
| `.github/workflows/update-js-libs.yml` | Workflow tweaks. |
| `.claude/CLAUDE.md` | sb2 development rules. |

---

## Files NOT in this list but flagged during merges (safe)

These show up in `git status` during merges because of historical sb2 commits, but contain no current sb2 functional code:

- `apps/studio/proxy.ts` — sb2's old routing logic lived here; moved to `next.config.ts`.
- `apps/studio/pages/api/platform/projects/index.ts` — only an unused-param rename.
- `apps/studio/lib/auth.tsx` — `fix(sb2): remove GoTrue auth, revert to Kong basic-auth only` (commit `97b12cd2d7`) reverted this to the plain upstream `alwaysLoggedIn={!IS_PLATFORM}`.
- `apps/studio/components/interfaces/SignIn/SignInForm.tsx` — same commit stripped the `SUPERBASE2_GOTRUE_AUTH` username/email login mode; no sb2 markers remain.
- `apps/studio/pages/_document.tsx` — same commit removed the `window.__SB2_RUNTIME__` injection.
- `packages/common/gotrue.ts` — same commit removed `superbase2GotrueAuthEnabled()`; the file is unmodified from upstream.
- `apps/studio/lib/superbase2/runtime-config.ts` — deleted entirely by commit `97b12cd2d7`; do not expect this file to exist.
- `docker/superbase2/seed-admin.sh` — orphaned by the same revert and since deleted; do not expect this file to exist. The dashboard's only auth today is Kong basic-auth + app-layer `SUPERBASE2_AUTH`, not a GoTrue admin seed.

---

## How to regenerate this list

After an upstream merge, run from the repo root:

```bash
MERGE_BASE=$(git merge-base HEAD upstream-snapshot)
git log --no-merges --invert-grep --grep="^Merge" --name-only --pretty=format: \
  "$MERGE_BASE..HEAD" \
  | sort -u \
  | while read f; do
      [ -z "$f" ] && continue
      git cat-file -e "$MERGE_BASE:$f" 2>/dev/null && echo "$f"
    done
```

The output is the set of upstream files that sb2-prefixed (non-merge) commits have modified. Cross-check this list and update accordingly.

---

## Verification during upstream merges

For each file in this document:

```bash
# Did the merged tree drop sb2 markers?
git show <pre-merge-branch>:<file> | grep -cE "SUPERBASE2|superbase2|sb2-"
git show <merged-branch>:<file> | grep -cE "SUPERBASE2|superbase2|sb2-"
# Counts should not decrease.
```

For files without textual sb2 markers (route handlers, helpers): diff against the pre-merge branch and verify intentional changes only.
