# Rumi push server (UnifiedPush distributor + Matrix push gateway) for Railway. Build context =
# repo root. Same pinned image and the same settings as the ntfy service in deploy/docker-compose.yml.
FROM binwiederhier/ntfy:v2.28.0
COPY --chmod=755 deploy/railway/ntfy/entrypoint.sh /rumi-ntfy.sh
ENTRYPOINT ["/rumi-ntfy.sh"]
