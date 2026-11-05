# Backend del marketplace ToKlean. Contexto de build: la raíz de toklean-scs (necesita deployments/).
#   docker build -f backend/Dockerfile -t toklean-marketplace-backend .
FROM node:22-alpine
RUN corepack enable
WORKDIR /app/backend
COPY backend/package.json backend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod=false
COPY backend/ ./
COPY deployments/ ../deployments/
ENV HOST=0.0.0.0 PORT=8787 DATA_DIR=/data
VOLUME /data
EXPOSE 8787
USER node
CMD ["pnpm", "start"]
