# Patches a generated homeserver.yaml into Rumi Messenger's shape. ONE copy, two callers:
# scripts/setup.sh (the compose stack; pipes this file into the synapse image's python3) and
# deploy/railway/synapse/entrypoint.sh (Railway, runs it at every boot). Everything is driven by
# env vars; the Railway-only branches below are all gated on vars setup.sh never sets
# (DATABASE_URL, LISTEN_PORT, TURN_HOST empty), so the compose output is unchanged.
import os, yaml
from urllib.parse import urlsplit, unquote

path = os.environ.get("HOMESERVER_YAML", "/data/homeserver.yaml")
with open(path) as f:
    config = yaml.safe_load(f)

server_name = os.environ["SERVER_NAME"]
mode = os.environ["REGISTRATION_MODE"]

if os.environ.get("DATABASE_URL"):
    # Railway's managed Postgres: one URL. The database NAME is SYNAPSE_DB_NAME, not the URL's
    # own ("railway"), because Synapse needs a C-collated database and the entrypoint creates
    # exactly that one (deploy/railway/synapse/entrypoint.sh).
    u = urlsplit(os.environ["DATABASE_URL"])
    config["database"] = {
        "name": "psycopg2",
        "args": {
            "user": unquote(u.username or "postgres"),
            "password": unquote(u.password or ""),
            "database": os.environ.get("SYNAPSE_DB_NAME", "synapse"),
            "host": u.hostname,
            "port": u.port or 5432,
            "cp_min": 5,
            "cp_max": 10,
        },
    }
else:
    config["database"] = {
        "name": "psycopg2",
        "args": {
            "user": "synapse",
            "password": os.environ["POSTGRES_PASSWORD"],
            "database": "synapse",
            "host": "postgres",
            "port": 5432,
            "cp_min": 5,
            "cp_max": 10,
        },
    }

# Railway: no reverse proxy of ours in front. The client listener takes Railway's PORT, listens on
# IPv4+IPv6 (Railway's private network is IPv6), trusts X-Forwarded-* from Railway's edge, and
# Synapse itself serves both .well-known documents (Caddy does that on the compose stack).
if os.environ.get("LISTEN_PORT"):
    for listener in config.get("listeners", []):
        if listener.get("type") == "http" and not listener.get("tls"):
            listener["port"] = int(os.environ["LISTEN_PORT"])
            listener["bind_addresses"] = ["::"]
            listener["x_forwarded"] = True
    config["serve_server_wellknown"] = True
    config["serve_client_wellknown"] = True

if mode == "token":
    config["enable_registration"] = True
    config["registration_requires_token"] = True
    config.pop("enable_registration_without_verification", None)
else:
    config["enable_registration"] = True
    config["enable_registration_without_verification"] = True
    config["registration_requires_token"] = False

# Phone-number enumeration (Railway critic, 25 Sep 2026): user ids ARE teachers' phone numbers, and
# three unauthenticated endpoints answered "does +92300... have an account?": register/available,
# POST /register (M_USER_IN_USE before the token stage), and GET /profile (which also returned the
# display name). rc_registration does NOT cover register/available -- Synapse v1.161.0 hardcodes a
# sleep-only limiter there (rest/client/register.py, ~1 req/2s per IP, delays, never rejects a
# sequential caller). So close the oracles instead of rate-limiting them:
# - inhibit_user_in_use_error: register/available always says available and POST /register only
#   reports a taken name AFTER the registration-token stage, i.e. only to someone holding a token.
# - require_auth_for_profile_requests: profiles need a login. Signed-in teachers still see each
#   other (user directory, search_all_users above is unchanged).
config["inhibit_user_in_use_error"] = True
config["require_auth_for_profile_requests"] = True

config["registration_shared_secret"] = os.environ["REG_SHARED_SECRET"]
config["auto_join_rooms"] = [f"#rumi-announcements:{server_name}"]
config["autocreate_auto_join_rooms"] = True
config["max_upload_size"] = "50M"
config["url_preview_enabled"] = False
config["presence"] = {"enabled": True}
config["report_stats"] = False

# User directory (issue #10, "give teachers a way to find each other"): this is what backs
# Element X's start-chat search box. search_all_users=true is deliberate here -- Rumi Messenger
# is a CLOSED school server (accounts come only from admin-created teacher onboarding or the
# registration_shared_secret flow above, never open public signup), so every account on THIS
# homeserver should be findable by name; there is no untrusted stranger to protect a teacher from
# by hiding them. prefer_local_users=true ranks this server's own teachers above any
# remote/federated account in results (this deployment doesn't federate, but costs nothing to set
# correctly). See docs/RUNBOOK.md for the multi-school privacy tradeoff this implies if this
# server is ever shared across more than one school.
# Keys + defaults per Synapse's own config docs, "user_directory" section:
# https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#user_directory
config["user_directory"] = {
    "enabled": True,
    "search_all_users": True,
    "prefer_local_users": True,
}

# Synapse's default rate limits assume a public server defending itself. A school is
# the opposite shape: a staffroom signs in together at 8am and a class joins a room
# together, which at the defaults reads as abuse and answers M_LIMIT_EXCEEDED.
config["rc_login"] = {
    "address": {"per_second": 1, "burst_count": 30},
    "account": {"per_second": 1, "burst_count": 30},
    "failed_attempts": {"per_second": 0.5, "burst_count": 10},
}
config["rc_joins"] = {
    "local": {"per_second": 1, "burst_count": 50},
    "remote": {"per_second": 0.05, "burst_count": 10},
}
config["rc_message"] = {"per_second": 5, "burst_count": 30}
config["rc_invites"] = {
    "per_room": {"per_second": 1, "burst_count": 20},
    "per_user": {"per_second": 1, "burst_count": 20},
}

# TURN server for 1:1 audio/video calls (issue #1). turn_shared_secret must be the exact same
# string as coturn's own static-auth-secret (deploy/coturn/turnserver.conf, written by step 5
# below) -- Synapse's TURN REST API implementation mints a short-lived username/password pair
# per client ("<unix-ts>+<user id>", HMAC-SHA1 of that over the shared secret, base64), and
# coturn validates that same construction on connect (use-auth-secret mode). Two URIs, UDP and
# TCP, per Matrix's own coturn guide (element-hq/synapse docs/setup/turn/coturn.md) -- clients
# try UDP first and fall back to TCP when UDP is blocked by a restrictive firewall.
# No coturn (Railway: no UDP at all) -> TURN_HOST empty -> no TURN advertised, never a dead one.
if os.environ.get("TURN_HOST"):
    config["turn_uris"] = [
        f"turn:{os.environ['TURN_HOST']}:{os.environ['TURN_PORT']}?transport=udp",
        f"turn:{os.environ['TURN_HOST']}:{os.environ['TURN_PORT']}?transport=tcp",
    ]
    config["turn_shared_secret"] = os.environ["TURN_SHARED_SECRET"]
    # 24h, the same value Synapse's own docs use as their example -- credentials are per-call-session
    # scoped by the client anyway (a fresh set is fetched per call), this just bounds how long a
    # leaked credential would remain valid.
    config["turn_user_lifetime"] = 86400000
    config["turn_allow_guests"] = True
else:
    for k in ("turn_uris", "turn_shared_secret", "turn_user_lifetime", "turn_allow_guests"):
        config.pop(k, None)

# Federation OFF (issue #8, docs/FEDERATION-RETENTION.md): one school, one server, no inter-school
# need yet. An empty whitelist makes Synapse refuse every remote server, and dropping the
# `federation` resource from the listener stops serving /_matrix/federation/* at all -- the
# generated default listener serves it on the same port as the client API. Re-enable both when a
# second school needs to talk to this one.
config["federation_domain_whitelist"] = []
for listener in config.get("listeners", []):
    for res in listener.get("resources", []):
        names = [n for n in res.get("names", []) if n != "federation"]
        # `openid` is Synapse's stand-alone resource for ONE endpoint,
        # /_matrix/federation/v1/openid/userinfo, which is how third-party services (here:
        # lk-jwt-service for group calls, issue #2) check that a teacher's OpenID token is real.
        # It is normally bundled inside `federation`; listing it on its own keeps that single
        # endpoint while the rest of the federation API stays unserved (404).
        if "client" in names and "openid" not in names:
            names.append("openid")
        res["names"] = names

# Calls (issue #2): MSC4143 RTC transport discovery -- the ONE place both apps (Element X and
# Element Web's Element Call widget) learn where the calls backend is. Written only when this run
# starts LiveKit (CALLS != off); otherwise removed, so no client is ever sent to a dead address.
if os.environ["CALLS"] != "off":
    config.setdefault("experimental_features", {})["msc4143_enabled"] = True
    config["matrix_rtc"] = {
        "transports": [
            {"type": "livekit", "livekit_service_url": os.environ["LIVEKIT_SERVICE_URL"]},
        ]
    }
else:
    config.setdefault("experimental_features", {})["msc4143_enabled"] = False
    config.pop("matrix_rtc", None)

# Group calls (issue #2): joining an Element Call means sending an
# `org.matrix.msc3401.call.member` STATE event. Synapse's default room power levels put every
# state event at 50 (state_default), so in any room not created by Element Web itself (bot, admin
# API, scripts, Element X) an ordinary teacher (level 0) gets 403 M_FORBIDDEN, Element Call's
# MembershipManager shuts down, and the LiveKit connection is torn down as "Client initiated
# disconnect" -- the root cause of round 1's second-participant abort (reproduced live, round 2).
# Same values Element Web itself uses when it creates a room with group calls on: members may
# join (0), only admins may start the legacy call object (100). Synapse applies this per preset
# by REPLACING top-level keys, so the full default `events` map is repeated here.
_room_events = {
    "m.room.name": 50,
    "m.room.avatar": 50,
    "m.room.canonical_alias": 50,
    "m.room.power_levels": 100,
    "m.room.history_visibility": 100,
    "m.room.encryption": 100,
    "m.room.server_acl": 100,
    "m.room.tombstone": 100,
    "org.matrix.msc3401.call.member": 0,
    "org.matrix.msc3401.call": 100,
}
# MSC4140 delayed events: Element Call schedules a "leave" that Synapse sends by itself if the
# client stops refreshing it (phone dies, tab closed, network gone). Without this, a crashed
# client's call.member event lingers as a "Waiting for media..." ghost tile until it expires
# (hours) -- seen live in round 2 ("Not using delayed event because the endpoint is not
# supported"). Setting a max duration is what turns the endpoint on in Synapse.
config["max_event_delay_duration"] = "24h"
config["default_power_level_content_override"] = {
    preset: {"events": dict(_room_events)}
    for preset in ("private_chat", "trusted_private_chat", "public_chat")
}

# The URL Synapse tells clients about itself (emails, SSO redirects, well-known) -- the same one
# Element and the bot are given.
config["public_baseurl"] = os.environ["PUBLIC_BASE_URL"].rstrip("/") + "/"

# LAN mode (issue #3, docs/PUSH.md): Synapse sends pusher traffic through an IP-blocklisted client
# that refuses every private address, so pushes to ntfy on the school LAN failed with
# "403: IP address blocked". Exempt exactly the server's own LAN IP (/32) -- ntfy is published
# there -- and nothing else: widening this (a whole /24, 10/8) would let any teacher register a
# pusher that makes Synapse POST into other machines on the school network (SSRF).
if os.environ.get("LAN_IP"):
    config["ip_range_whitelist"] = [os.environ["LAN_IP"] + "/32"]
else:
    config.pop("ip_range_whitelist", None)

with open(path, "w") as f:
    yaml.safe_dump(config, f, default_flow_style=False, sort_keys=False)

print("homeserver.yaml patched")
