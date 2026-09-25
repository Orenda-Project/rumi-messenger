# Rumi Messenger web app for Railway. Build context = repo root. Same pinned image as
# deploy/docker-compose.yml; the branded templates are the ones scripts/setup.sh renders, and a
# /docker-entrypoint.d hook renders them from Railway variables at boot (the server's domain is
# only known once Railway assigns it).
FROM vectorim/element-web:v1.12.29
USER root
COPY deploy/element/config.template.json deploy/element/welcome.template.html deploy/element/home.template.html /rumi-templates/
COPY deploy/element/rumi-translations.json /app/rumi-translations.json
COPY deploy/element/assets /app/rumi
RUN for f in config.json welcome.html home.html; do : > "/app/$f"; chown nginx:nginx "/app/$f"; done
COPY --chmod=755 deploy/railway/element/17-rumi-render.envsh /docker-entrypoint.d/17-rumi-render.envsh
USER nginx
