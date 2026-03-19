FROM node:lts-trixie-slim AS base
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git \
  && rm -rf /var/lib/apt/lists/*
RUN corepack enable

FROM base AS deps
WORKDIR /app

# Copy workspace configuration and lockfile
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./

# Copy all package.json files to allow pnpm to fetch all dependencies 
# This ensures internal packages like plugin-sdk are recognized
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
# Using a wildcard to catch all internal package manifests
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/plugin-sdk/package.json packages/plugin-sdk/
COPY packages/types/package.json packages/types/
COPY packages/adapters// packages/adapters/

# Filter out only package.json files if the above COPY was too broad, 
# but pnpm install needs the manifests to link the workspace.
RUN pnpm install --frozen-lockfile

FROM base AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .

# 1. Build the server AND all its local workspace dependencies (like the SDK)
# The "..." tells pnpm to build the target plus its internal dependency tree.
RUN pnpm --filter @paperclipai/server... build

# 2. Build the UI
RUN pnpm --filter @paperclipai/ui build

# Verify build output
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

FROM base AS production
WORKDIR /app

# Copy only the necessary files for production
COPY --chown=node:node --from=build /app /app

# Install global CLI tools required by the app
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

ENV NODE_ENV=production \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private

VOLUME ["/paperclip"]
EXPOSE 3100

USER node

# We use tsx loader because the app likely uses ESM/TS features in production
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
