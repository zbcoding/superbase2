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

pnpm 10 + Turborepo monorepo. Requires Node >= 22.

## Structure

| Directory         | Purpose                                                      |
| ----------------- | ------------------------------------------------------------ |
| `apps/studio`     | Supabase Studio/Dashboard — Next.js (pages router), React 19 |
| `apps/docs`       | Documentation site                                           |
| `apps/www`        | Marketing website                                            |
| `packages/ui`     | Shared UI components (shadcn/ui based)                       |
| `packages/common` | Shared utilities and telemetry constants                     |
| `e2e/studio`      | Playwright E2E tests for Studio                              |

## Common Commands

```bash
pnpm install                          # install dependencies
pnpm dev:studio                       # run Studio dev server
pnpm test:studio                      # run Studio unit tests (vitest)
pnpm --prefix e2e/studio run e2e       # run Studio E2E tests (playwright)
pnpm build --filter=studio             # build Studio
pnpm lint --filter=studio              # lint Studio
pnpm typecheck                        # typecheck all packages
```

## Conventions

**UI** — import from `'ui'`, use `_Shadcn_` suffixed variants for form primitives. Check `packages/ui/index.tsx` before creating new primitives.

**Styling** — Tailwind only, semantic tokens (`bg-muted`, `text-foreground-light`), no hardcoded colors.

**Language** — Use U.S. English everywhere.

**Studio shortcuts** — when adding or changing repeated Studio UI actions, use the shared shortcut registry and primitives in `apps/studio/state/shortcuts/` and `apps/studio/components/ui/Shortcut*.tsx`. Prefer registered, discoverable shortcuts over one-off keyboard listeners; keep `G then ...` chords for navigation.

## Studio

Pages router. Co-locate sub-components with parent. Avoid barrel re-export files.

See studio-\* skills for detailed studio conventions.
