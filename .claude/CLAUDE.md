# CLAUDE.md — 12-rule template

These rules apply to every task in this project unless explicitly overridden.
Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.

## Rule 1 — Think Before Coding
State assumptions explicitly. If uncertain, ask rather than guess.
Present multiple interpretations when ambiguity exists.
Push back when a simpler approach exists.
Stop when confused. Name what's unclear.

## Rule 2 — Simplicity First
Minimum code that solves the problem. Nothing speculative.
No features beyond what was asked. No abstractions for single-use code.
Test: would a senior engineer say this is overcomplicated? If yes, simplify.

## Rule 3 — Surgical Changes
Touch only what you must. Clean up only your own mess.
Don't "improve" adjacent code, comments, or formatting.
Don't refactor what isn't broken. Match existing style.

## Rule 4 — Goal-Driven Execution
Define success criteria. Loop until verified.
Don't follow steps. Define success and iterate.
Strong success criteria let you loop independently.

## Rule 5 — Use the model only for judgment calls
Use me for: classification, drafting, summarization, extraction.
Do NOT use me for: routing, retries, deterministic transforms.
If code can answer, code answers.

## Rule 6 — Token budgets are not advisory
Per-task: 4,000 tokens. Per-session: 30,000 tokens.
If approaching budget, summarize and start fresh.
Surface the breach. Do not silently overrun.

## Rule 7 — Surface conflicts, don't average them
If two patterns contradict, pick one (more recent / more tested).
Explain why. Flag the other for cleanup.
Don't blend conflicting patterns.

## Rule 8 — Read before you write
Before adding code, read exports, immediate callers, shared utilities.
"Looks orthogonal" is dangerous. If unsure why code is structured a way, ask.

## Rule 9 — Tests verify intent, not just behavior
Tests must encode WHY behavior matters, not just WHAT it does.
A test that can't fail when business logic changes is wrong.

## Rule 10 — Checkpoint after every significant step
Summarize what was done, what's verified, what's left.
Don't continue from a state you can't describe back.
If you lose track, stop and restate.

## Rule 11 — Match the codebase's conventions, even if you disagree
Conformance > taste inside the codebase.
If you genuinely think a convention is harmful, surface it. Don't fork silently.

## Rule 12 — Fail loud
"Completed" is wrong if anything was skipped silently.
"Tests pass" is wrong if any were skipped.
Default to surfacing uncertainty, not hiding it.



# SuperBase² on top of Supabase

SuperBase² is built on top of the upstream `supabase/supabase` repo. The design goal is that nearly every sb2 feature lives in **new files** (under `apps/studio/pages/api/superbase2/`, `apps/studio/pages/sb2/`, `apps/studio/lib/superbase2/`, `docker/superbase2/`, etc.) so that `git pull` from upstream merges without hard conflicts.

Where new-file isolation isn't possible, the in-place modifications to upstream files are tracked in [`SB2_MODIFIED_FILES.md`](../SB2_MODIFIED_FILES.md) at the repo root. **Before adding sb2 logic to any existing upstream file, prefer extracting it into a new file under an sb2 namespace.** When you must edit an upstream file, update `SB2_MODIFIED_FILES.md` in the same change so future merges know to scrutinize it.

During upstream merges: files outside `SB2_MODIFIED_FILES.md` can almost always take-upstream safely. Files inside it require a real 3-way merge.


# Supabase Monorepo

pnpm 11 + Turborepo monorepo. Requires Node >= 22.13.

## Structure

| Directory                | Purpose                                                                     |
| ------------------------ | --------------------------------------------------------------------------- |
| `apps/studio`            | Supabase Studio/Dashboard — has its own `apps/studio/CLAUDE.md` (see below) |
| `apps/docs`              | Documentation site — Next.js app router, MDX (port 3001)                    |
| `apps/www`               | Marketing website — Next.js, app + pages (port 3000)                        |
| `apps/design-system`     | Component demos — source of truth for Studio UI patterns (port 3003)        |
| `apps/ui-library`        | shadcn-style registry site for Supabase UI blocks (port 3004)               |
| `apps/lite-studio`       | Lightweight Studio — different stack: React Router 7 + Vite + Tailwind v4   |
| `packages/ui`            | Shared UI components (shadcn/ui based) — `import { Button } from 'ui'`      |
| `packages/ui-patterns`   | Composite components — subpath imports, e.g. `ui-patterns/AssistantChat`    |
| `packages/common`        | Shared utils, telemetry constants, feature flags                            |
| `packages/api-types`     | Generated platform Management API types                                     |
| `packages/pg-meta`       | SQL builders for Postgres introspection (`SafeSqlFragment`)                 |
| `packages/shared-data`   | Static data: pricing, plans, regions, error codes                           |
| `e2e/studio`, `e2e/docs` | Playwright E2E tests                                                        |
| `supabase/`              | Local Supabase project: edge functions, migrations, config.toml             |

## Common Commands

```bash
pnpm dev:studio              # run Studio dev server → http://localhost:8082
pnpm dev:docs                # run docs dev server
pnpm dev:www                 # run www dev server
pnpm test:studio             # Studio unit tests (vitest)
pnpm e2e                     # Studio E2E tests (playwright)
pnpm build --filter=studio   # build Studio
pnpm lint --filter=studio    # lint Studio
pnpm typecheck               # typecheck all packages
pnpm format                  # Prettier write (check: pnpm test:prettier)
pnpm generate:types          # local DB types → supabase/functions/common/database-types.ts
pnpm api:codegen             # platform Management API types → packages/api-types
```

## CI

Every PR must pass typecheck + lint (one workflow), Prettier, and a typos check. Other checks are path-filtered: Studio unit tests/build and the lint ratchet (ESLint warning count must not increase) run on `apps/studio/**` changes; app-specific test suites run on their own paths.

Never hand-edit generated files: `packages/api-types/types/**`, `**/routeTree.gen.ts`, `**/__generated__/**`, `apps/docs/features/docs/generated/**`, `apps/www/.generated/**`, `supabase/functions/common/database-types.ts`.

## Conventions

**UI** — import from `'ui'`; primitives are shadcn/ui-based and exported unsuffixed (`Input`, `Select`, `Form`, …). Use `Button` — the in-house component and the standard everywhere (a raw shadcn `Button_Shadcn_` also exists but is rarely the right choice). Check `packages/ui/index.tsx` before creating new primitives. Higher-level patterns live in `packages/ui-patterns`.

**Styling** — Tailwind only, semantic tokens (`bg-muted`, `text-foreground-light`), no hardcoded colors.

**Exports** — named exports only; default exports are allowed only where a framework requires them (`pages/**`, `app/**`, config files — the eslint preset has the exact carve-out list). Lint-enforced across all apps via `eslint-config-supabase` (severity `warn` everywhere; hard-enforced in Studio by the lint ratchet).

**Language** — Use U.S. English everywhere.

## Skills

The skills in `.claude/skills/` are the source of truth for conventions — load the relevant ones before working, don't guess:

- `copywriting` — any user-facing text, anywhere in the monorepo
- `docs-content` — anything under `apps/docs`
- `telemetry-standards` — PostHog events, `packages/common/telemetry-constants.ts`
- `dev-toolbar-review` — `packages/dev-tools`, `packages/common/posthog-client.ts`, `packages/common/feature-flags.tsx`
- `safe-sql-execution` — any code that builds or executes SQL against user databases
- `react-hook-form` — writing or modifying any form code, anywhere in the monorepo
- `vitest` / `vercel-composition-patterns` — generic unit-testing and React composition references

## Studio

Before working on anything in `apps/studio`, read `apps/studio/CLAUDE.md` if it isn't already in context — it maps Studio tasks to required skills and covers the TanStack Start migration rules.
