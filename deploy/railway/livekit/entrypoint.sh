#!/bin/sh
# Railway gives this service ONE https domain (signalling, on PORT) and ONE TCP proxy (media).
# The TCP proxy's public port (RAILWAY_TCP_PROXY_PORT) is chosen by Railway and differs from the
# port it forwards to (RAILWAY_TCP_APPLICATION_PORT). LiveKit advertises its own rtc.tcp_port in
# ICE candidates, so it listens on the PUBLIC port number, and socat forwards the proxy's target
# port to it. node_ip = the TCP proxy host's IP. UDP candidates are still advertised (LiveKit has no
# TCP-only switch) but unreachable, so clients fall back to ICE-TCP after the UDP attempts fail.
set -eu
: "${LIVEKIT_API_KEY:?}" ; : "${LIVEKIT_API_SECRET:?}"
: "${RAILWAY_TCP_PROXY_DOMAIN:?create the media proxy first: railway tcp-proxy create --port 7881 --service livekit}"
MEDIA_PORT="${RAILWAY_TCP_PROXY_PORT:?}"
APP_PORT="${RAILWAY_TCP_APPLICATION_PORT:-7881}"
NODE_IP="${LIVEKIT_NODE_IP:-$(getent ahostsv4 "${RAILWAY_TCP_PROXY_DOMAIN}" | awk 'NR==1{print $1}')}"
[ -n "${NODE_IP}" ] || { echo "rumi: could not resolve ${RAILWAY_TCP_PROXY_DOMAIN}"; exit 1; }
cat > /tmp/livekit.yaml <<YAML
port: ${PORT:-7880}
rtc:
  tcp_port: ${MEDIA_PORT}
  port_range_start: 50100
  port_range_end: 50200
  use_external_ip: false
  node_ip: ${NODE_IP}
keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
room:
  auto_create: false
YAML
if [ -n "${LK_JWT_URL:-}" ]; then
  printf 'webhook:\n  api_key: %s\n  urls:\n    - "%s/sfu_webhook"\n' "${LIVEKIT_API_KEY}" "${LK_JWT_URL%/}" >> /tmp/livekit.yaml
fi
if [ "${APP_PORT}" != "${MEDIA_PORT}" ]; then
  SELF_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')"
  socat "TCP-LISTEN:${APP_PORT},fork,reuseaddr" "TCP:${SELF_IP:-127.0.0.1}:${MEDIA_PORT}" &
fi
echo "rumi: livekit signalling :${PORT:-7880}, ICE-TCP ${NODE_IP}:${MEDIA_PORT} (proxy ${RAILWAY_TCP_PROXY_DOMAIN}:${MEDIA_PORT} -> :${APP_PORT} -> socat -> :${MEDIA_PORT})"
exec /livekit-server --config /tmp/livekit.yaml
