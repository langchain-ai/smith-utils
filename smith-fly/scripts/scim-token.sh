#!/bin/bash

##############################################################################
# scim-token.sh — generate a LangSmith SCIM bearer token (for --provisioning scim)
#
# The token is what Keycloak's outbound-SCIM extension authenticates with when it
# pushes Users/Groups to LangSmith's /scim/v2 endpoint. It is returned ONCE and is
# not retrievable later — save it immediately.
#
# Usage:
#   scripts/scim-token.sh <langsmith-endpoint> <org-admin-api-key> [description]
#
#   <langsmith-endpoint>   e.g. https://langsmith.<host>  (no trailing slash)
#   <org-admin-api-key>    an org-admin PAT / service key (X-Api-Key)
#   [description]          optional label, default "keycloak-local"
#
# Self-signed local TLS: this uses curl -k. Drop -k against a real CA.
##############################################################################

set -euo pipefail

ENDPOINT="${1:-}"
API_KEY="${2:-}"
DESCRIPTION="${3:-keycloak-local}"

if [ -z "$ENDPOINT" ] || [ -z "$API_KEY" ]; then
    echo "Usage: $0 <langsmith-endpoint> <org-admin-api-key> [description]" >&2
    exit 1
fi

ENDPOINT="${ENDPOINT%/}"

# Self-hosted exposes the API under /api/v1; SaaS docs show /v1. Try the self-hosted
# path first, then fall back, so the same script works in both shapes.
PATHS=(
    "/api/v1/platform/orgs/current/scim/tokens"
    "/v1/platform/orgs/current/scim/tokens"
)

for p in "${PATHS[@]}"; do
    url="${ENDPOINT}${p}"
    echo "[scim-token] POST ${url}" >&2
    resp="$(curl -sk -w '\n%{http_code}' -X POST "$url" \
        -H "X-Api-Key: ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"description\": \"${DESCRIPTION}\"}" || true)"

    code="$(printf '%s' "$resp" | tail -n1)"
    body="$(printf '%s' "$resp" | sed '$d')"

    if [ "$code" = "200" ] || [ "$code" = "201" ]; then
        echo "[scim-token] Success (HTTP ${code}). Token (shown once):" >&2
        echo "$body"
        exit 0
    fi
    echo "[scim-token] HTTP ${code} at ${p}; trying next path if any..." >&2
done

echo "[scim-token] Failed to create SCIM token. Last response:" >&2
echo "$body" >&2
exit 1
