FROM node:lts-trixie-slim AS base
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git \
  && rm -rf /var/lib/apt/lists/*
RUN corepack enable

FROM base AS deps
WORKDIR /app

# 1. Copy the root workspace files
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./

# 2. Copy the package.json from EVERY directory at once
# This handles server, ui, cli, and everything inside /packages automatically
COPY **/package.json ./
# Note: Because of how Docker COPY works with wildcards, we need to ensure 
# the directory structure is preserved for pnpm to link them.
# If the above fails, we use this more explicit but flexible approach:
COPY cli/package.json ./cli/
COPY server/package.json ./server/
COPY ui/package.json ./ui/
COPY packages/ ./packages/

# We delete everything in packages EXCEPT the package.json files 
# to keep the install cache slim (Optional, but good practice)
RUN find packages -type f -not -name 'package.json' -delete

RUN pnpm install --frozen-lockfile

FROM base AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .

# Build with internal dependency awareness
RUN pnpm --filter @paperclipai/server... build
RUN pnpm --filter @paperclipai/ui build

RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

FROM base AS production
WORKDIR /app
COPY --chown=node:node --from=build /app /app

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
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
