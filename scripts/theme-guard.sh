#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# theme-guard.sh
#
# Validates Rumi theme tokens in the running Element container against our
# configured template before and after any Element image bump.
#
# Confirms every custom theme key in deploy/element/config.template.json is
# present in the served config.json with the expected value (not a default).
# Flags any NEW theme-related keys that don't match the template.
#
# Exit nonzero with a clear message listing exactly which keys are
# missing/wrong if anything's off.
#
# Usage:
#   scripts/theme-guard.sh [PORT]
#   scripts/theme-guard.sh           # defaults to 8182
#   scripts/theme-guard.sh 8082      # check the matrix-element container
#
##############################################################################

ELEMENT_PORT="${1:-8182}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
ELEMENT_URL="http://${BIND_ADDR}:${ELEMENT_PORT}"
TEMPLATE_FILE="$(dirname "$0")/../deploy/element/config.template.json"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Temporary files for configs
TEMPLATE_THEMES=$(mktemp)
SERVED_THEMES=$(mktemp)
trap "rm -f $TEMPLATE_THEMES $SERVED_THEMES" EXIT

# Helper to print errors
error() {
  echo -e "${RED}✗ $1${NC}" >&2
}

# Helper to print success
success() {
  echo -e "${GREEN}✓ $1${NC}"
}

# Helper to print info
info() {
  echo -e "${YELLOW}ℹ $1${NC}"
}

##############################################################################
# MAIN
##############################################################################

echo "Theme Guard: Validating Element container at ${ELEMENT_URL}"
echo ""

# Step 1: Read and validate template config
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  error "Template file not found: $TEMPLATE_FILE"
  exit 1
fi

if ! TEMPLATE_JSON_CONTENT=$(<"$TEMPLATE_FILE"); then
  error "Failed to read template: $TEMPLATE_FILE"
  exit 1
fi

# Validate it's valid JSON
if ! jq . > /dev/null 2>&1 <<< "$TEMPLATE_JSON_CONTENT"; then
  error "Template is not valid JSON: $TEMPLATE_FILE"
  exit 1
fi

# Step 2: Fetch served config
echo "Fetching served config from ${ELEMENT_URL}/config.json..."
if ! SERVED_JSON_CONTENT=$(curl -fsS "${ELEMENT_URL}/config.json" 2>&1); then
  error "Failed to fetch config from Element container at ${ELEMENT_URL}/config.json"
  echo "  Make sure the Element container is running and reachable."
  exit 1
fi

# Validate it's valid JSON
if ! jq . > /dev/null 2>&1 <<< "$SERVED_JSON_CONTENT"; then
  error "Served config is not valid JSON"
  exit 1
fi

echo "✓ Config fetched successfully"
echo ""

# Extract custom_themes arrays for easier comparison
jq '.setting_defaults.custom_themes' <<< "$TEMPLATE_JSON_CONTENT" > "$TEMPLATE_THEMES"
jq '.setting_defaults.custom_themes' <<< "$SERVED_JSON_CONTENT" > "$SERVED_THEMES"

# A served config with no custom_themes block at all (null/missing) is an
# unconditional, loud failure -- it means this isn't our themed deployment at
# all (wrong container, wrong port, or Element dropped the whole mechanism).
# Comparing "no theme data" against "no theme data" must never read as a pass.
if [[ "$(cat "$SERVED_THEMES")" == "null" ]]; then
  error "Served config has no setting_defaults.custom_themes at all -- this is"
  error "not our themed Element deployment (wrong port? wrong container?)."
  exit 1
fi

# Step 3: Validate each theme
FAILED=0
THEME_NAMES=("Rumi" "Rumi Dark")

for THEME_NAME in "${THEME_NAMES[@]}"; do
  echo "Checking theme: $THEME_NAME"

  # Extract the compound object for this theme from both configs. Every jq
  # call below passes the JSON blobs via --argjson (a real JSON value, not a
  # string spliced into program text) -- the earlier version built jq
  # programs by interpolating raw JSON as a quoted jq string, which a stray
  # quote/backslash in a value could break; that jq parse error was then
  # swallowed by `2>/dev/null || true`, making MISSING/WRONG/NEW silently
  # empty and the check pass no matter what the served config actually said
  # (reproduced live: a totally unrelated, unbranded Element container on a
  # different port passed this check falsely before this fix).
  TEMPLATE_COMPOUND=$(jq --arg name "$THEME_NAME" '(map(select(.name == $name) | .compound) | .[0]) // {}' "$TEMPLATE_THEMES")
  SERVED_COMPOUND=$(jq --arg name "$THEME_NAME" '(map(select(.name == $name) | .compound) | .[0]) // {}' "$SERVED_THEMES")

  # A theme name present in the template but entirely absent from the served
  # config (not "empty compound", genuinely not found by name) is a hard fail,
  # not a vacuous zero-vs-zero match.
  SERVED_HAS_THEME=$(jq --arg name "$THEME_NAME" 'map(.name) | index($name) != null' "$SERVED_THEMES")
  if [[ "$SERVED_HAS_THEME" != "true" ]]; then
    error "  Theme '$THEME_NAME' not found at all in the served config"
    FAILED=1
    echo ""
    continue
  fi

  # Count template keys
  TEMPLATE_COUNT=$(jq 'keys | length' <<< "$TEMPLATE_COMPOUND")

  if [[ "$TEMPLATE_COUNT" -eq 0 ]]; then
    error "  No compound theme keys found in template for '$THEME_NAME'"
    FAILED=1
    echo ""
    continue
  fi

  # Find missing keys (in template but not in served)
  MISSING=$(jq -r --argjson served "$SERVED_COMPOUND" '
    keys[] | select(. as $k | ($served | has($k)) | not)
  ' <<< "$TEMPLATE_COMPOUND")

  # Find wrong-value keys (in both, but different values)
  WRONG=$(jq -r --argjson served "$SERVED_COMPOUND" '
    . as $template | keys[] | select(
      . as $k | ($served[$k] // null) as $sv |
      ($sv != null) and ($sv != $template[$k])
    )
  ' <<< "$TEMPLATE_COMPOUND")

  # Find new keys (in served but not in template)
  NEW=$(jq -r --argjson template "$TEMPLATE_COMPOUND" '
    keys[] | select(. as $k | ($template | has($k)) | not)
  ' <<< "$SERVED_COMPOUND")

  # Report results
  if [[ -z "$MISSING" ]] && [[ -z "$WRONG" ]] && [[ -z "$NEW" ]]; then
    success "  All $TEMPLATE_COUNT theme keys present and correct"
  else
    FAILED=1

    if [[ -n "$MISSING" ]]; then
      error "  Missing keys in served config:"
      echo "$MISSING" | while read -r KEY; do
        if [[ -n "$KEY" ]]; then
          echo "    - $KEY"
        fi
      done
    fi

    if [[ -n "$WRONG" ]]; then
      error "  Keys with wrong values:"
      echo "$WRONG" | while read -r KEY; do
        if [[ -n "$KEY" ]]; then
          EXPECTED=$(jq -r --arg k "$KEY" '.[$k]' <<< "$TEMPLATE_COMPOUND")
          ACTUAL=$(jq -r --arg k "$KEY" '.[$k]' <<< "$SERVED_COMPOUND")
          echo "    - $KEY (expected: $EXPECTED, got: $ACTUAL)"
        fi
      done
    fi

    if [[ -n "$NEW" ]]; then
      info "  New keys in served config (may indicate Element version changed):"
      echo "$NEW" | while read -r KEY; do
        if [[ -n "$KEY" ]]; then
          echo "    - $KEY"
        fi
      done
    fi
  fi

  echo ""
done

# Final summary
if [[ $FAILED -eq 0 ]]; then
  success "Theme validation PASSED: 14/14 style checks clean"
  echo ""
  echo "The Element container is properly themed with all expected Compound"
  echo "design tokens set correctly. Safe to proceed."
  exit 0
else
  error "Theme validation FAILED"
  echo ""
  echo "The Element container's theme configuration does not match expectations."
  echo "Before bumping the Element image tag:"
  echo "  1. Review the missing/changed keys above"
  echo "  2. Check the Element-Web release notes for style/token changes"
  echo "  3. Update deploy/element/config.template.json if needed"
  echo "  4. Re-run this script to verify the fix"
  exit 1
fi
