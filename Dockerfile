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

ENV NODE_ENV=production \
    HAICO_HOST=0.0.0.0 \
    HAICO_PORT=4567 \
    HAICO_DB_PATH=/data/haico.db

WORKDIR /app

# Run as unprivileged user; /data holds the SQLite DB (and can hold agent workspaces)
RUN addgroup -S haico && adduser -S haico -G haico \
    && mkdir -p /data && chown -R haico:haico /data

COPY --from=prod-deps  /app/node_modules ./node_modules
COPY --from=builder    /app/dist         ./dist
COPY --from=builder    /app/public       ./public
COPY --from=builder    /app/bin          ./bin
COPY                   package.json      ./

USER haico
VOLUME ["/data"]
EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${HAICO_PORT:-4567}/" || exit 1

CMD ["node", "dist/index.js"]
