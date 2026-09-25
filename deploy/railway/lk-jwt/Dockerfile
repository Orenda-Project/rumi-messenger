# Rumi Calls token service for Railway (MSC4195 standalone mode, same image digest as
# deploy/docker-compose.yml). Shell-less image, so everything is plain env: set PORT=8080 and the
# LIVEKIT_* variables on the service (docs/RAILWAY.md).
FROM ghcr.io/element-hq/lk-jwt-service@sha256:e0c7cecfa74e2342a3e79d47e1d4ab4bd228fe05b1a4dc4ba7f807686b0c214b
ENV LIVEKIT_JWT_BIND=":8080" LIVEKIT_LOG_LEVEL=info
