# Rumi Calls SFU for Railway. Build context = repo root. Same pinned image as
# deploy/docker-compose.yml. TCP-only media: Railway has no UDP (docs/RAILWAY.md, calls section).
FROM livekit/livekit-server:v1.13.7
RUN apk add --no-cache socat
COPY --chmod=755 deploy/railway/livekit/entrypoint.sh /rumi-livekit.sh
ENTRYPOINT ["/rumi-livekit.sh"]
