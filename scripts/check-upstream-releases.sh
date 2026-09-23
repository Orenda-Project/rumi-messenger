#!/usr/bin/env bash
# Compares the versions this repo is pinned to against each upstream's latest GitHub release.
# One issue per outdated dependency, deduped by title, auto-closed once we catch up.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-Orenda-Project/rumi-messenger}"
COMPOSE="$(dirname "$0")/../deploy/docker-compose.yml"

check() {
  local name="$1" upstream="$2" pinned="$3" note="$4"
  local latest latest_ver pinned_ver
  latest="$(gh api "repos/${upstream}/releases/latest" --jq '.tag_name' 2>/dev/null || echo "")"
  # `gh api` can exit 0 and print the error body's JSON as "tag_name" text (e.g. 404 on a
  # renamed/missing repo) instead of failing -- validate it actually looks like a version
  # instead of trusting a non-empty string. Also normalizes tag-format drift (e.g. coturn's
  # "docker/4.18.0-r0" vs our plain "4.18.0") by comparing only the dotted-number part.
  latest_ver="$(grep -oP '[0-9]+(\.[0-9]+)+' <<<"${latest}" | head -1)"
  pinned_ver="$(grep -oP '[0-9]+(\.[0-9]+)+' <<<"${pinned}" | head -1)"
  if [[ -z "${latest_ver}" ]]; then
    echo "  ${name}: could not fetch a valid latest release (got '${latest:0:80}'), skipping"
    return
  fi

  local title="Upstream release available: ${name} ${latest}"
  # real numeric version compare, not substring: pinned is up to date if it is >= latest
  # once both are reduced to their dotted-number core (sort -V, not a text match).
  if [[ "${pinned_ver}" == "${latest_ver}" ]] || \
     [[ "$(printf '%s\n%s\n' "${pinned_ver}" "${latest_ver}" | sort -V | tail -1)" == "${pinned_ver}" ]]; then
    echo "  ${name}: up to date (${pinned}, latest ${latest})"
    # close any stale alert now that we've caught up
    gh issue list --repo "${REPO}" --state open --search "\"Upstream release available: ${name} \" in:title" --json number \
      --jq '.[].number' 2>/dev/null | while read -r n; do
      [[ -n "$n" ]] && gh issue close "$n" --repo "${REPO}" --comment "Closing: ${name} is now pinned to ${pinned}, at or past this release." >/dev/null
    done
    return
  fi

  echo "  ${name}: OUTDATED — pinned ${pinned}, latest ${latest}"
  local existing
  existing="$(gh issue list --repo "${REPO}" --state open --search "\"${title}\" in:title" --json number --jq '.[0].number' 2>/dev/null || echo "")"
  if [[ -n "${existing}" ]]; then
    echo "    already tracked as #${existing}"
    return
  fi
  gh issue create --repo "${REPO}" --title "${title}" \
    --label upstream-alert \
    --body "$(printf 'We are pinned to `%s`; upstream https://github.com/%s just released [`%s`](https://github.com/%s/releases/tag/%s).\n\n%s\n\nBump the pin, re-run the full e2e/gauntlet pass, and close this once done.' \
      "${pinned}" "${upstream}" "${latest}" "${upstream}" "${latest}" "${note}")" >/dev/null
  echo "    filed a new issue"
}

echo "Checking upstream releases against pins in deploy/docker-compose.yml..."
check "Synapse"     "element-hq/synapse"          "$(grep -oP 'synapse:v\K[0-9.]+' "$COMPOSE")"     "deploy/docker-compose.yml: synapse image tag."
check "Element Web" "element-hq/element-web"      "$(grep -oP 'element-web:v\K[0-9.]+' "$COMPOSE")" "deploy/docker-compose.yml: element image tag."
check "Sygnal"      "element-hq/sygnal"           "$(grep -oP 'sygnal:v\K[0-9.]+' "$COMPOSE")"      "deploy/docker-compose.yml: sygnal image tag."
check "coturn"      "coturn/coturn"               "$(grep -oP 'coturn:\K[0-9.]+' "$COMPOSE")"       "deploy/docker-compose.yml: coturn image tag."

# element-x-android: we don't pin to a release tag, we merge upstream/develop on a schedule (see
# ~/Documents/free_work/element-x-android/.rumi/README.md). Report drift by commit count instead.
ANDROID_REPO="Orenda-Project/element-x-android"
BASE_SHA="$(gh api "repos/${ANDROID_REPO}/git/refs/heads/rumi-brand" --jq '.object.sha' 2>/dev/null || echo "")"
if [[ -n "${BASE_SHA}" ]]; then
  BEHIND="$(gh api "repos/element-hq/element-x-android/compare/${BASE_SHA}...develop" --jq '.behind_by // .ahead_by // "unknown"' 2>/dev/null || echo "unknown")"
  echo "  Android fork: rumi-brand is ${BEHIND} commits behind element-hq/element-x-android develop"
fi
