FROM node:22-alpine

RUN apk add --no-cache \
    docker-cli \
    docker-cli-compose \
    bash \
    jq \
    openssl \
    coreutils \
    grep \
    sed \
    curl

WORKDIR /app
# Build context is ./superbase2 (the parent dir), so paths are relative to that.
COPY agent/agent.js /app/agent.js
# Bake the CLI + templates into the image so the agent works even when the
# host-side bind mount isn't available (e.g. Coolify's ephemeral artifacts dir).
COPY superbase2.sh /workspace/superbase2/superbase2.sh
COPY templates /workspace/superbase2/templates
# Bake init configs (kong, vector, pooler, db-init SQL, functions/main) so the
# init services can `cp` them into shared volumes instead of carrying them as
# inline base64 blobs in docker-compose.coolify.yml. This keeps the compose
# file under Linux ARG_MAX when Coolify writes it via `docker exec ... bash -c`.
COPY agent/configs /opt/sb2-configs
RUN chmod +x /workspace/superbase2/superbase2.sh /opt/sb2-configs/kong/kong-entrypoint.sh

ENV NODE_ENV=production \
    SB2_AGENT_PORT=8088 \
    SB2_DOCKER_DIR=/workspace

EXPOSE 8088

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD curl -fsS http://localhost:8088/health || exit 1

CMD ["node", "/app/agent.js"]
