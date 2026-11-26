# Production image for the photo booth server.
# Build from the repository root (the image also bundles ../designs):
#   docker build -f server/Dockerfile -t photobooth-server .
FROM node:24-bookworm-slim AS build
WORKDIR /app/server
COPY server/package.json server/package-lock.json ./
RUN npm ci
COPY server/tsconfig.json server/tsconfig.build.json ./
COPY server/src ./src
RUN npm run build && npm prune --omit=dev

FROM node:24-bookworm-slim
# Fonts so text elements in strip designs render (SVG text via librsvg).
RUN apt-get update \
 && apt-get install -y --no-install-recommends fontconfig fonts-dejavu-core fonts-liberation tini \
 && rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production \
    PORT=8080 \
    HOST=0.0.0.0 \
    DATA_DIR=/data \
    DESIGNS_DIR=/app/designs
WORKDIR /app/server
COPY --from=build /app/server/node_modules ./node_modules
COPY --from=build /app/server/dist ./dist
COPY server/package.json ./
COPY server/public ./public
COPY --chown=node:node designs /app/designs
RUN mkdir -p /data && chown node:node /data
USER node
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "dist/index.js"]
