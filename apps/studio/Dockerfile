# To be run in the root of the turbo monorepo
# NOTE: It's highly recommended to use the new builder, Buildkit. https://docs.docker.com/build/buildkit/
## USAGE:
# Build:        docker build . -f apps/studio/Dockerfile --target production -t studio:latest
# Run:          docker run -p 3000:3000 supabase/studio
# Deploy:       docker push supabase/studio:latest
# Clean build:
#    docker builder prune
#    docker build . -f apps/studio/Dockerfile --target production -t studio:latest --no-cache

FROM node:22-slim AS base
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

# Fixes issues with Sentry CLI and SSL certificates during build
# TODO: Git is added because it's needed to build libpg, remove it once they publish a binary on the S3 bucket
RUN apt-get update -qq && \
  apt-get install -y --no-install-recommends \
  git \
  python3 \
  ca-certificates \
  build-essential && \
  rm -rf /var/lib/apt/lists/* && \
  update-ca-certificates

RUN npm install -g pnpm@10.24.0

WORKDIR /app

# Prune unneeded dependencies with turbo (from apps/ for example)
FROM base AS turbo
COPY . .

RUN pnpm dlx turbo@2.9.14 prune studio --docker

# Install dev dependencies (only if needed)
FROM base AS deps
COPY --from=turbo /app/out/json ./
COPY --from=turbo /app/out/pnpm-lock.yaml ./
COPY ./patches/ ./patches

# No need to clean cache because production uses standalone build
RUN pnpm install --no-frozen-lockfile

# dev contains dependencies and source code not compiled
FROM deps AS dev
COPY --from=turbo /app/out/full ./
ENTRYPOINT ["docker-entrypoint.sh"]
EXPOSE 8082
CMD ["pnpm", "dev:studio"]

# Compile Next.js
FROM dev AS builder

# ── SuperBase² build-time NEXT_PUBLIC_* vars ──
# Next.js inlines NEXT_PUBLIC_* into the client bundle at build time, so these
# must be set when the image is built — flipping them in Coolify env at runtime
# only affects server-side code paths. Coolify exposes build-time env via
# `--build-arg` or its UI's "Build args" panel.
#
# Note: The GoTrue-auth flag is deliberately NOT a NEXT_PUBLIC_* var. See the
# SUPERBASE2_GOTRUE_AUTH block below and lib/superbase2/auth.ts for why.
ARG NEXT_PUBLIC_SUPERBASE2_ENABLED=true
ARG NEXT_PUBLIC_GOTRUE_URL
ENV NEXT_PUBLIC_SUPERBASE2_ENABLED=${NEXT_PUBLIC_SUPERBASE2_ENABLED}
ENV NEXT_PUBLIC_GOTRUE_URL=${NEXT_PUBLIC_GOTRUE_URL}

# ── SuperBase² runtime-only vars (no NEXT_PUBLIC_ prefix) ──
# Intentionally NOT prefixed with NEXT_PUBLIC_ so the bundler can't inline
# them and dead-code-eliminate the auth branches. Server-side code in
# lib/superbase2/auth.ts reads process.env.SUPERBASE2_GOTRUE_AUTH at runtime;
# the client receives the value via window.__SB2_RUNTIME__ injected by
# _document.tsx. This means the flag can be flipped in the Coolify env
# panel and takes effect on container restart — no rebuild required.
#
# The ARG+ENV here exists so builds that want to bake in a default still
# can, but production deployments should set the runtime env var instead.
ARG SUPERBASE2_GOTRUE_AUTH=false
ENV SUPERBASE2_GOTRUE_AUTH=${SUPERBASE2_GOTRUE_AUTH}

RUN pnpm --filter studio exec next build

# Copy only compiled code and dependencies
FROM base AS production
COPY --from=builder /app/apps/studio/public ./apps/studio/public
COPY --from=builder /app/apps/studio/.next/standalone ./
COPY --from=builder /app/apps/studio/.next/static ./apps/studio/.next/static
EXPOSE 3000
ENTRYPOINT ["docker-entrypoint.sh"]
HEALTHCHECK --interval=5s --timeout=5s --retries=3 CMD node -e "fetch('http://localhost:3000/api/platform/profile').then((r) => {if (r.status !== 200) throw new Error(r.status)})"
CMD ["node", "apps/studio/server.js"]
