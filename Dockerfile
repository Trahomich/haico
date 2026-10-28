# syntax=docker/dockerfile:1

########## Stage 1: build (compile TS + native modules) ##########
FROM node:22-alpine AS builder

# python3/make/g++ needed to build native addons (better-sqlite3, node-pty)
RUN apk add --no-cache python3 make g++

WORKDIR /app

# Install dependencies first to leverage Docker layer cache
COPY package.json package-lock.json ./
RUN npm ci

# Build the application
COPY . .
RUN npm run build
# Ensure vendor assets in public/ (postinstall may have run before public/ was copied)
RUN npm run postinstall

########## Stage 2: prune to production dependencies ##########
FROM builder AS prod-deps
RUN npm prune --omit=dev

########## Stage 3: runtime ##########
FROM node:22-alpine AS runtime

# git   — HAICO git integration + agent tooling
# curl  — omp installer (+ handy for agents)
RUN apk add --no-cache git curl ca-certificates

# --- Agent CLIs used by HAICO adapters ---
#   claude — Claude Code       (@anthropic-ai/claude-code)
#   codex  — OpenAI Codex CLI  (@openai/codex, musl binaries)
#   gemini — Gemini CLI        (@google/gemini-cli)
#   pi     — Pi coding agent   (@earendil-works/pi-coding-agent)
#   cld    — symlink to claude (HAICO's default command template)
# Credentials are expected via env (ANTHROPIC_API_KEY / OPENAI_API_KEY /
# GEMINI_API_KEY) or persisted in /home/haico (see compose volume).
RUN npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli @earendil-works/pi-coding-agent \
 && npm cache clean --force \
 && ln -s "$(command -v claude)" /usr/local/bin/cld

# omp — Oh My Pi coding agent (official installer, musl-aware, sha256-verified)
RUN curl -fsSL https://omp.sh/install | PI_INSTALL_DIR=/usr/local/bin sh -s -- --binary

ENV NODE_ENV=production \
    HOME=/home/haico \
    HAICO_HOST=0.0.0.0 \
    HAICO_PORT=4567 \
    HAICO_DB_PATH=/data/haico.db

# Agents fall back to process.cwd() as working directory — use writable /data
WORKDIR /data

# Run as unprivileged user; /data = DB + fallback workspace, /home/haico = agent configs
RUN addgroup -S haico && adduser -S -h /home/haico -s /bin/sh -G haico haico \
 && mkdir -p /data /home/haico \
 && chown -R haico:haico /data /home/haico

COPY --from=prod-deps /app/node_modules /app/node_modules
COPY --from=builder   /app/dist         /app/dist
COPY --from=builder   /app/public       /app/public
COPY --from=builder   /app/bin          /app/bin
COPY                  package.json      /app/package.json

USER haico
VOLUME ["/data"]
EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${HAICO_PORT:-4567}/" || exit 1

CMD ["node", "/app/dist/index.js"]
