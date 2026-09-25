# Rumi Messenger Synapse for Railway. Build context = repo root (railway up from the repo root,
# RAILWAY_DOCKERFILE_PATH=deploy/railway/synapse/Dockerfile). Same pinned image as
# deploy/docker-compose.yml; the only addition is an entrypoint that renders homeserver.yaml from
# Railway variables at every boot, with the SAME patch scripts/setup.sh applies.
FROM matrixdotorg/synapse:v1.161.0
COPY deploy/synapse/patch_homeserver.py /rumi/patch_homeserver.py
COPY --chmod=755 deploy/railway/synapse/entrypoint.sh /rumi/entrypoint.sh
ENTRYPOINT ["/rumi/entrypoint.sh"]
