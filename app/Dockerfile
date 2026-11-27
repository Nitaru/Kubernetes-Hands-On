# Build stage: npm is needed to install dependencies, and only here.
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Runtime stage: no npm, no corepack. They are not needed to run the app, and the npm that ships in
# the base image bundles packages (tar, glob, minimatch...) that carry HIGH/CRITICAL CVEs.
FROM node:20-alpine
# Pick up OS security fixes published since the base image was built (libssl, zlib, musl...).
# Not pinned on purpose: the point is to take whatever fixed version exists today.
RUN apk upgrade --no-cache \
 && rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /opt/yarn*
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
# The base image's "node" user, by number (hadolint DL3066); the chart's pod spec says runAsUser: 1000 too.
USER 1000
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=3s CMD ["wget", "-qO-", "http://127.0.0.1:3000/health"]
CMD ["node", "src/server.js"]
